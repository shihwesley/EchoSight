import Foundation
import Photos
import QuartzCore
import UIKit
import Logging

// MARK: - PhotosLibraryCaptureSource

/// `PassthroughCaptureSource` implementation backed by an internal PHPhotoLibraryChangeObserver.
///
/// Observes the Photos library for new screenshots and calls back with the captured `UIImage`
/// whenever the user presses Digital Crown + Capture Button.
///
/// The source must be `@MainActor` because handleCapture is called via a Task hop from the
/// PhotoKit background queue, and `UIImage` is not `Sendable`.
///
/// ## Lifecycle
///
/// Call `start()` after Photos authorization is granted. Call `stop()` to cancel pending
/// captures and drain the frame stream.
@MainActor
public final class PhotosLibraryCaptureSource: PassthroughCaptureSource {

    // MARK: - Private state

    private let album: EchoSightAlbum
    private let logger = Logger(label: "echosight.capture")

    private var framesContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _isActive = false
    private var firstCaptureAnnouncedThisSession = false
    /// Prevents two concurrent `captureFrame()` callers from racing on the shared stream.
    private var captureInFlight = false
    private var screenshotObserver: ScreenshotObserver?

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
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            _isActive = true
            let observer = ScreenshotObserver(source: self)
            screenshotObserver = observer
            PHPhotoLibrary.shared().register(observer)
            logger.info("capture.started")
        case .limited:
            logger.warning("capture.degraded — reason: limitedAccess")
            throw EchoSightError.captureFailed(
                NSError(domain: "echosight.capture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Photos limited access — full access required"])
            )
        case .denied, .restricted:
            logger.warning("capture.failed — reason: photosDenied")
            throw EchoSightError.captureFailed(
                NSError(domain: "echosight.capture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Photos access denied or restricted"])
            )
        case .notDetermined:
            logger.warning("capture.failed — reason: permissionNotDetermined (call requestPhotoLibraryAccess() first)")
            throw EchoSightError.captureFailed(
                NSError(domain: "echosight.capture", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Photos permission not yet requested"])
            )
        @unknown default:
            logger.warning("capture.failed — reason: unknownAuthorizationStatus")
            throw EchoSightError.captureFailed(nil)
        }
    }

    public func stop() async {
        _isActive = false
        if let observer = screenshotObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            screenshotObserver = nil
        }
        framesContinuation?.finish()
        logger.info("capture.stopped")
    }

    /// Conformance to `PassthroughCaptureSource`. Waits for the next frame with
    /// an 800 ms timeout. The actual capture is triggered by the user's hardware
    /// gesture (Digital Crown + Capture Button) — this method awaits delivery.
    ///
    /// Only one concurrent caller is supported. A second call while one is in flight
    /// throws immediately to prevent both from racing on the same shared stream.
    public func captureFrame() async throws -> CapturedFrame {
        guard !captureInFlight else {
            throw EchoSightError.captureFailed(
                NSError(domain: "echosight.capture", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "captureFrame() called while a capture is already in flight"])
            )
        }
        captureInFlight = true
        defer { captureInFlight = false }

        logger.info("capture.requested")

        return try await withThrowingTaskGroup(of: CapturedFrame.self) { group in
            // Frame waiter
            group.addTask { [frames] in
                for await frame in frames {
                    return frame
                }
                throw EchoSightError.captureFailed(nil)
            }

            // Timeout — throws after 800 ms so the frame waiter task is cancelled
            group.addTask {
                try await Task.sleep(for: .milliseconds(800))
                throw EchoSightError.captureFailed(
                    NSError(domain: "echosight.capture", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "capture timeout"])
                )
            }

            // P1-1 fix: use guard let instead of force-unwrap
            guard let result = try await group.next() else {
                throw EchoSightError.captureFailed(nil)
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Capture handler (called by ScreenshotObserver)

    /// Called by ScreenshotObserver on the main actor via Task hop.
    ///
    /// Records delivery timestamp immediately on entry, then fetches the
    /// corresponding `PHAsset` to obtain the authoritative shutter timestamp.
    public func handleCapture(_ image: UIImage) async {
        let machTimestamp = CACurrentMediaTime()
        let deliveryTimestamp = Date()
        logger.info("capture.delivered — at: \(deliveryTimestamp.timeIntervalSince1970)")

        // Guard against zero-size images
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
            let deliveryMs = Int(deliveryTimestamp.timeIntervalSinceNow * -1000)
            logger.info("capture.shutter — shutterMs: \(shutterMs)")
            logger.info("capture.delivered — deliveryMs: \(deliveryMs), lagMs: \(lagMs)")
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
                name: PhotosLibraryCaptureSource.firstCaptureNotification, object: nil
            )
        }

        let frame = CapturedFrame(
            image: image,
            shutterTimestamp: shutterTimestamp,
            deliveryTimestamp: deliveryTimestamp,
            machTimestamp: machTimestamp,
            outcome: outcome
        )
        framesContinuation?.yield(frame)
    }

    // MARK: - Authorization

    /// Requests Full Photos access. Returns `false` for `.limited` —
    /// Full access required; .limited is insufficient for screenshot monitoring.
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

// MARK: - ScreenshotObserver

private final class ScreenshotObserver: NSObject, PHPhotoLibraryChangeObserver {
    private weak var source: PhotosLibraryCaptureSource?
    private var lastSeenLocalIdentifier: String?

    init(source: PhotosLibraryCaptureSource) {
        self.source = source
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(
            format: "mediaSubtype == %d", PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = result.firstObject else { return }
        guard asset.localIdentifier != lastSeenLocalIdentifier else { return }
        lastSeenLocalIdentifier = asset.localIdentifier

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isSynchronous = false
        manager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: requestOptions
        ) { [weak self] image, _ in
            guard let self, let image, let source = self.source else { return }
            Task { @MainActor in await source.handleCapture(image) }
        }
    }
}
