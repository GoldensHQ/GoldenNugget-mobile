import SwiftUI
import Minimuxer

/// Media backup and restore.
///
/// The native path uses the photo-library permission: it copies new and changed
/// assets into this app's container and writes the stored copies back as new
/// assets. Every apply backs up incrementally, so the manual button is just a
/// way to do it between runs.
///
/// The optional AFC path still exists for one thing Photos cannot do: deleting
/// originals. The destructive half is behind its own switch, **off by default**.
/// A first run copies and verifies; only once the switch is on does a verified
/// copy also remove the original. The store in the container is then the only
/// copy of that photo, and iOS deletes the container with the app.
struct MediaView: View {
    @AppStorage("AfcMedia.deleteOriginals") private var deleteOriginals = false
    @State private var survey: AfcMediaBackup.Survey?
    @State private var manifest: AfcMediaBackup.Manifest?
    @State private var busy = false
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var confirmPull = false

    private var free: Int64 { AfcMediaBackup.containerFreeBytes() }

    /// Read once on entry rather than starting at nil. The two store-dependent
    /// buttons gate on `manifest?.entries`, so a nil manifest disabled both of
    /// them for the whole session -- including after a pull from a previous run,
    /// which is exactly when you come back to push or clear.
    private func loadManifest() {
        PhotoMediaBackup.ensureService()
        manifest = try? AfcMediaBackup.read()
        hasStoredFiles = storeHasFiles()
    }

    /// Whether the store holds anything — computed **once per load or action**,
    /// not on every body pass.
    ///
    /// `storeHasFiles` walks the store tree for leftovers, and the old computed
    /// property sat in two `.disabled(...)` modifiers: every re-render of this
    /// page walked the directory twice, on the main thread.  The answer only
    /// changes when an action runs, and every action ends here.
    @State private var hasStoredFiles = false

    /// From the filesystem rather than from the last run's manifest: a pull that
    /// was interrupted, or files left by an earlier build, are real data that
    /// "Empty" must still be able to remove. Both stores share the same root.
    private func storeHasFiles() -> Bool {
        if let m = manifest, !m.entries.isEmpty { return true }
        if (try? PhotoMediaBackup.read().entries.isEmpty) == false { return true }
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: AfcMediaBackup.storeRoot.path) else { return false }
        for case let name as String in walker
            where name.hasSuffix(".afcpartial") || name.hasSuffix(".photopartial") { return true }
        return false
    }

    var body: some View {
        List {
            mediaSection
            afcSection
            if !lines.isEmpty { logSection }
            if let error { errorSection(error) }
        }
        .listStyle(.insetGrouped)
        .task { loadManifest() }
        // The only page that had no navigation bar at all, because it used to be
        // the one destination reached from a launcher (Home's card grid) rather
        // than pushed on a stack, so it never needed a back button.  Both of
        // those are gone: the sidebar is the only way in and it pushes like
        // everything else, so this page gets the same bar as the rest — title
        // included, which it never had.
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Copy media and remove eligible originals?",
            isPresented: $confirmPull, titleVisibility: .visible
        ) {
            Button("Copy and remove originals", role: .destructive) { Task { await doPull() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(bytes(survey?.bytes ?? 0)) will be copied into this app's container. Free space there: \(bytes(free)). Once removed, the copy in the container is the only one -- and the container is deleted if the app is.")
        }
    }

    private var mediaSection: some View {
        Section("Media backup") {
            NativeNote("Uses the iOS photo-library permission. Every apply adds new and changed photos and videos to this app's container; nothing is removed from the library. Restore creates new assets from the stored copies.")
            Button {
                Task { await backupPhotos() }
            } label: {
                Label("Back up photo library", systemImage: "arrow.down.doc.fill")
            }
            .disabled(busy)
            Button {
                Task { await restoreToPhotos() }
            } label: {
                Label("Restore to Photos", systemImage: "arrow.up.doc.fill")
            }
            .disabled(busy || !hasStoredFiles)
        }
    }

    private var afcSection: some View {
        Section("AFC media (optional)") {
            NativeNote(String(localized: "Copies \(AfcMediaBackup.trees.joined(separator: " and ")) from the device's Media root over AFC into this app's container. Only needed to delete originals, which the photo library cannot do."))
            surveyRows
            deleteSwitch
            Button {
                Task { await pull() }
            } label: {
                Label("Pull media over AFC", systemImage: "arrow.down.doc")
            }
            .disabled(busy)
            // Was `try?` with a success message printed either way, so a failure
            // looked identical to a success. It is routed through run() so the
            // error surfaces, and loadManifest() re-reads rather than assuming
            // the store is empty now.
            Button(role: .destructive) {
                Task {
                    await run {
                        try AfcMediaBackup.clear()
                        loadManifest()
                        lines.append("Local media store emptied.")
                    }
                }
            } label: {
                Label("Empty the local store", systemImage: "trash")
            }
            .disabled(busy || !hasStoredFiles)
            NativeSafetyNote("Emptying the store is only safe once the copies are back in the photo library and verified there.")
        }
    }

    @ViewBuilder
    private var surveyRows: some View {
        if let survey {
            VStack(alignment: .leading, spacing: 4) {
                (Text("\(survey.files.count) file(s), \(bytes(survey.bytes))")
                    + (survey.skippedSymlinks > 0 ? Text(", \(survey.skippedSymlinks) symlink(s) skipped") : Text(verbatim: "")))
                    .font(.body)
                NativeNote("Free in the container: \(bytes(free)).")
            }
        } else {
            Text("Not surveyed")
                .foregroundStyle(.secondary)
        }
        Button {
            Task { await runSurvey() }
        } label: {
            Label("Survey", systemImage: "magnifyingglass")
        }
        .disabled(busy)
    }

    private var deleteSwitch: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $deleteOriginals) {
                Text("Delete originals after copy")
                    .foregroundStyle(deleteOriginals ? Color.red : Color.primary)
            }
            NativeNote(deleteOriginals
                ? "Originals are removed after the verified copy is saved for recovery."
                : "Off: copies are made and the originals stay put.")
        }
    }

    private var logSection: some View {
        Section("Log") {
            ForEach(lines.suffix(40), id: \.self) { line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section("Failed") {
            NativeSafetyNote(error)
        }
    }

    // MARK: - Actions

    private func runSurvey() async {
        await run {
            let s = try await AfcMediaBackup.survey()
            survey = s
            lines = ["Survey: \(s.files.count) file(s), \(bytes(s.bytes))."]
        }
    }

    private func pull() async {
        if deleteOriginals { confirmPull = true; return }
        await doPull()
    }

    private func doPull() async {
        await run {
            let m = try await AfcMediaBackup.pull(deletingOriginals: deleteOriginals) { line in
                Task { @MainActor in lines.append(line) }
            }
            manifest = m
            // The store just changed, so the gate on Push/Empty has to be
            // recomputed here — `loadManifest()` is not called on this path.
            hasStoredFiles = storeHasFiles()
            let removed = m.entries.filter(\.deleted).count
            lines.append("Store contains \(m.entries.count) file(s); \(removed) original(s) removed across saved transfers.")
        }
    }

    /// Incremental native backup, the same operation every apply performs.
    private func backupPhotos() async {
        await run {
            _ = try await PhotoMediaBackup.backup { line in
                Task { @MainActor in lines.append(line) }
            }
            loadManifest()
        }
    }

    /// Restore through the photo-library permission, never through AFC.
    private func restoreToPhotos() async {
        await run {
            try await PhotoMediaBackup.restore { line in
                Task { @MainActor in lines.append(line) }
            }
            loadManifest()
        }
    }

    /// One place for the busy flag, the log and the error, so no action can end
    /// up half-updating them.
    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await body()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
