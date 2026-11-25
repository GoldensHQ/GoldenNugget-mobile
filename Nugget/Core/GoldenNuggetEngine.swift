import Foundation
import Minimuxer
import SwiftUI

/// An error whose message is meant for the operator, not for a stack trace.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The apply pipeline, ported from GoldenNugget's own apply pass
// (`device_manager._apply_tweak_pass`) onto this app's restore machinery.
//
// Flow:
//   1. Compile the selection to plists — before the device is touched, so an
//      impossible selection costs nothing.
//   2. Real protective backup via mobilebackup2 — triggers the iOS 27
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   3. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them), then inject
//      the compiled tweak plists as rows + payloads.
//   4. Restore via mobilebackup2.
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 2), `BackupInjector` (stage 3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()

    private init() {}

    // MARK: - Logging facade

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Run `body` under `label`, writing a failure into the log before it escapes.
    ///
    /// Every run entry point throws to a view that turns the error into a status
    /// line, and a status line lives exactly as long as the screen: the file sink
    /// is the only record a failed run leaves once the app is closed. It has to
    /// be written here rather than at the call sites because there are four of
    /// them and a fifth would silently skip it — which is how a posterboard apply
    /// came to end with its last line still on the *fetch* and nothing saying
    /// why.
    private func loggedRun<T>(_ label: String,
                              _ body: () async throws -> T) async throws -> T {
        try InFlightCall.shared.beginRun()
        defer { InFlightCall.shared.endRun() }
        do {
            return try await body()
        } catch let failure as TransportFailure where failure.isCancellation {
            log("\(label) stopped: \(failure.label)")
            throw failure
        } catch {
            log("\(label) failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cancellation facade

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        // One line per call was wrong twice over: `.onAppear` fires on every
        // navigation back and `startMinimuxer` calls this again, so a session
        // that never got a tunnel printed the same "rust log → …" line a dozen
        // times — the loudest thing in a log whose real failure was one line
        // lower. The Rust side is process-wide state; the first answer is the
        // only one that describes it.
        if let cached = RustLog.initResult {
            return cached
        }

        let hygiene = PairingLogPrivacy.removeLegacyDumps(
            at: [AppPaths.rustLog, AppPaths.rustLogArchive, AppPaths.appLog]
        )
        if !hygiene.isEmpty {
            // Named, not silent: this is free space on the volume the device's
            // backup space check measures, and its absence is why backups that
            // used to work started offering zero files.
            log("diagnostic logs reclaimed: \(hygiene.summary) — the backup volume needs this space")
        }
        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

        let meaning: String
        switch rc {
        case 0:   meaning = "file sink requested (DEBUG)"
        case -1:  meaning = "file error — path rejected by Rust"
        case -2:  meaning = "already initialized — a previous idevice_init_logger call won, Rust logs stay on console(Error) and never reach the file"
        case -3:  meaning = "invalid path string"
        case -99: meaning = "no ideviceGateway available"
        default:  meaning = "unknown"
        }
        log("rust log → \(path): rc=\(rc) (\(meaning))")

        // rc=0 only means the subscriber was installed; the file itself is
        // created by the first line the Rust side writes, so it is legitimately
        // absent here. What must be true NOW is that the directory exists —
        // a missing parent is the one case where the sink can never come up, and
        // it is invisible afterwards (status reads "size=MISSING" forever).
        if rc == 0 {
            let fm = FileManager.default
            let parent = URL.documents.path
            let parentExists = fm.fileExists(atPath: parent)
            log("rust log dir: \(parent) exists=\(parentExists) "
                + "(file appears with the first Rust line)")
            if !parentExists {
                log("⚠️ the Rust log directory does not exist — no Rust evidence will be "
                    + "written this session. This app is running somewhere its Documents "
                    + "path is not writable.")
            }
        }
        return rc
    }

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Progress facade

    /// Whole-percent progress of the run in flight, or nil when nothing has
    /// reported yet.  The reference's home page prints the same number in its
    /// process-status line (`IOSApplyPage.set_status` parses `NN%` out of the
    /// status text), and a multi-minute restore with no number on it is the one
    /// screen the operator keeps re-reading to guess whether it is alive.
    private(set) var progress: Double?

    /// Route progress into the UI.  Called from the Rust progress callbacks, so
    /// the handler hops to the main actor itself.
    var onProgress: ((Double) -> Void)?

    /// Route the remaining-time estimate into the UI with the same story as
    /// `onProgress`: the feed happens on the Rust callback thread, the handler
    /// hops to the main actor.  Empty string until a stable rate is known — the
    /// desktop's status line shows nothing while `eta.py` is still quiet.
    var onEta: ((String) -> Void)?

    /// The last formatted remaining time (`""` before an estimate exists or
    /// while nothing is running).
    private(set) var etaText: String = ""

    /// The `eta.py` port.  Recreated per run so a new apply starts estimating
    /// from a clean slate even though the engine object is a singleton.
    private var etaEstimator = ProgressEta()

    private func reportProgress(_ percent: Double) {
        let clamped = percent < 0 ? 0 : min(percent, 100)
        progress = clamped
        onProgress?(clamped)
        let estimate = etaEstimator.update(clamped)
        etaText = estimate
        onEta?(estimate)
    }

    private func clearProgress() {
        progress = nil
        etaEstimator.reset()
        etaText = ""
        onProgress?(Double.nan)
        onEta?("")
    }

    // MARK: - Run: apply the ported GoldenNugget tweaks

    /// Apply everything this app can deliver: the compiled plist tweaks, the skip-setup
    /// files, and the PosterBoard selection — **one pass, one button**.
    ///
    /// This is GoldenNugget's `device_manager._apply_tweak_pass`, whose file list is
    /// built from every feature at once: its `needs_posterboard` flag decides whether the
    /// store's database has to be fetched first, and the wallpapers then ride the same
    /// restore as the tweaks.  There is no separate apply for wallpapers — this port had
    /// one for a while, a second button running the same four stages over a different
    /// payload set, and it is gone.  What is left of it is the flag.
    ///
    /// The compile runs *before* the device is touched, so an empty or impossible
    /// selection fails without paying for a backup first.  The PosterBoard database is
    /// the one input that has to come off the device; that stage therefore talks to it,
    /// but it is still ahead of the expensive protective pull and of the restore.
    func applyTweaks(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        templates: TemplateSelection,
        deviceVersion: String,
        isIPhone: Bool,
        deviceModel: String = "",
        communityPayloads: [TweakPayload] = [],
        communityPresetEntry: [String: Any]? = nil
    ) async throws {
        // The keepalive covers the whole call: the rollback snapshot before the
        // device is touched, the restore itself, and the preset save after it.
        // It is claimed before `loggedRun` reserves the run so an overlapping
        // apply rejected by `InFlightCall` cannot leave this run's screen awake
        // without an owner. `start()` refuses the run when the Always-location
        // requirement is on but unmet — the home page preflights the same rule
        // before showing its confirmation, but the engine is the last guard.
        let keepAliveToken = try await MainActor.run {
            try ApplyKeepAlive.shared.start()
        }
        do {
            // `_prepare_rollback_preset` (`main_window_mixins.py:1090`): keep the
            // last successful apply available as a one-click rollback *before* the
            // next apply overwrites it.  Best-effort, like the reference.
            try await loggedRun("apply") {
                GoldenNuggetPresets.prepareRollback()
                try await applyTweaksRun(selection: selection,
                                         posterBoard: posterBoard,
                                         statusBar: statusBar,
                                         templates: templates,
                                         deviceVersion: deviceVersion,
                                         isIPhone: isIPhone, deviceModel: deviceModel, communityPayloads: communityPayloads)
            }
            // `_save_last_applied_preset` (`main_window_mixins.py:1101`): a run
            // that returned is a successful apply — it becomes the rollback source
            // for the next one.  The model string is derived because the engine
            // does not carry a full identity; the snapshot is internal metadata.
            _ = GoldenNuggetPresets.saveLastApplied(selection: selection,
                                                    deviceModel: deviceModel.isEmpty ? (isIPhone ? "iPhone" : "iPad") : deviceModel,
                                                    iosVersion: deviceVersion)
            if let entry = communityPresetEntry {
                do { try GoldenNuggetPresets.attachTemplates(entry, to: GoldenNuggetPresets.lastAppliedName) }
                catch { log("Template rollback snapshot could not be saved: \(error.localizedDescription)") }
            }
        } catch {
            await MainActor.run { ApplyKeepAlive.shared.finish(token: keepAliveToken) }
            throw error
        }
        await MainActor.run { ApplyKeepAlive.shared.finish(token: keepAliveToken) }
    }

    private func applyTweaksRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        templates: TemplateSelection,
        deviceVersion: String,
        isIPhone: Bool,
        deviceModel: String = "",
        communityPayloads: [TweakPayload] = []
    ) async throws {
        AppLog.shared.resetForNewRun()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        let identity = await DeviceIdentity.read()
        let safety = await MainActor.run {
            HotLoadService.shared.policy(deviceVersion: identity.version.isEmpty ? deviceVersion : identity.version,
                                         model: identity.productType.isEmpty ? deviceModel : identity.productType)
        }
        var features: Set<String> = []
        if posterBoard.isActive { features.insert("PosterBoard") }
        if statusBar.isActive { features.insert("Status Bar") }
        if templates.isActive || !communityPayloads.isEmpty { features.insert("Templates") }
        try safety.requireAllowed(features: features)
        try safety.validateCommunity(communityPayloads)
        for warning in safety.warnings(for: selection) + safety.warnings(forFeatures: features) { log("HotLoad warning: \(warning)") }
        if let issue = selection.validationIssue() { throw GoldenNuggetError(issue) }
        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone, deviceModel: deviceModel,
                                             hiddenTweakIDs: safety.hiddenTweakIDs,
                                             forcedDaemonKeys: safety.forcedDaemonKeys)

        let tweakPayloads = try TweakCompiler.merging(community: communityPayloads, builtIn: compiled.payloads, deviceVersion: deviceVersion)

        // The status bar is built here, on the version the page already read, and
        // for the same reason the plist compile is: a payload that cannot be built
        // has to fail before the device is touched.  The page resolves the
        // mechanism from this same number, so the two cannot disagree.
        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            // The count, then the parenthetical the reference's summary has: an
            // enabled-but-empty selection still writes a file, and the log has to
            // say so, or a reset reads as a no-op.
            log("Status bar: \(statusBar.overrides.activeCount) override(s)"
                + " \(statusBar.overrides.activeCount == 0 ? "(a reset)" : "") via "
                + "\(mechanism == .classic ? "the classic struct" : "the iOS 27 archive") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) has no counterpart in the iOS 27 archive and was not delivered")
            }
        }

        // Upstream's skip-setup block rides the same apply, **ahead of** the
        // tweaks (`device_manager.add_skip_setup`).  Its warnings are logged
        // below: the parts this port cannot reproduce must not read like parity.
        //
        // Always the un-supervised variant.  The `supervised` / `organizationName`
        // arguments used to come off the Supervision page, and the page is gone —
        // it recorded `IsSupervised` without ever writing the
        // `SupervisorHostCertificates` that make the flag mean anything, so a
        // device this app "supervised" sat in a state the reference never
        // produces on purpose.  `SkipSetup` still carries the supervised shape
        // because `scripts/skipsetup-check.swift` checks both, but nothing in the
        // app selects it any more.
        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        // PosterKit's selection (`tweak_compiler.py`'s `_compile_posterkit`)
        // rides its own container pull, not the PosterBoard page, so a run can
        // carry it and nothing else. Read once here: the guard below, the
        // separation guard, and the staging all need it.
        let posterKitOptions: [String: TweakValue]
        if let posterKit = TweakCatalog.byID["PosterKitOverrides"], selection.isOn(posterKit),
           case .dictionary(let options) = selection.value(for: posterKit) {
            posterKitOptions = options
        } else {
            posterKitOptions = [:]
        }

        guard !tweakPayloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive || templates.usesDomains || !posterKitOptions.isEmpty else {
            throw GoldenNuggetError("Nothing to apply: no tweak is enabled (or every enabled one "
                + "was skipped), skip setup is off, the status bar is untouched, there is "
                + "nothing selected on the PosterBoard page, and no template delivers through a "
                + "backup domain.")
        }
        log("Tweaks: \(tweakPayloads.count) file(s) from \(compiled.locations.count) plist(s)")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("Skip setup: \(skipSetup.payloads.count) file(s) ahead of the tweaks")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        // The apply mode picks the mechanism, and it is the user's choice: the
        // backup path below and the AirLift path install the same wallpapers two
        // different ways, and neither can stand in for the other. The mode's
        // constraints are checked *here*, before `prepareRun`, so a selection the
        // chosen mode cannot honour fails without paying for a tunnel first.
        let modeIdentity = await DeviceIdentity.read()
        let posterBoardMode = PosterBoardApplyModeSettings.resolved(
            deviceVersion: modeIdentity.version.isEmpty ? deviceVersion : modeIdentity.version,
            buildVersion: modeIdentity.buildVersion)
        let hasPosterBoardTemplates = templates.templates.contains { $0.isPosterBoard && !$0.requiresSparserestore }
        if (posterBoard.isActive || hasPosterBoardTemplates) && posterBoardMode == .airlift {
            try checkAirliftCanApply(posterBoard: posterBoard,
                templates: templates.templates.filter { $0.isPosterBoard && !$0.requiresSparserestore },
                deviceVersion: deviceVersion, buildVersion: modeIdentity.buildVersion)
        }

        // A reset and a wallpaper selection cannot ride the same run, and the
        // reference's own code is why: `apply_tweak` returns on its reset branch
        // before it ever reads the packs, so such a run empties the store and
        // installs none of the wallpapers the page still shows as selected. This
        // port inherits that shape, and the reset survives a failed run (it is
        // cleared only when an apply succeeds), so the two really can be armed at
        // once without the user meaning to — a run that then succeeded would read
        // as "applying wallpapers erased every wallpaper". Refuse, and name both
        // halves instead of silently preferring the destructive one.
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            let carriesWallpapers = !posterBoard.tendies.isEmpty || posterBoard.video != nil
                || hasPosterBoardTemplates
            if carriesWallpapers {
                throw GoldenNuggetError("The PosterBoard page has a reset armed "
                    + "(\(posterBoard.describe)) together with wallpapers selected. A reset run "
                    + "installs no wallpapers — it clears the store and returns before the packs "
                    + "are read — so applying this would wipe every wallpaper and add none. Turn "
                    + "the reset off to install the wallpapers, or unselect them to run the reset.")
            }
            log("PosterBoard: \(posterBoard.describe) — this run clears the store and installs "
                + "nothing.")
        }

        // PosterKit staging edits the *live* wallpaper archives it pulls, so a
        // wallpaper import would overwrite the very files these edits land in,
        // and a reset run returns before the archives are even read — the
        // reference refuses both (`tweak_compiler.py:135`).
        if !posterKitOptions.isEmpty {
            if posterBoard.isActive || templates.isActive {
                throw GoldenNuggetError("Apply PosterKit settings separately from wallpaper "
                    + "imports and resets.")
            }
            log("PosterKit: \(posterKitOptions.count) setting(s)")
        }

        // Templates, if the page has any.  Two routes, and which one a template
        // takes is decided by its own `domain` — `templates_tweak.apply_tweak`
        // makes the same split: a PosterBoard template rides the wallpapers, and
        // everything else is walked here into payloads.
        var templatePayloads: [TweakPayload] = []
        var posterBoardTemplates: [TemplateFile] = []
        if templates.isActive {
            log("Templates: \(templates.describe)")
            // ReplaceOption URLs belong to the current selection. Keep their
            // staging files available for this apply and any subsequent retry.
            for entry in templates.undeliverable {
                log("  ⚠️ \(entry.template.title) was not delivered: \(entry.reason)")
            }
            let deliverable = templates.templates.filter { !$0.requiresSparserestore }
            let work = AppPaths.templatesWorkDirectory
            try? FileManager.default.removeItem(at: work)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            } catch {
                throw GoldenNuggetError("Could not create the template working directory "
                    + "(\(work.lastPathComponent)): \(error.localizedDescription)")
            }
            for template in deliverable {
                if template.isPosterBoard {
                    // Left for `PosterBoard.compile`: its extracted tree has to
                    // be walked by `PosterBoardBuilder`, which is what turns a
                    // descriptor into a wallpaper.
                    posterBoardTemplates.append(template)
                    log("  → \(template.title): rides with the wallpapers (domain "
                        + "\(template.domain))")
                    continue
                }
                log("  → \(template.title): \(template.effectiveDomain)")
                templatePayloads += try TemplateDelivery.payloads(
                    for: template, into: work, log: { AppLog.write($0) })
            }
            if !templatePayloads.isEmpty {
                let total = templatePayloads.reduce(0) { $0 + $1.byteCount }
                log("Templates: \(templatePayloads.count) payload(s) ("
                    + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                    + ")")
            }
        }

        let udid = try await prepareRun()
        // Resolved once, here, because two stages need it: the PosterBoard compile (its
        // reset preferences change at 26.4) and the manifest-format fork inside
        // `deliver`.  `resolvedDeviceVersion` carries the reasoning for refusing to
        // guess — a device whose version cannot be read must not be treated as iOS 26.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the manifest-format fork: \(version) (major \(major))")

        // PosterBoard, if the page has anything. Two mechanisms, chosen above:
        // the store's database first — a wallpaper exists only once it has a row in
        // it — and then the wallpapers themselves, unless AirLift is doing it, in
        // which case there is no database and no payload: the injection into the
        // container *is* the apply.
        var posterBoardPayloads: [TweakPayload] = []
        var posterBoardSnapshotDirectory: URL?
        var posterBoardInjectedOverAirlift = false
        if (posterBoard.isActive || !posterBoardTemplates.isEmpty) && posterBoardMode == .airlift {
            log("PosterBoard: \(posterBoard.describe) — over AirLift, no backup")
            try await applyPosterBoardOverAirlift(selection: posterBoard,
                                                 templates: posterBoardTemplates, deviceVersion: version)
            posterBoardInjectedOverAirlift = true
        } else if posterBoard.isActive || !posterBoardTemplates.isEmpty {
            // A PosterBoard template is a wallpaper source even when no pack and
            // no video were picked, so it opens this branch by itself — the
            // reference's `apply_tweak` does the same (`len(tendies) == 0 and
            // len(templates) == 0 and videoFile == None` is the only early
            // return, and `templates` is one of the three terms).
            if posterBoard.isActive {
                log("PosterBoard: \(posterBoard.describe)")
            } else {
                log("PosterBoard: \(posterBoardTemplates.count) template(s) and nothing else")
            }
            var structureVersion = PosterBoard.fallbackStructureVersion
            var database: URL?
            var preservedPosterBoardFiles: [TweakPayload] = []
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                // Resets synthesize their own store state; additions, including
                // template-only descriptors, must start with the device's database.
                log("PosterBoard: reset only — no database is needed, and none is fetched.")
            } else {
                let fetched = try await PosterBoardBackup.fetch(
                    backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                    ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                    preserveExisting: true,
                    onProgress: { overall in
                        self.logProgress("posterboard backup progress", overall)
                    },
                    log: { AppLog.write($0) })
                posterBoardSnapshotDirectory = fetched.snapshotDirectory
                database = fetched.database
                preservedPosterBoardFiles = fetched.preservedPayloads
                log("PosterBoard: preserving \(preservedPosterBoardFiles.count) existing container file(s)")
                structureVersion = fetched.structureVersion
            }
            posterBoardPayloads = try await PosterBoard.compile(
                selection: posterBoard,
                templates: posterBoardTemplates,
                structureVersion: structureVersion,
                database: database,
                preservedPayloads: preservedPosterBoardFiles,
                includeSnapshotFiles: posterBoardSnapshotDirectory == nil,
                deviceVersion: version,
                workingDirectory: PosterBoard.workDirectory,
                log: { AppLog.write($0) })
            let onDisk = posterBoardPayloads.filter { $0.source != nil }.count
            let total = posterBoardPayloads.reduce(0) { $0 + $1.byteCount }
            log("PosterBoard: \(posterBoardPayloads.count) payload(s), \(onDisk) of them on disk "
                + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        }

        // PosterKit staging (`_compile_posterkit`): the guard above already
        // refused a run that also imports wallpapers, resets, or templates, so
        // this pulls its own snapshot of the live container and edits the
        // wallpaper configuration archives in place. `preserveExisting` is
        // what turns the pull into the relativePath↔file pairs `stage` walks.
        var posterKitPayloads: [TweakPayload] = []
        if !posterKitOptions.isEmpty {
            log("PosterKit: fetching current wallpaper configurations…")
            let fetched = try await PosterBoardBackup.fetch(
                backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                preserveExisting: true,
                onProgress: { overall in
                    self.logProgress("posterkits backup progress", overall)
                },
                log: { AppLog.write($0) })
            posterKitPayloads = try PosterKitStaging.stage(
                options: posterKitOptions,
                preservedPayloads: fetched.preservedPayloads,
                log: { AppLog.write($0) })
            features.insert("PosterBoard")
        }

        // Skip setup, then the tweaks, then the status bar, then the wallpapers: one
        // array, one pass through the injector, which derives the directory rows from
        // each payload's path.  The order is the reference's — `add_skip_setup`
        // ahead of the tweaks, and `apply_classic_tweak` / `apply_ios27_tweak`
        // before the wallpapers — and it only actually matters for the two
        // skip-setup files, which land in the order they are appended.
        let payloads = skipSetup.payloads + tweakPayloads + statusBarPayloads
            + posterBoardPayloads + templatePayloads + posterKitPayloads

        // Wallpapers-only run in AirLift mode: the injection already happened and
        // it resprings on its way out, so running the backup/restore tail here
        // would buy a full protective pull for an empty payload list.
        if payloads.isEmpty && posterBoardInjectedOverAirlift {
            log("Apply succeeded: the wallpapers are in PosterBoard's container and it has "
                + "resprung — no backup was taken.")
            return
        }

        try await deliver(payloads: payloads, udid: udid, version: version, label: "apply",
                          posterBoardSnapshot: posterBoardSnapshotDirectory) {
            log("Apply succeeded: the device confirmed it finished.")
            log("Reboot the device so the injected preferences take effect.")
            if posterBoardInjectedOverAirlift {
                log("The wallpapers went in over AirLift and are already live; only the tweaks "
                    + "above needed the reboot.")
            } else if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                log("The PosterBoard store was cleared. Reboot the device, then add wallpapers "
                    + "from a fresh database fetch — a reset makes the copy fetched before it "
                    + "stale.")
            } else if posterBoard.isActive {
                log("Reboot the device so the PosterBoard store picks the new wallpapers up.")
            }
        }
        do { try CommunityApplyRecord.record(communityPayloads, udid: udid) }
        catch { log("Community apply history could not be saved: \(error.localizedDescription)") }
    }

    func resetCommunityTweaks() async throws {
        try await loggedRun("community reset") {
            clearCancel()
            clearProgress()
            let udid = try await prepareRun()
            let version = try await resolvedDeviceVersion("")
            let plan = try CommunityApplyRecord.resetPlan(udid)
            for path in plan.remaining { log("Community file requires manual recovery: \(path)") }
            guard !plan.payloads.isEmpty else {
                throw GoldenNuggetError("No recorded Managed Preferences to reset. Other replaced files require manual recovery: \(plan.remaining.joined(separator: ", "))")
            }
            try await deliver(payloads: plan.payloads, udid: udid, version: version, label: "community reset") {
                log("Community Managed Preferences reset. Reboot the device.")
            }
            try CommunityApplyRecord.didReset(udid)
        }
    }

    /// Refuse a selection the AirLift path cannot carry, before anything is opened.
    ///
    /// A reset is a store operation and the video stage's frames are computed for
    /// the restore, so neither can travel a container write. Saying so up front is
    /// the alternative to accepting the selection and quietly dropping half of it.
    private func checkAirliftCanApply(posterBoard: PosterBoardSelection,
                                     templates: [TemplateFile] = [], deviceVersion: String, buildVersion: String = "") throws {
        if templates.contains(where: \.isContainer) {
            throw GoldenNuggetError("AirLift only installs template descriptors. A selected template "
                + "also carries container files; switch to \"Protective backup\" to apply all of them.")
        }
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("AirLift cannot reset the PosterBoard store — it only adds "
                + "wallpapers. Switch the apply mode to \"Protective backup\" for a reset.")
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("AirLift cannot apply a PosterBoard video: its frames are "
                + "staged for a restore. Switch the apply mode to \"Protective backup\".")
        }
        let reason = Airlift.unsupportedReason(deviceVersion: deviceVersion, buildVersion: buildVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("AirLift needs a pairing record and none is stored. Import one "
                + "on the home page first.")
        }
    }

    /// Run the AirLift PosterBoard injection, reporting through the run log.
    private func applyPosterBoardOverAirlift(selection: PosterBoardSelection,
                                             templates: [TemplateFile] = [],
                                             deviceVersion: String) async throws {
        log("⚠️ PosterBoard AirLift is deprecated; Protective backup is the supported path.")
        try await PosterBoardAirlift.apply(
            selection: selection,
            templates: templates,
            structureVersion: PosterBoard.fallbackStructureVersion,
            deviceVersion: deviceVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("posterboard airlift", overall) }
        )
    }

    /// Fetch only the device's PosterBoard database, without applying anything.
    ///
    /// The page's own action, and the reference has the same one (its "Fetch
    /// Database File" wizard in `pb_dialog.py`) for the same reason: the fetch is
    /// the one stage of a wallpaper apply that can fail on its own terms — the
    /// device decides whether it will upload the container — so being able to run
    /// it alone, watch it, and retry is worth a button. The result is cached at
    /// `PosterBoardBackup.cachedDatabase(udid:)`, and an apply reuses nothing:
    /// it fetches its own, because a copy fetched before a reset is stale.
    func fetchPosterBoardDatabase() async throws {
        try await loggedRun("posterboard database fetch") {
            try await fetchPosterBoardDatabaseRun()
        }
    }

    private func fetchPosterBoardDatabaseRun() async throws {
        AppLog.shared.resetForNewRun()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard database fetch")
        defer { stage.done() }

        let udid = try await prepareRun()
        _ = try await PosterBoardBackup.fetch(
            backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
            onProgress: { overall in self.logProgress("posterboard backup progress", overall) },
            log: { AppLog.write($0) })
        log("PosterBoard database fetched and validated.")
    }

    /// Inject the PosterBoard packs over AirLift, and nothing else.
    ///
    /// The home page's Apply is one combined run — tweaks and wallpapers ride
    /// together through a single protective backup — which is right for a
    /// backup-mode selection and wrong for this one: AirLift writes the
    /// descriptors straight into the container, so a run that carries nothing
    /// but wallpapers should not buy a backup at all. That early return lives
    /// in the combined path and is reached only when no tweak is selected, so
    /// this is the same injection on its own, with no payloads to deliver and
    /// no mode switch to remember.
    ///
    /// - Parameters:
    ///   - selection: the page's selection. Only its packs are honoured, exactly
    ///     as in the combined run.
    ///   - deviceVersion: what the page already read; the constraints are checked
    ///     against it rather than resolved again over a second connection.
    func applyPosterBoardViaAirlift(_ selection: PosterBoardSelection,
                                    deviceVersion: String) async throws {
        try await loggedRun("posterboard airlift apply") {
            try await applyPosterBoardViaAirliftRun(selection, deviceVersion: deviceVersion)
        }
    }

    private func applyPosterBoardViaAirliftRun(_ selection: PosterBoardSelection,
                                               deviceVersion: String) async throws {
        AppLog.shared.resetForNewRun()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard airlift apply")
        defer { stage.done() }

        try await HotLoadService.requireAllowed(features: ["PosterBoard"])
        let identity = await DeviceIdentity.read()
        try checkAirliftCanApply(posterBoard: selection,
            deviceVersion: identity.version.isEmpty ? deviceVersion : identity.version,
            buildVersion: identity.buildVersion)
        log("PosterBoard: \(selection.describe) — over AirLift, no backup")
        try await applyPosterBoardOverAirlift(selection: selection, deviceVersion: deviceVersion)
        log("PosterBoard: injected over AirLift and resprung. No backup was taken, and no "
            + "tweak was delivered — the home page's Apply is what delivers those.")
    }

    // MARK: - The shared delivery tail
    //
    // Both applies end in the same four stages, and the order is load-bearing:
    // the manifest-format fork decides whether there is anything to prune, the
    // pull is what authorizes the session, the prune must precede the injection,
    // and the restore is what delivers any of it.

    /// One payload set through stages 1–4.  `udid` and `version` come from the caller:
    /// the PosterBoard stage talks to the device (and needs the version) before this
    /// runs, so resolving them again here would be a second answer to a settled question.
    private func deliver(
        payloads: [TweakPayload],
        udid: String,
        version: String,
        label: String,
        posterBoardSnapshot: URL? = nil,
        onSuccess: () -> Void
    ) async throws {
        // The two versions take opposite paths, and the split is the
        // reference's one-line fork (`backup.py:113`) widened to the whole run:
        // iOS 26 speaks legacy MBDB and can have a backup built for it from
        // nothing, iOS 27+ speaks the modern sqlite Manifest.db and must keep
        // the device's own state. Comparing "26.0" against "27.0" lexically
        // would put 26.9 on the wrong side, so compare the major component.
        //
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        // Development mode can force the iOS 26 branch, so the reported version is no
        // longer the last word on which branch runs -- only the default for it. Read
        // once, here, and both decisions below quote the same snapshot.
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore
        let hasEligibility = payloads.contains { $0.domain == "SysContainerDomain-com.apple.eligibilityd" }
        if hasEligibility && !ios27 {
            throw GoldenNuggetError("Siri AI overrides require an unencrypted protective backup. Disable forced partial restore and retry.")
        }
        // Reported before the fork, because this number *is* the fork: the
        // branch lines below say where the run went, this says why.
        log("device version for the manifest-format fork: \(version) (major \(major))")
        if dev.forcePartialRestore {
            log("development mode: forcing the iOS 26 branch on a major \(major) device "
                + "-- no protective backup will be pulled")
        }

        // iOS 26: a Partial Restore, built rather than pulled -- an empty device
        // directory, the host-side manifests, then this run's rows. Nothing was
        // pulled, so there is no device state to reconcile against and the
        // prune would only discard what this run just wrote.
        //
        // iOS 27: the protective backup, pulled from the device, then pruned to
        // what is on disk before injection. A synthesized manifest is not enough
        // here: `restored` rejects a domain it cannot resolve ("Failed to
        // prepare INSERT for ManagedPreferencesDomain") because the real one
        // carries the device's own domain registration.
        // Media backup is part of *every* apply, on both device branches and
        // regardless of any development switch. It uses the photo-library
        // permission, so it needs no tunnel and only exports assets that are new
        // or changed since the last apply.
        clearProgress()
        log("Photos: backing up new and changed media…")
        await photoMediaBackup()

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled")
            backupRoot = try await protectiveBackup(udid: udid)
            if hasEligibility {
                let manifestURL = backupRoot.appendingPathComponent(udid).appendingPathComponent("Manifest.plist")
                let data = try Data(contentsOf: manifestURL)
                let manifest = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard manifest?["IsEncrypted"] as? Bool == false else {
                    throw GoldenNuggetError("Siri AI overrides require a confirmed unencrypted protective backup. Disable local backup encryption in Finder/iTunes and retry.")
                }
            }
            prune = true
            // AFC is an optional extra backup, never the apply's media path. It
            // is the only way to remove originals after a verified copy, but a
            // run is not the place to do that: the Media page offers it with a
            // count and a free-space figure in front of the user. This pull is
            // therefore always non-destructive, and off unless asked for.
            if dev.useAfcMediaBackup {
                clearProgress()
                log("AFC media: optional backup requested (Dev.UseAfcMediaBackup)")
                await mediaBackup(deletingOriginals: false)
            }
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        clearProgress()
        log("Pruning and injecting tweaks…")
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            posterBoardSnapshot: posterBoardSnapshot,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: label,
                             onSuccess: onSuccess)
    }

    /// Put the named pages back to stock, on the device.
    ///
    /// A port of `device_manager.reset_tweaks` (`device_manager.py:1104`): a
    /// fixed set of files written over the device's own, with nothing read back
    /// first — no psysbackup capture, on either branch. The page set comes from
    /// the picker the reference's `ResetDialog` offers, not from this app's
    /// tweak selection; the two are unrelated, and the reference's dialog is
    /// likewise built from `get_resettable_pages`, not from what is enabled.
    ///
    /// It is the same pipeline as `applyTweaks` with a different payload list, so
    /// it reuses `protectiveBackup` / `partialRestore` / `pruneAndInject` /
    /// `runRestore` rather than growing a second restore path. The two branches
    /// differ in what a nulled file is written as (0 bytes vs. a valid empty
    /// plist — `TweakReset` has the table and the reason) and in which manifest
    /// the run needs, for the same reason the apply forks:
    ///
    /// * **iOS 27+** speaks the modern sqlite `Manifest.db` and rejects a
    ///   synthesized one ("Failed to prepare INSERT for ManagedPreferencesDomain"
    ///   — the real one carries the device's own domain registration), so the
    ///   reset pulls the protective backup and prunes it, exactly as an apply
    ///   does. It does **not** pull media: a reset is a preferences operation and
    ///   the backup filter rejects the media domains anyway.
    /// * **iOS 26** speaks legacy MBDB and can have a backup built for it from
    ///   nothing, so the reset synthesises one.
    ///
    /// What is deliberately absent is the reference's `clear_lastapply`: it drops
    /// the apply record so a later apply does not skip Phase 2 against a reset
    /// device, and there is no phase-2 skip in this port to guard. The app's own
    /// selection is left alone too, exactly as the reference leaves the tweaks
    /// page as the user had it — the reset is of the *device*, and the selection
    /// is what would put the tweaks back.
    func resetPages(pages: Set<ResetPage>) async throws {
        try await loggedRun("page reset") { try await resetPagesRun(pages: pages) }
    }

    private func resetPagesRun(pages: Set<ResetPage>) async throws {
        try await HotLoadService.requireAllowed(features: Set(pages.map(\.title)))
        AppLog.shared.resetForNewRun()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN page reset")
        defer { runStage.done() }

        guard !pages.isEmpty else {
            throw GoldenNuggetError("No page was selected — nothing to reset.")
        }

        let udid = try await prepareRun()

        // Read the version here for the same reason the apply does: the pages
        // read it before lockdown answers, so a value of "" would put a 27
        // device on the 26 branch and hand it 0-byte plists.
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        let plan = TweakReset.plan(pages: pages, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("Every selected page resolved to no file — nothing to reset.")
        }

        // The reference appends the skip-setup files to the *reset's* file list
        // too (`add_skip_setup(files_to_restore, uses_domains)`, called after the
        // null loop and before `start_restore`), subject to its own gate — which
        // on iOS 27 only passes when the file list already restores real domains,
        // and in the reset path that means the Daemons page was ticked. Reproduced
        // as written; see `TweakReset.skipSetupAllowed(pages:ios27:)`.
        let skipSetupOn = SkipSetupSettings.shared.skipSetupEnabled
        let skipSetup: SkipSetup.Build
        if !skipSetupOn {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
        } else if plan.skipSetupAllowed {
            skipSetup = SkipSetup.build(supervised: false, organizationName: "")
        } else {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
            log("Skip Setup is on, but the reference omits its two files here: on iOS 27 "
                + "the reset restores no real domain unless the Daemons page is ticked, "
                + "and that is its `add_skip_setup` condition. Tick Daemons, or reset on "
                + "iOS 26, to include them.")
        }

        log("Reset: \(pages.count) page(s) — \(plan.targets.count) file(s) on iOS \(version)")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) bytes]")
        }
        for item in plan.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        for page in ResetPage.allCases where pages.contains(page) {
            log("  page \(page.title): \(page.locations.count) file(s)")
        }
        if ios27 {
            log("iOS 27 branch: a nulled file is written as a valid empty plist, not 0 bytes — "
                + "a truncated plist is a SpringBoard boot loop on this release. Nothing is read "
                + "back from the device first: this is the reference's own no-capture fallback, "
                + "not a psysbackup restore of the original values.")
        } else {
            log("iOS 26 branch: a nulled file is written as 0 bytes, over a synthesised MBDB "
                + "backup (no device content pulled).")
        }

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled, then pruned")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            // Same order as the reference's file list: the daemons file first, then
            // the nulled ones, then the two skip-setup files last — the reference
            // calls `add_skip_setup` after the null loop.
            tweakPayloads: plan.payloads + skipSetup.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "page reset") {
            log("Reset succeeded: the device confirmed it finished.")
            log("The pages above are back to their defaults. The selections in this app are "
                + "untouched — applying again would write the tweaks back.")
            log("Reboot the device so the restored files take effect.")
        }
    }

    /// The media stage of an apply: a native photo-library backup, always run.
    ///
    /// A failure is logged, not thrown. The store is a copy, not a precondition
    /// for writing preferences, and a media failure must not cost the user the
    /// tweak run they started.
    private func photoMediaBackup() async {
        PhotoMediaBackup.ensureService()
        // A background copy owns the same store. Keep what it has already saved
        // instead of turning a normal collision into a FAILED line.
        guard !AfcMediaBackup.isTransferActive else {
            log("Photos: a media copy is still running — this apply keeps what the "
                + "store already has")
            clearProgress()
            return
        }
        do {
            let manifest = try await PhotoMediaBackup.backup { line in AppLog.write(line) }
            log("Photos: \(manifest.entries.count) file(s) in the store, ready to restore")
        } catch {
            log("Photos: FAILED — \(error.localizedDescription)")
        }
        clearProgress()
    }

    /// The optional AFC stage, kept only for users who want a second copy of
    /// the device's Media tree. It never deletes an original on an apply.
    private func mediaBackup(deletingOriginals: Bool) async {
        guard !AfcMediaBackup.isTransferActive else {
            log("AFC media: a background pull is still running — this run keeps what the "
                + "store already has")
            clearProgress()
            return
        }
        do {
            let survey = try await AfcMediaBackup.survey()
            guard !survey.files.isEmpty else {
                log("AFC media: nothing in \(AfcMediaBackup.trees.joined(separator: "/")) "
                    + "— skipped")
                return
            }
            log("AFC media: pulling \(survey.files.count) file(s), \(survey.bytes) byte(s)")
            let manifest = try await AfcMediaBackup.pull(deletingOriginals: deletingOriginals) {
                AppLog.write($0)
            }
            let removed = manifest.entries.filter(\.deleted).count
            log("AFC media: stored \(manifest.entries.count) file(s), \(removed) removed "
                + "from the device")
        } catch {
            log("AFC media: FAILED — \(error.localizedDescription)")
        }
        clearProgress()
    }

    // MARK: - Media facade

    /// One automatic backup at a time, whoever asked for it.
    private static let mediaBackupLock = NSLock()
    private static var mediaBackupInFlight = false
    /// When the last automatic backup started, for the rate limit below.
    private static var lastAutomaticMediaBackup: Date?
    /// An hour between automatic backups. They are top-ups, not runs: the home
    /// page is rebuilt on every selection in a split view, and each rebuild must
    /// not mean another walk of the photo library. An apply always backs up as
    /// well, so this is only the between-applies convenience copy.
    private static let automaticMediaBackupInterval: TimeInterval = 3600

    /// Back up the photo library into the app container without a tweak run.
    ///
    /// The store is what "Restore media" writes back, and a store that only
    /// fills when the user remembers an apply is empty exactly when it is
    /// needed — after a reset, when there is no photo left on the device. So the
    /// setup guide finishing starts one and every launch tops it up. The second
    /// call is cheap: unchanged assets are not exported again.
    ///
    /// Deliberately **not** fatal and deliberately not a run: it holds no
    /// `InFlightCall` reservation, so pressing Apply still works while it
    /// streams, and every outcome — including a denied permission — is a log
    /// line rather than an error on the page.
    ///
    /// - Parameters:
    ///   - reason: what asked for this, quoted in the log so two callers can be
    ///     told apart in a bug report.
    ///   - force: skip the one-per-hour limit, for the setup step the user just
    ///     took rather than a page being rebuilt.
    func startAutomaticMediaBackup(reason: String, force: Bool = false) {
        PhotoMediaBackup.ensureService()
        guard !InFlightCall.shared.isRunActive else {
            log("Photos: automatic backup skipped (\(reason)) — a run owns the store")
            return
        }
        Self.mediaBackupLock.lock()
        if Self.mediaBackupInFlight {
            Self.mediaBackupLock.unlock()
            log("Photos: automatic backup already running — \(reason) started no second one")
            return
        }
        if !force, let last = Self.lastAutomaticMediaBackup,
           Date().timeIntervalSince(last) < Self.automaticMediaBackupInterval {
            Self.mediaBackupLock.unlock()
            return
        }
        Self.lastAutomaticMediaBackup = Date()
        Self.mediaBackupInFlight = true
        Self.mediaBackupLock.unlock()
        log("Photos: automatic backup started (\(reason)) — new and changed media is copied "
            + "into the container so Restore media can put it back")

        Task { [weak self] in
            defer { Self.finishAutomaticBackup() }
            guard let self else { return }
            do {
                let manifest = try await PhotoMediaBackup.backup { line in AppLog.write(line) }
                let stored = manifest.entries.reduce(0) { $0 + $1.size }
                self.log("Photos: automatic backup finished — \(manifest.entries.count) file(s), "
                    + "\(ByteCountFormatter.string(fromByteCount: stored, countStyle: .file)) "
                    + "in the container, ready for Restore media")
            } catch {
                self.log("Photos: automatic backup FAILED — \(error.localizedDescription); "
                    + "the store keeps what it already has")
            }
        }
    }

    /// Synchronous so `NSLock` is not used from an async context (an error in
    /// Swift 6 language mode); called only from the backup task's `defer`.
    private static func finishAutomaticBackup() {
        mediaBackupLock.lock()
        mediaBackupInFlight = false
        mediaBackupLock.unlock()
    }

    /// Put the container's photos and videos back into the photo library.
    ///
    /// The counterpart of the automatic backup, and the one button the user is
    /// expected to press: after a reset — or after reinstalling the app's data —
    /// this creates new assets from the verified copies with the native Photos
    /// permission. No AFC write, gateway or device path is involved. Runs as a
    /// run (`InFlightCall`), so it cannot overlap with an apply.
    func restoreMedia() async throws {
        try await loggedRun("media restore") {
            PhotoMediaBackup.ensureService()
            // A backup writes the same store. The transfer lock would reject a
            // concurrent restore with a generic "busy"; say what is happening.
            guard !AfcMediaBackup.isTransferActive else {
                throw GoldenNuggetError("A media backup is still running. "
                    + "Restore media can start once it finishes — what it has copied so "
                    + "far is already kept.")
            }
            guard PhotoMediaBackup.restorableCount > 0 else {
                throw GoldenNuggetError(
                    "The media store is empty — there is nothing to put back. Every apply "
                    + "backs up the photo library, and the Media page can back it up by hand.")
            }
            log("Photos: restoring the stored media into the photo library")
            try await PhotoMediaBackup.restore { line in AppLog.write(line) }
            log("Photos: restore finished — the local copies stay in the container "
                + "until the Media page empties them")
        }
    }

    // MARK: - Protective flow stages
    //
    // The full flow, kept in one place because the order is load-bearing.

    /// Stage 1: the working backup, into `<Documents>/<udid>/`.
    ///
    /// A Partial Restore, so it is built rather than pulled: an empty device
    /// directory, then the host-side manifests, then this run's rows and
    /// payloads. There is no user content to preserve and nothing to wipe, which
    /// is why the reference's three-phase flow (and its safe-state recovery) has
    /// no part here on iOS 26 -- the restore lands on the live device.
    private func partialRestore(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        log("Partial Restore: synthesising backup at \(backupRoot.lastPathComponent) "
            + "(no device content pulled)")
        return backupRoot
    }

    /// A real protective backup into `<Documents>/<udid>/`.
    private func protectiveBackup(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            self.logProgress("backup progress", overall)
        }
        log("Protective backup complete.")
        clearProgress()
        return backupRoot
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// Everything a run does before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root).  Throws
    /// `GoldenNuggetError` for the operator-facing failures.
    private func prepareRun() async throws -> String {
        try await HotLoadService.requireAllowed()
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer is not ready. Ensure WiFi and a working tunnel (LocalDevVPN or WireGuard + em_proxy), then select a pairing file.")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Tunnel: \(Tunnel.describe())")
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        return udid
    }

    /// The version the manifest-format fork branches on — never a guess.
    ///
    /// An empty `fallback` means "the page never managed to read it" (it reads
    /// once, when it appears, and lockdown may not have been answering yet), and
    /// **not** "iOS 26". Parsing it as 0 used to send a 27.0 device down the
    /// legacy branch, which cannot work there: that branch synthesises a backup
    /// from nothing, and what the device answers is
    /// `MBErrorDomain/205 — No keybag in manifest` (2026-09-26).
    ///
    /// So re-read lockdown — `prepareRun()` has just shown it is ready — and
    /// refuse to continue if even that fails. Refusing beats defaulting: the two
    /// branches want different manifest formats, and a wrong pick costs the
    /// operator a whole run plus a puzzle like this one.
    private func resolvedDeviceVersion(_ fallback: String) async throws -> String {
        if !fallback.isEmpty { return fallback }
        log("device version: the caller had none (it read the identity before lockdown answered) "
            + "— re-reading before the format fork")
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else {
            throw GoldenNuggetError(
                "Could not read the device's iOS version (lockdown ProductVersion), which this run "
                + "needs to choose a manifest format: iOS 27+ gets a protective backup pulled from the "
                + "device with a sqlite Manifest.db, iOS 26 a legacy MBDB backup synthesised on the "
                + "host. Unlock the device, confirm the tunnel is up, then run again.")
        }
        log("device version: lockdown answered \(identity.version)")
        return identity.version
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        clearProgress()
        log("Restoring backup… (this is the stage that finalizes on the device)")
        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("restore returned \(code) without confirming completion — inspect the log above.")
        }
    }

    // MARK: - Readiness

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }
}
