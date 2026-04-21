import Foundation
import Photos
import UIKit
import Logging

// MARK: - PeekABooSource

/// `PassthroughCaptureSource` implementation backed by PeekABoo screenshot observation.
///
/// PeekABoo monitors the system screenshot album and calls back with the captured `UIImage`
/// whenever the user presses Digital Crown + Capture Button.
///
/// The source must be `@MainActor` because PeekABoo's `onCapture` closure runs on the
/// main actor, and `UIImage` is not `Sendable`.
///
/// ## Usage
///
/// Attach `.onCapture { image in await source.handleCapture(image) }` to the root view
/// of your capture-aware SwiftUI hierarchy **exactly once**.
///
/// ## Lifecycle
///
/// Call `start()` after Photos authorization is granted. Call `stop()` to cancel pending
/// captures and drain the frame stream.
@MainActor
public final class PeekABooSource: PassthroughCaptureSource {

    // MARK: - Private state

    private let album: EchoSightAlbum
    private let logger = Logger(label: "echosight.capture")

    private var framesContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _isActive = false
    private var firstCaptureAnnouncedThisSession = false

    /// 800 ms capture timeout per spec acceptance criterion.
    private let captureTimeoutSeconds: Double = 0.8

    // MARK: - Public stream

    /// Emits `CapturedFrame` values as captures arrive. Backed by an `AsyncStream`.
    public let frames: AsyncStream<CapturedFrame>

    // MARK: - Init

    public init(album: EchoSightAlbum = EchoSightAlbum()) {
        self.album = album
        var continuation: AsyncStream<CapturedFrame>.Continuation?
        self.frames = AsyncStream { cont in
            continuation = cont
        }
        self.framesContinuation = continuation
    }

    // MARK: - PassthroughCaptureSource

    public var isActive: Bool {
        get async { _isActive }
    }

    public func start() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            if status == .limited {
                logger.warning("capture.degraded — reason: limitedAccess")
                throw EchoSightError.captureFailed(nil)
            }
            throw EchoSightError.captureFailed(nil)
        }
        _isActive = true
        logger.info("capture.started")
    }

    public func stop() async {
        _isActive = false
        framesContinuation?.finish()
        logger.info("capture.stopped")
    }

    /// Conformance to `PassthroughCaptureSource`. Waits for the next frame with
    /// an 800 ms timeout. The actual capture is triggered by the user's hardware
    /// gesture (Digital Crown + Capture Button) — this method awaits delivery.
    public func captureFrame() async throws -> CapturedFrame {
        logger.info("capture.requested")

        return try await withThrowingTaskGroup(of: CapturedFrame.self) { group in
            // Frame waiter
            group.addTask { [frames] in
                for await frame in frames {
                    return frame
                }
                throw EchoSightError.captureFailed(nil)
            }

            // Timeout
            group.addTask {
                try await Task.sleep(for: .milliseconds(800))
                throw EchoSightError.captureFailed(
                    NSError(domain: "echosight.capture", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "capture timeout"])
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Capture handler (called from SwiftUI .onCapture modifier)

    /// Called by the SwiftUI view that hosts the `.onCapture` modifier.
    ///
    /// Records delivery timestamp immediately on entry, then fetches the
    /// corresponding `PHAsset` to obtain the authoritative shutter timestamp.
    public func handleCapture(_ image: UIImage) async {
        let deliveryTimestamp = Date()
        logger.info("capture.delivered — at: \(deliveryTimestamp.timeIntervalSince1970)")

        // Guard against zero-size images (PeekABoo swallows errors internally)
        guard image.size != .zero else {
            logger.warning("capture.failed — reason: zeroSizeImage")
            return
        }

        // Fetch the most recent screenshot asset
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1
        fetchOptions.predicate = NSPredicate(
            format: "mediaSubtype == %d",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        let shutterTimestamp: Date
        let assetForAlbum: PHAsset?

        if let asset = fetchResult.firstObject {
            shutterTimestamp = asset.creationDate ?? deliveryTimestamp
            assetForAlbum = asset
            let lagMs = Int(deliveryTimestamp.timeIntervalSince(shutterTimestamp) * 1000)
            let shutterMs = Int(shutterTimestamp.timeIntervalSinceNow * -1000)
            logger.info("capture.shutter — shutterMs: \(shutterMs)")
            logger.info("capture.delivered — deliveryMs: \(lagMs), lagMs: \(lagMs)")
        } else {
            // No asset found — use delivery timestamp as best-effort shutter
            shutterTimestamp = deliveryTimestamp
            assetForAlbum = nil
            logger.warning("capture.shutter — no asset found, using deliveryTimestamp as fallback")
        }

        // Determine outcome based on delivery lag
        let lagSeconds = deliveryTimestamp.timeIntervalSince(shutterTimestamp)
        let outcome: CapturedFrame.Outcome
        if lagSeconds > 3.0 {
            logger.warning("capture.degraded — reason: latePhotoKitDelivery, lagSeconds: \(lagSeconds)")
            outcome = .degraded(.latePhotoKitDelivery)
        } else {
            outcome = .ok
        }

        // Move asset to album
        if let asset = assetForAlbum {
            do {
                try await album.moveAsset(asset)
            } catch {
                // Non-fatal: asset stays in default album, log and continue
                logger.warning("capture.album.moveFailed — \(error.localizedDescription)")
            }
        }

        // One-time session reminder after first successful capture
        if !firstCaptureAnnouncedThisSession {
            firstCaptureAnnouncedThisSession = true
            // Caller (SwiftUI view) posts the accessibility announcement
            // We signal via notification name so the view layer can react
            NotificationCenter.default.post(
                name: PeekABooSource.firstCaptureNotification, object: nil
            )
        }

        let frame = CapturedFrame(
            image: image,
            shutterTimestamp: shutterTimestamp,
            deliveryTimestamp: deliveryTimestamp,
            outcome: outcome
        )
        framesContinuation?.yield(frame)
    }

    // MARK: - Authorization

    /// Requests Full Photos access. Returns `false` for `.limited` — PeekABoo
    /// requires `.authorized` to observe screenshots.
    @discardableResult
    public func requestPhotoLibraryAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            return true
        case .limited:
            logger.warning("capture.degraded — reason: limitedAccess")
            return false
        case .denied, .restricted:
            logger.warning("capture.failed — reason: photosDenied")
            return false
        case .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Notifications

    /// Posted after the first capture of a session so the UI layer can announce
    /// the album reminder to VoiceOver.
    public static let firstCaptureNotification = Notification.Name("EchoSight.firstCapture")
}
