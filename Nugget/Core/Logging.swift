import Foundation

/// A destination for one already-formatted log line.
///
/// The engine used to log through `GoldenNuggetEngine.shared.log`, which made every
/// helper that merely wanted to say something — the stage timer, the heartbeat,
/// the stall guard, the wire tailer — depend on the whole engine type.  A narrow
/// sink is what lets those helpers move out of it.
protocol LogSink: AnyObject, Sendable {
    func write(_ line: String)
}

/// `<Documents>/goldennugget.log` — append-only sink, rotated by dropping the older half.
///
/// The on-screen list alone is not enough: it only ever shows the tail and dies
/// with the process, so anything written there (the host-side delegate
/// decisions, the commit accounting, the stall verdict) would be unshareable.
/// A failed run has to be diagnosable from a file.
final class RotatingFileSink: LogSink, @unchecked Sendable {
    /// Byte cap; the sink is rotated by dropping the older half once exceeded.
    static let defaultLimit: UInt64 = 2 * 1024 * 1024

    private let url: URL
    private let limit: UInt64
    private let lock = NSLock()

    init(url: URL, limit: UInt64 = RotatingFileSink.defaultLimit) {
        self.url = url
        self.limit = limit
    }

    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)
            .map { $0.uint64Value } ?? 0
        if size > limit, let existing = try? Data(contentsOf: url) {
            // Keep the newer half — a long run logs continuously and the tail is
            // the part that matters.
            try? existing.suffix(Int(limit / 2)).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Current size on disk, for the share-sheet labels.
    func size() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Keeps the whole run in memory for the UI list and the diagnostics tail.
///
/// Unbounded on purpose: the engine is the producer and a run is bounded by
/// human patience, while the VIEW keeps its own 600-line window for rendering.
/// Capping here instead would silently truncate the diagnostics tail.
final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(n).joined(separator: "\n")
    }

    func reset() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}

/// One coalescing rule for a known family of detail lines.
private struct AppLogFamilyRule {
    let label: String
    /// Keep the first line of a family, then one in every `cadence` lines, so a
    /// long run still shows that the family is moving without listing every file.
    let cadence: Int
    /// Emit one counted marker after this many lines were actually omitted.
    let summaryEvery: Int
}

/// The concise-log policy for `goldennugget.log` and the in-app run log.
///
/// Apply used to produce thousands of nearly identical lines — one per photo,
/// one per AFC file, one per backup placeholder, one per AirLift callback, plus
/// a fresh diagnostics dump on every retry. They are useful in the device
/// console, but in the app they push the single actionable line ("apply failed:
/// …") off the screen and fill the 2 MiB file before the failure is written.
///
/// This filter sits at the fan-out point rather than at the call sites: the 98
/// `AppLog.write` callers keep their exact wording, the scripts that grep the
/// file keep their anchors, and the raw stream stays on the console via the
/// unfiltered `print` in `AppLog.log`. Only families that are known to be
/// high-volume are coalesced; anything unrecognised passes through verbatim.
private final class AppLogConciseFilter: @unchecked Sendable {
    private struct State {
        var seen = 0
        var lastEmit = 0
        var lastSummary = 0
    }

    private static let rules: [String: AppLogFamilyRule] = [
        "photos.files": .init(label: "Photos file", cadence: 10, summaryEvery: 50),
        "afc.files": .init(label: "AFC media file", cadence: 10, summaryEvery: 50),
        "backup.progress": .init(label: "backup progress", cadence: 4, summaryEvery: 20),
        "restore.progress": .init(label: "restore progress", cadence: 4, summaryEvery: 20),
        "wait": .init(label: "wait observation", cadence: 3, summaryEvery: 20),
        "placeholder": .init(label: "placeholder", cadence: 20, summaryEvery: 100),
        "commit": .init(label: "commit", cadence: 20, summaryEvery: 100),
        "airlift": .init(label: "AirLift library", cadence: 20, summaryEvery: 100),
        // A diagnostics block or Rust excerpt is a multi-line snapshot. The
        // first one in a run is kept; repeating it on every retry is what made
        // apply failures unreadable.
        "diagnostics": .init(label: "diagnostics block", cadence: Int.max, summaryEvery: Int.max),
        "rust.excerpt": .init(label: "Rust excerpt", cadence: Int.max, summaryEvery: Int.max),
    ]

    private let lock = NSLock()
    private var states: [String: State] = [:]

    func reset() {
        lock.lock()
        states.removeAll()
        lock.unlock()
    }

    /// Returns the line to fan out, or `nil` when this occurrence was folded
    /// into a counted marker. `forcedFamily` is used by callers that know a
    /// line came from a high-volume trampoline (AirLift) but whose text has no
    /// stable prefix of its own.
    func emittedLine(for raw: String, forcedFamily: String?) -> String? {
        let family = forcedFamily ?? Self.family(for: raw)
        // Snapshots are identified as a family before the error markers they
        // contain: a diagnostics block almost always mentions "failed", but a
        // retry must not append a second copy of it to the app log.
        if let family, family != "diagnostics", family != "rust.excerpt",
           Self.isImportant(raw) { return raw }
        guard let family else { return raw }
        let rule = Self.rules[family]
            ?? AppLogFamilyRule(label: family, cadence: 20, summaryEvery: 100)

        lock.lock()
        defer { lock.unlock() }
        var state = states[family] ?? State()
        state.seen += 1

        if state.seen == 1 || state.seen - state.lastEmit >= rule.cadence {
            state.lastEmit = state.seen
            states[family] = state
            return raw
        }

        let omitted = state.seen - state.lastSummary
        guard omitted >= rule.summaryEvery else {
            states[family] = state
            return nil
        }
        state.lastSummary = state.seen
        states[family] = state
        return "… \(omitted) \(rule.label) detail line\(omitted == 1 ? "" : "s") omitted; "
            + "full text is on the console …"
    }

    /// Lines that must never be coalesced, even when they share a prefix with
    /// a detail family. These are the lines an apply failure is read for.
    private static func isImportant(_ raw: String) -> Bool {
        if raw.contains("⚠️") || raw.contains("❌") { return true }
        let lower = raw.lowercased()
        for marker in ["failed", "fatal", "refused", "aborted", "giving up",
                       "not retrying", "crash", "panic", "FilePickerFix:"] {
            if lower.contains(marker.lowercased()) { return true }
        }
        if raw.hasPrefix("⏱ RUN ") { return true }
        for marker in ["apply succeeded", "reset succeeded", "restore verified",
                       "restore confirmed complete"] {
            if lower.contains(marker) { return true }
        }
        return false
    }

    /// Recognise only the families that actually flood an apply. Everything
    /// else — warnings, payload lists, stage totals, one-off state — is kept.
    private static func family(for raw: String) -> String? {
        if raw.contains("── diagnostics ──") { return "diagnostics" }
        if raw.contains("rust log excerpt") || raw.hasPrefix("Rust log tail,") { return "rust.excerpt" }

        if raw.hasPrefix("Photos: ") {
            // The count and summary lines are the anchors the cost report uses.
            // A per-file line is the one with a filename followed by an em dash.
            if raw.contains("asset(s) in the photo library")
                || raw.contains("new or changed asset(s)")
                || raw.contains("asset(s) already stored")
                || raw.contains("iCloud-only asset(s) skipped")
                || raw.contains("file(s) in the store")
                || raw.hasPrefix("Photos: restoring ")
                || raw.contains("restore finished") { return nil }
            if raw.contains(" — ") { return "photos.files" }
        }

        if raw.hasPrefix("AFC media: ") {
            if raw.contains("file(s) already stored")
                || raw.contains("file(s),")
                || raw.contains("optional backup requested")
                || raw.contains("nothing in")
                || (raw.contains("stored ") && raw.contains("removed ")) { return nil }
            if raw.contains(" — ") || raw.contains("could not remove")
                || raw.contains("could not re-check")
                || raw.contains("changed during transfer") { return "afc.files" }
        }

        if raw.hasPrefix("backup stream:") { return "backup.progress" }
        if raw.hasPrefix("restore progress:") { return "restore.progress" }

        if raw.hasPrefix("⏱ ") && !raw.hasPrefix("⏱ RUN ") {
            // Plain stage timings are kept. Only the repeating observations —
            // heartbeats and stall notices — are coalesced.
            if raw.contains("elapsed —") || raw.contains("has not sent")
                || raw.contains("answered the handshake")
                || raw.contains("device is talking again")
                || raw.contains("nothing for") || raw.contains("still quiet") {
                return "wait"
            }
        }

        if raw.hasPrefix("placeholder: #") || raw.hasPrefix("placeholder: cannot create") {
            return "placeholder"
        }
        if raw.hasPrefix("commit: ") && !raw.contains("file(s) moved into place") {
            return "commit"
        }
        return nil
    }
}

/// Process-wide log fan-out: one `log()` call, N sinks, in order.
///
/// The sinks are installed by this type itself rather than by an owner, because
/// logging is the one dependency every other layer has — a helper that logs
/// before the engine exists must still land in `goldennugget.log`.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    let memory = MemoryLogSink()
    let file = RotatingFileSink(url: AppPaths.appLog)

    private let conciseFilter = AppLogConciseFilter()
    private let lock = NSLock()
    private var extraSinks: [LogSink] = []
    /// Only ever invoked on the main queue, which is what makes storing a
    /// non-`@Sendable` closure sound here — the class is `@unchecked Sendable`
    /// and the handler never crosses a thread boundary.
    private var uiHandler: ((String) -> Void)?

    private init() {}

    /// Route log lines to the UI list.  Set by the view; delivered on the main
    /// queue because the list is the only main-thread consumer.
    func setUIHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        uiHandler = handler
        lock.unlock()
    }

    /// Additional sinks (tests, a future in-app exporter).
    func add(_ sink: LogSink) {
        lock.lock()
        extraSinks.append(sink)
        lock.unlock()
    }

    /// Start a fresh apply/reset display. The memory list is cleared by the
    /// engine at each run entry; the coalescing counters have to clear with it,
    /// or the first per-file line of the next run would be folded into the
    /// previous run's summary.
    func resetForNewRun() {
        conciseFilter.reset()
        memory.reset()
    }

    func log(_ line: String, family: String? = nil) {
        // Console first, and unfiltered: a bug report may need the full detail
        // even though the file and the in-app tail are deliberately concise.
        print(line)
        guard let emitted = conciseFilter.emittedLine(for: line, forcedFamily: family) else {
            return
        }
        lock.lock()
        memory.write(emitted)
        file.write(emitted)
        for sink in extraSinks { sink.write(emitted) }
        let handler = uiHandler
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(emitted) }
    }
}

extension AppLog {
    /// Convenience for the many call sites that only want to emit a line.
    static func write(_ line: String) { shared.log(line) }

    /// A line from a known high-volume trampoline whose text has no stable
    /// prefix. Used by the AirLift C callback, which forwards library output
    /// verbatim; errors still pass through `isImportant` before this family is
    /// applied.
    static func writeDetail(_ line: String, family: String) {
        shared.log(line, family: family)
    }
}

/// Old releases wrote complete pairing dictionaries into diagnostic files.
/// Remove only logs containing those secret field dumps before enabling the
/// append-only Rust sink, so an update cannot keep exporting previously leaked
/// credentials. Pairing records themselves are never touched.
///
/// **Nothing here throws, and nothing here may refuse.** The caller answered a
/// thrown error by leaving the Rust sink off for the rest of the session, so one
/// unreadable file was enough to silence the only protocol-level evidence this
/// app has — and it did exactly that. An 18.7 GB `minimuxer.log` could not be
/// loaded into memory, `enableRustFileLogging()` returned -1 on every launch
/// after it, and the 18.7 GB it occupied stayed on the volume the backup is
/// written to. That volume then had 74 GB free where the device wanted more, so
/// every backup returned "0 of 0 offered" with no Rust log to say why.
///
/// These files are diagnostic output the app owns and can afford to lose. When
/// one cannot be inspected, deleting it answers the secrets question *and* the
/// space question at once; keeping it does neither.
enum PairingLogPrivacy {
    /// Above this, a diagnostic file is a liability rather than evidence.
    ///
    /// The Rust sink caps itself at 64 MB per generation and keeps one
    /// generation (`minimuxer.log.1`), so a healthy pair is at most 128 MB and
    /// survives this pass untouched — the previous run's tail is still there to
    /// read after a relaunch. Anything above it came from a build without that
    /// cap; the file this exists for was 18.7 GB.
    static let maxBytes: UInt64 = 128 << 20

    /// What was removed or replaced, so the engine can say so in one line.
    struct Reclaim: Sendable, Equatable {
        var files: [String] = []
        var bytes: UInt64 = 0

        var isEmpty: Bool { files.isEmpty }

        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(files.joined(separator: ", ")) (\(size))"
        }
    }

    /// Field names that only ever appeared in the credential dumps of older
    /// builds. Quoted on purpose: today's builds log the same key *names* as a
    /// bare list ("keys: alt_irk, identifier, …") and that line must not wipe
    /// the log on every launch.
    private static let secretFields = ["\"private_key\"", "\"alt_irk\""]
        .map { Data($0.utf8) }

    private enum Verdict {
        case clean
        case secretDump
        case unreadable
    }

    /// Sanitise each file, deleting what cannot be inspected or is oversized.
    ///
    /// - Parameter limit: files above this are removed without being read. The
    ///   scan is the expensive part and a huge file is not evidence any more,
    ///   so the size check has to come first — that ordering is the whole fix.
    @discardableResult
    static func removeLegacyDumps(at urls: [URL], limit: UInt64 = maxBytes) -> Reclaim {
        let fm = FileManager.default
        var reclaim = Reclaim()

        for url in urls {
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.uint64Value > 0 else { continue }

            if size.uint64Value > limit {
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
                continue
            }

            switch scan(url) {
            case .clean:
                continue
            case .secretDump:
                // Replaced rather than deleted: the app log keeps appending, and
                // the notice is what a reader of that file needs to know.
                let notice = Data("Old diagnostic log removed because it contained pairing secrets.\n".utf8)
                if (try? notice.write(to: url, options: .atomic)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value - UInt64(min(notice.count, Int(size.uint64Value)))
                }
            case .unreadable:
                // Nothing here is worth keeping, and the bytes are exactly why it
                // could not be inspected — so they go, rather than disabling the
                // sink that would have explained the next failure.
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
            }
        }
        return reclaim
    }

    /// Stream the file in 1 MB chunks, carrying the overlap a pattern could
    /// straddle. Memory stays bounded no matter how long the file is, which is
    /// the property `Data(contentsOf:)` did not have.
    ///
    /// The search is `Data.range(of:)`, not a byte-by-byte walk, and that is a
    /// launch-survival fix rather than a tidying: this pass runs from the first
    /// view body, on the main thread, before the shell is allowed to appear. A
    /// naive walk costs ~1 µs per byte in a Debug build — the 2026-10-29 build
    /// died on every launch with a scene-create watchdog kill after 19.96 s,
    /// its main thread inside `Array.contains(sequence:)` over a 54 MB
    /// `minimuxer.log` (58 s measured at -Onone by
    /// `scripts/check-log-privacy-scan.py`). The Rust sink is capped at 64 MB
    /// per generation with one generation kept, so this has to stay fast at
    /// 128 MB; Foundation's search does that in a fraction of a second.
    private static func scan(_ url: URL) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }

        let overlap = (secretFields.map(\.count).max() ?? 1) - 1
        var carry = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1 << 20), !read.isEmpty else {
                    return .clean
                }
                chunk = read
            } catch {
                return .unreadable
            }
            var buffer = carry
            buffer.append(chunk)
            if secretFields.contains(where: { buffer.range(of: $0) != nil }) {
                return .secretDump
            }
            carry = buffer.suffix(overlap)
        }
    }
}
