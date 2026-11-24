import Foundation

/// Native photo-library backup and restore.
///
/// This is the media path every apply uses. It works through `PHPhotoLibrary`
/// with the user's permission, so it needs no tunnel, no pairing file and no
/// AFC service: the photos the library shows are the photos it backs up. The
/// local copies live beside the AFC store in `AppPaths.mediaStore`, under
/// `Photos/`, and are restored by creating new assets in the library.
///
/// AFC stays for one thing it can do and Photos cannot: **deleting** originals
/// after a verified copy (`AfcMediaBackup.pull(deletingOriginals:)`). That is a
/// manual, optional operation on the Media page, never part of an apply.
///
/// The Photos backend is injected (`Service`) so the store logic can be run in
/// the simulator regression harness, where `Photos` is not available. The
/// shipping implementation in `PhotoLibraryService.swift` installs itself at
/// launch through `ensureService()`.
enum PhotoMediaBackup {
    // MARK: - Model

    /// One library asset's verified copy in the container.
    struct Entry: Codable, Hashable {
        /// `PHAsset.localIdentifier`; stable across renames and edits.
        var identifier: String
        /// Relative path inside the media store, always under `Photos/`.
        var storedAs: String
        var filename: String
        var size: Int64
        var created: Date?
        var modified: Date?
        var isVideo: Bool
    }

    struct Manifest: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    /// What the Photos backend reports for one asset. Size is deliberately not
    /// part of the survey: Photos has no public byte count for an asset, and the
    /// bytes are known only after `write(_:to:)` has streamed it to disk.
    struct Descriptor: Sendable {
        var identifier: String
        var filename: String
        var created: Date?
        var modified: Date?
        var isVideo: Bool
    }

    /// A verified local copy to put back into the photo library.
    struct RestoreAsset: Sendable {
        var url: URL
        var filename: String
        var isVideo: Bool
    }

    /// The device-side half, kept small enough to double in tests.
    protocol Service: Sendable {
        func authorizeForBackup() async throws
        func authorizeForRestore() async throws
        func assets() async throws -> [Descriptor]
        /// Stream one asset's original bytes into `destination`. Returns the
        /// number of bytes actually written.
        func write(_ asset: Descriptor, to destination: URL) async throws -> Int64
        func restore(_ assets: [RestoreAsset], onProgress: @Sendable (String) -> Void) async throws
    }

    // MARK: - Service installation

    private static let serviceLock = NSLock()
    private static var installedService: (any Service)?

    static func install(_ service: any Service) {
        serviceLock.lock()
        installedService = service
        serviceLock.unlock()
    }

    static var hasService: Bool {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        return installedService != nil
    }

    private static func resolvedService() throws -> any Service {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        guard let installedService else {
            throw GoldenNuggetError("Photo library service is not installed — restart the app.")
        }
        return installedService
    }

    // MARK: - Store

    static var manifestURL: URL {
        AppPaths.mediaStore.appendingPathComponent("photos-media.json", conformingTo: .data)
    }

    /// What is in the local Photos store, for the UI.
    static func storeTotals() -> (files: Int, bytes: Int64)? {
        guard let manifest = try? read() else { return nil }
        return (manifest.entries.count, manifest.entries.reduce(0) { $0 + $1.size })
    }

    /// Files that a restore would create in the library: every Photos copy,
    /// plus the AFC originals that were deliberately removed from the device.
    /// A non-destructive AFC pull is not counted — those photos are still in
    /// the library and restoring them would duplicate them.
    static var restorableCount: Int {
        let native = (try? read().entries.count) ?? 0
        let removed = (try? AfcMediaBackup.read().entries.filter(\.deleted).count) ?? 0
        return native + removed
    }

    // MARK: - Backup

    /// Add every new or changed library asset to the store. Existing copies
    /// whose identity and modification date are unchanged are not re-exported.
    static func backup(onProgress: @Sendable (String) -> Void) async throws -> Manifest {
        try AfcMediaBackup.beginStoreTransfer()
        defer { AfcMediaBackup.endStoreTransfer() }
        let service = try resolvedService()
        try await service.authorizeForBackup()
        try FileManager.default.createDirectory(
            at: AppPaths.mediaStore, withIntermediateDirectories: true)
        let library = try await service.assets()
        onProgress("Photos: \(library.count) asset(s) in the photo library")

        var manifest = try read()
        var indices: [String: Int] = [:]
        for (index, row) in manifest.entries.enumerated() { indices[row.identifier] = index }

        var added = 0
        var alreadyStored = 0
        var bytes: Int64 = 0

        for asset in library {
            let relative = relativePath(for: asset)
            let destination = try localMediaPath(relative)

            if let index = indices[asset.identifier] {
                let row = manifest.entries[index]
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                if row.modified == asset.modified, row.created == asset.created,
                   row.filename == asset.filename, row.isVideo == asset.isVideo,
                   attributes?[.type] as? FileAttributeType == .typeRegular,
                   (attributes?[.size] as? NSNumber)?.int64Value == row.size {
                    alreadyStored += 1
                    bytes += row.size
                    continue
                }
            }

            // The container is the volume Photos writes into. Refuse to start
            // another export when it is nearly full. A zero reading means the
            // volume query was unavailable, not that the disk is full, so it is
            // treated as unknown rather than aborting the backup.
            let free = AfcMediaBackup.containerFreeBytes()
            if free > 0, free < 256 * 1024 * 1024 {
                throw GoldenNuggetError("Photos: less than 256 MB free in the app container — backup stopped.")
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("photopartial")
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)

            let written: Int64
            do {
                written = try await service.write(asset, to: partial)
                guard written > 0 else {
                    throw GoldenNuggetError("Photos: \(asset.filename) exported no bytes — original kept.")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == written else {
                    throw GoldenNuggetError("Photos: \(asset.filename) changed size while exporting — original kept.")
                }
                try handle(at: partial, synchronize: true)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw GoldenNuggetError("Photos: \(asset.filename) failed — \(error.localizedDescription). Original kept.")
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }

            let row = Entry(identifier: asset.identifier, storedAs: relative,
                            filename: asset.filename, size: written,
                            created: asset.created, modified: asset.modified,
                            isVideo: asset.isVideo)
            if let index = indices[asset.identifier] {
                manifest.entries[index] = row
            } else {
                indices[asset.identifier] = manifest.entries.count
                manifest.entries.append(row)
            }
            added += 1
            bytes += written
            onProgress("Photos: \(asset.filename) — "
                + ByteCountFormatter.string(fromByteCount: written, countStyle: .file))
            // A cancelled apply must not throw away the files already copied:
            // checkpoint the manifest every few assets and always at the end.
            if added % 25 == 0 { try write(manifest) }
        }

        if alreadyStored > 0 {
            onProgress("Photos: \(alreadyStored) asset(s) already stored, not exported again")
        }
        try write(manifest)
        onProgress("Photos: \(added) new or changed asset(s), "
            + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in the store")
        return manifest
    }

    // MARK: - Restore

    /// Put the stored copies back into the photo library through the native
    /// permission. AFC is not involved: no gateway, no pairing file, no device
    /// paths. Local copies stay until the Media page empties the store.
    static func restore(onProgress: @Sendable (String) -> Void) async throws {
        try AfcMediaBackup.beginStoreTransfer()
        defer { AfcMediaBackup.endStoreTransfer() }
        let service = try resolvedService()
        try await service.authorizeForRestore()

        var items: [RestoreAsset] = []
        for row in try read().entries {
            let url = try localMediaPath(row.storedAs)
            try verifyLocalCopy(url, size: row.size, label: row.filename)
            items.append(RestoreAsset(url: url, filename: row.filename, isVideo: row.isVideo))
        }
        // Only AFC originals that were deliberately deleted need putting back.
        for row in try AfcMediaBackup.read().entries where row.deleted {
            let url = try AfcMediaBackup.storedFile(for: row.storedAs)
            try verifyLocalCopy(url, size: row.size, label: row.source)
            let filename = (row.source as NSString).lastPathComponent
            items.append(RestoreAsset(url: url, filename: filename,
                                      isVideo: Self.looksLikeVideo(filename)))
        }
        guard !items.isEmpty else {
            throw GoldenNuggetError("The media store is empty — the Media page's backup fills it.")
        }

        onProgress("Photos: restoring \(items.count) file(s) to the photo library")
        try await service.restore(items, onProgress: onProgress)
        onProgress("Photos: restore finished — local copies stay until the store is emptied")
    }

    private static func verifyLocalCopy(_ url: URL, size: Int64, label: String) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw GoldenNuggetError("Photos store copy is missing: \(label). Restore stopped.") }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == size else {
            throw GoldenNuggetError("Photos store copy is incomplete: \(label). Restore stopped; local copies kept.")
        }
    }

    // MARK: - Internals

    /// A stable, filesystem-safe directory per asset: Photos identifiers look
    /// like `ABCDEF/GHIJKL/LPHASP…`, so flattening the separators gives a unique
    /// name without a hash dependency and without trusting a photo's filename.
    private static func relativePath(for asset: Descriptor) -> String {
        let folder = safe(asset.identifier)
        let file = safe((asset.filename as NSString).lastPathComponent)
        return "Photos/\(folder)/\(file.isEmpty ? "asset" : file)"
    }

    private static func safe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// AFC rows carry a path, not a media type. The extension is enough to tell
    /// Photos which resource kind to create for a deleted original.
    private static func looksLikeVideo(_ filename: String) -> Bool {
        ["mov", "mp4", "m4v", "avi", "mkv"].contains(
            (filename as NSString).pathExtension.lowercased())
    }

    /// Keep recovery paths inside `Photos/`, with no traversal and no links.
    private static func localMediaPath(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "Photos",
              !relative.contains("\\"), !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GoldenNuggetError("Unsafe Photos media path: \(relative)")
        }
        var target = AppPaths.mediaStore
        for part in [""] + parts.map(String.init) {
            if !part.isEmpty { target.appendPathComponent(part) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GoldenNuggetError("Linked Photos media path: \(relative)")
            }
        }
        return target
    }

    private static func handle(at url: URL, synchronize: Bool) throws {
        guard synchronize else { return }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    // MARK: - Manifest and cache

    static func invalidateCache() {
        cacheLock.lock()
        cachedKey = ""
        cachedManifest = nil
        cacheLock.unlock()
    }

    static func read() throws -> Manifest {
        let key = manifestCacheKey()
        cacheLock.lock()
        if let cachedManifest, cachedKey == key {
            cacheLock.unlock()
            return cachedManifest
        }
        cacheLock.unlock()

        var manifest: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } else {
            manifest = Manifest()
        }
        guard manifest.version == 1 else {
            throw GoldenNuggetError("Unsupported Photos media manifest version.")
        }
        var identifiers = Set<String>()
        for entry in manifest.entries {
            guard entry.size >= 0, identifiers.insert(entry.identifier).inserted else {
                throw GoldenNuggetError("Invalid Photos media entry: \(entry.identifier)")
            }
            _ = try localMediaPath(entry.storedAs)
        }

        cacheLock.lock()
        cachedKey = key
        cachedManifest = manifest
        cacheLock.unlock()
        return manifest
    }

    private static func write(_ manifest: Manifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(
            at: AppPaths.mediaStore, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
        let file = try FileHandle(forWritingTo: manifestURL)
        defer { try? file.close() }
        try file.synchronize()
        invalidateCache()
    }

    private static let cacheLock = NSLock()
    private static var cachedKey = ""
    private static var cachedManifest: Manifest?

    private static func manifestCacheKey() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return "\(manifestURL.path):<absent>"
        }
        return "\(manifestURL.path):\(size):\(modified.timeIntervalSince1970)"
    }
}
