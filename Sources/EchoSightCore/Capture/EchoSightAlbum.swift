import Photos
import Logging

// MARK: - EchoSightAlbum

/// Manages the "EchoSight Captures" photo album.
///
/// Creates the album on first use and persists its identifier in `UserDefaults`
/// so it survives app restarts. If the user deletes the album from Photos,
/// it is recreated on the next capture.
///
/// All mutating operations require `.authorized` Photos access. `.limited`
/// access is treated as a failure (album operations silently no-op under
/// limited access and PHPhotoLibraryChangeObserver won't see new screenshots).
public actor EchoSightAlbum {

    // MARK: - Private state

    private let defaultsKey = "EchoSight.albumIdentifier"
    private let logger = Logger(label: "echosight.capture")

    // MARK: - Init

    public init() {}

    // MARK: - Album access

    /// Returns the existing "EchoSight Captures" album, or creates it.
    ///
    /// Persists the album identifier in `UserDefaults` so subsequent calls are fast.
    /// If the stored identifier no longer resolves (user deleted the album), creates a new one.
    public func ensureAlbum() async throws -> PHAssetCollection {
        // Try persisted identifier first
        if let savedID = UserDefaults.standard.string(forKey: defaultsKey) {
            let result = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [savedID], options: nil
            )
            if let album = result.firstObject {
                return album
            }
            logger.info("capture.album.notFound — recreating (id: \(savedID))")
        }

        // Create new album
        var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: "EchoSight Captures")
                placeholderID = req.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            logger.warning("capture.album.createFailed — \(error.localizedDescription)")
            throw EchoSightAlbumError.creationFailed(error)
        }

        guard let id = placeholderID else {
            throw EchoSightAlbumError.creationFailed(nil)
        }

        UserDefaults.standard.set(id, forKey: defaultsKey)
        logger.info("capture.album.created — id: \(id)")

        // Re-fetch the real album object (placeholder ID is stable post-performChanges)
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        )
        guard let album = result.firstObject else {
            throw EchoSightAlbumError.creationFailed(nil)
        }
        return album
    }

    // MARK: - Move asset

    /// Moves a screenshot asset into the EchoSight Captures album.
    ///
    /// This adds a reference — the asset also remains in the default screenshot album.
    public func moveAsset(_ asset: PHAsset) async throws {
        let album = try await ensureAlbum()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let req = PHAssetCollectionChangeRequest(for: album) else { return }
                req.addAssets([asset] as NSArray)
            }
            logger.info("capture.album.moved — assetId: \(asset.localIdentifier)")
        } catch {
            logger.warning("capture.album.moveFailed — \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Clear all

    /// Deletes all assets in the EchoSight Captures album from the photo library.
    ///
    /// The system always presents a deletion confirmation dialog — no custom
    /// alert is needed before calling this. The dialog is VoiceOver-compatible.
    ///
    /// If the album is empty this is a no-op.
    public func clearAll() async throws {
        let album = try await ensureAlbum()
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        guard assets.count > 0 else {
            logger.info("capture.clearCaptures.noop — album already empty")
            return
        }
        let count = assets.count
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            logger.info("capture.clearCaptures.confirmed — count: \(count)")
        } catch {
            logger.warning("capture.clearCaptures.failed — \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Asset count

    /// Returns the number of assets currently in the EchoSight Captures album.
    public func assetCount() async throws -> Int {
        let album = try await ensureAlbum()
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        return assets.count
    }
}

// MARK: - EchoSightAlbumError

public enum EchoSightAlbumError: Error, LocalizedError {
    case creationFailed(Error?)
    case albumNotFound

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let underlying):
            if let underlying {
                return "Failed to create EchoSight Captures album: \(underlying.localizedDescription)"
            }
            return "Failed to create EchoSight Captures album."
        case .albumNotFound:
            return "EchoSight Captures album not found."
        }
    }
}
