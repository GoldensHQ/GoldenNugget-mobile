import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

/// The device-side implementation of `PhotoMediaBackup.Service`.
///
/// All library access goes through the user-facing permission:
/// `PHPhotoLibrary.requestAuthorization(for: .readWrite)` before a backup and
/// `.addOnly` before a restore. Nothing here touches the device's AFC Media
/// tree, a pairing file or the tunnel. Assets are streamed to disk with
/// `PHAssetResourceManager`, so a large video never has to sit in one `Data`,
/// and restored by `PHAssetCreationRequest` so the library owns the result.
/// Assets whose bytes are still in iCloud are reported as
/// `PhotoMediaBackup.AssetRequiresNetwork`, which makes the backup skip them
/// instead of turning a media copy into a download.
///
/// `@preconcurrency` keeps Swift 5-mode builds quiet about Photos' completion
/// handlers while the code still marshals every continuation resume explicitly.
final class PhotoLibraryService: PhotoMediaBackup.Service, @unchecked Sendable {
    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: - Permission

    func authorizeForBackup() async throws {
        try await authorize(.readWrite)
    }

    func authorizeForRestore() async throws {
        try await authorize(.addOnly)
    }

    private func authorize(_ level: PHAccessLevel) async throws {
        switch PHPhotoLibrary.authorizationStatus(for: level) {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: level)
            guard status == .authorized || status == .limited else {
                throw GoldenNuggetError("Photos: access was not granted. Turn it on in Settings › Privacy & Security › Photos, then try again.")
            }
        case .denied, .restricted:
            throw GoldenNuggetError("Photos: access is off. Turn it on in Settings › Privacy & Security › Photos, then try again.")
        @unknown default:
            throw GoldenNuggetError("Photos: this iOS version returned an unknown permission state.")
        }
    }

    // MARK: - Survey and export

    func assets() async throws -> [PhotoMediaBackup.Descriptor] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: #keyPath(PHAsset.creationDate), ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var out: [PhotoMediaBackup.Descriptor] = []
        result.enumerateObjects { asset, _, _ in
            guard let resource = Self.primaryResource(for: asset) else { return }
            out.append(PhotoMediaBackup.Descriptor(
                identifier: asset.localIdentifier,
                filename: resource.originalFilename,
                created: asset.creationDate,
                modified: asset.modificationDate,
                isVideo: resource.type == .video))
        }
        return out
    }

    func write(_ asset: PhotoMediaBackup.Descriptor, to destination: URL) async throws -> Int64 {
        let matches = PHAsset.fetchAssets(withLocalIdentifiers: [asset.identifier], options: nil)
        guard let phAsset = matches.firstObject,
              let resource = Self.primaryResource(for: phAsset) else {
            throw GoldenNuggetError("Photos: \(asset.filename) is no longer in the library — skipped.")
        }
        let sink = try FileSink(url: destination)
        let options = PHAssetResourceRequestOptions()
        // A camera roll on a device with iCloud Photos can have assets that are
        // not local; a backup must not pull them back down over the network.
        options.isNetworkAccessAllowed = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { chunk in sink.write(chunk) },
                completionHandler: { error in
                    if let error {
                        sink.closeQuietly()
                        if Self.isNetworkAccessRequired(error) {
                            continuation.resume(throwing: PhotoMediaBackup.AssetRequiresNetwork())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume()
                    }
                })
        }
        return try sink.finish()
    }

    /// Photos reports code 3164 when the requested bytes are only in iCloud
    /// and the request did not allow network access. Other Photos errors still
    /// travel to the caller unchanged and fail the backup.
    private static func isNetworkAccessRequired(_ error: Error) -> Bool {
        let photosError = error as NSError
        return photosError.domain == PHPhotosErrorDomain
            && photosError.code == PHPhotosError.Code.networkAccessRequired.rawValue
    }

    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        // A Live Photo has a still image plus a paired movie; one copy per asset
        // is the backup's unit, so take the still and leave the pair alone.
        return resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .video }
    }

    // MARK: - Restore

    func restore(_ assets: [PhotoMediaBackup.RestoreAsset],
                 onProgress: @Sendable (String) -> Void) async throws {
        guard !assets.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for item in assets {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    // The store is the backup: Photos must copy from it, not
                    // move the only verified file out from under the store.
                    options.shouldMoveFile = false
                    if let type = UTType(filenameExtension: item.url.pathExtension) {
                        options.uniformTypeIdentifier = type.identifier
                    }
                    request.addResource(with: item.isVideo ? .video : .photo,
                                        fileURL: item.url, options: options)
                }
            }, completionHandler: { succeeded, error in
                if succeeded {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error
                        ?? GoldenNuggetError("Photos: the library refused the restore."))
                }
            })
        }
        for item in assets { onProgress("Photos: added \(item.filename)") }
    }

    /// The chunk callback can arrive on any Photos worker. One lock keeps the
    /// byte count and the first write error consistent with the completion.
    private final class FileSink: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var count: Int64 = 0
        private var failure: Error?

        init(url: URL) throws {
            self.handle = try FileHandle(forWritingTo: url)
        }

        func write(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard failure == nil else { return }
            do {
                try handle.write(contentsOf: chunk)
                count += Int64(chunk.count)
            } catch {
                failure = error
            }
        }

        func finish() throws -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            try? handle.synchronize()
            try? handle.close()
            if let failure { throw failure }
            return count
        }

        func closeQuietly() {
            lock.lock()
            defer { lock.unlock() }
            try? handle.close()
        }
    }
}

extension PhotoMediaBackup {
    /// Called at launch and before any media action, so the store logic never
    /// has to know which backend the build has linked.
    static func ensureService() {
        guard !hasService else { return }
        install(PhotoLibraryService.shared)
    }
}
