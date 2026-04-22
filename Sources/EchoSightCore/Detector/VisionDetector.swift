import CoreML
@preconcurrency import Dispatch
import Foundation
import Logging
import UIKit
@preconcurrency import Vision

// MARK: - VisionDetector

/// `Detector` implementation backed by the YOLO11n Core ML model.
///
/// On load, the model is fetched from the app bundle and compiled into memory
/// using `.cpuAndNeuralEngine` compute units (preferred for small models on AVP).
/// A warm-up inference is run against a 1×1 zero image to prime the ANE before
/// the first real capture arrives.
///
/// Each `detect(in:)` call builds a fresh `VNCoreMLRequest` (not stored as a
/// property — required for Swift 6 Sendable compliance) and runs it synchronously
/// inside a `withCheckedThrowingContinuation` bridge.
///
/// A 2-second timeout wraps each call. Exceeding it returns `[]` and logs
/// `detector.timeout`.
public actor VisionDetector: Detector {

    // MARK: - Private state

    private let logger = Logger(label: LogCategories.detector)
    /// Serial queue shared by `detect(in:)` and `warmUpInference()`. Owned by the
    /// actor so we don't allocate a fresh queue per call (Sprint 2.1 P2 #1 fix).
    private let inferenceQueue = DispatchQueue(
        label: "echosight.detector.inference",
        qos: .userInitiated
    )
    private var mlModel: MLModel?
    private var vnModel: VNCoreMLModel?
    private var _isWarm = false
    private var _isLoading = false

    // MARK: - Init

    public init() {}

    // MARK: - Detector conformance

    public var isReady: Bool {
        mlModel != nil && _isWarm
    }

    /// Load and warm-up the YOLO11n model.
    ///
    /// Idempotent: a second call while a load is in progress or already complete
    /// returns immediately without re-loading.
    public func load() async throws {
        guard mlModel == nil, !_isLoading else { return }
        _isLoading = true
        defer { _isLoading = false }

        logger.info("detector.warmUp.started")
        let start = Date()

        let modelURL = try bundledModelURL()

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let loaded: MLModel
        do {
            loaded = try await MLModel.load(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error("detector.error — reason: modelLoad, detail: \(error.localizedDescription)")
            throw EchoSightError.modelLoadFailed(modelURL.lastPathComponent)
        }

        let vnLoaded: VNCoreMLModel
        do {
            vnLoaded = try VNCoreMLModel(for: loaded)
        } catch {
            logger.error("detector.error — reason: vnModelCreate, detail: \(error.localizedDescription)")
            throw EchoSightError.modelLoadFailed("VNCoreMLModel creation failed")
        }

        self.mlModel = loaded
        self.vnModel = vnLoaded

        // Warm-up: prime the ANE with a dummy 1×1 inference
        await warmUpInference()

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("detector.warmUp.completed — durationMs: \(durationMs)")
        _isWarm = true
    }

    public func unload() async {
        mlModel = nil
        vnModel = nil
        _isWarm = false
        logger.info("detector.unloaded")
    }

    /// Run object detection on the given frame.
    ///
    /// Applies a 2-second timeout. Returns `[]` on timeout rather than throwing,
    /// to keep the scene-mode pipeline running even if a frame takes too long.
    ///
    /// Swift 6 note: `VNCoreMLModel` is not Sendable, so Vision inference runs
    /// synchronously on a background DispatchQueue via `withCheckedThrowingContinuation`.
    /// This keeps the model on the actor's heap without crossing task boundaries.
    public func detect(in frame: CapturedFrame) async throws -> [DetectionResult] {
        guard let vnModel else {
            logger.warning("detector.error — reason: modelNotLoaded")
            throw EchoSightError.detectorUnavailable
        }

        let frameId = frame.shutterTimestamp.timeIntervalSince1970
        logger.info("detector.detect.started — frameId: \(frameId)")
        let start = Date()

        // Run inference synchronously on the actor-owned background queue.
        // withCheckedThrowingContinuation suspends the actor until the queue fires.
        // The 2-second budget is enforced by a DispatchWorkItem deadline.
        // Note: P2 — this timeout pattern cannot interrupt a running Vision
        // inference (`handler.perform` is synchronous). A `withThrowingTaskGroup`
        // rewrite would be stylistically cleaner but carries the same limitation,
        // so the refactor is deferred until sim test coverage is available.
        let results: [DetectionResult]

        do {
            results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[DetectionResult], Error>) in
                let flag = _ResumeFlag()
                let lock = NSLock()

                let work = DispatchWorkItem {
                    guard let cgImage = frame.image.cgImage else {
                        lock.lock()
                        guard !flag.value else { lock.unlock(); return }
                        flag.value = true
                        lock.unlock()
                        continuation.resume(returning: [])
                        return
                    }
                    let request = VNCoreMLRequest(model: vnModel)
                    request.imageCropAndScaleOption = .scaleFit
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    do {
                        try handler.perform([request])
                        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
                        let detections = observations.compactMap { obs -> DetectionResult? in
                            guard let topLabel = obs.labels.first else { return nil }
                            let flippedY = 1.0 - obs.boundingBox.origin.y - obs.boundingBox.height
                            return DetectionResult(
                                anchorPoint: CGPoint(
                                    x: obs.boundingBox.origin.x + obs.boundingBox.width / 2.0,
                                    y: flippedY + obs.boundingBox.height / 2.0
                                ),
                                size: CGSize(
                                    width: obs.boundingBox.width,
                                    height: obs.boundingBox.height
                                ),
                                label: topLabel.identifier,
                                confidence: topLabel.confidence
                            )
                        }.sorted { $0.confidence > $1.confidence }

                        lock.lock()
                        guard !flag.value else { lock.unlock(); return }
                        flag.value = true
                        lock.unlock()
                        continuation.resume(returning: detections)
                    } catch {
                        lock.lock()
                        guard !flag.value else { lock.unlock(); return }
                        flag.value = true
                        lock.unlock()
                        continuation.resume(throwing: error)
                    }
                }

                // 2-second timeout
                inferenceQueue.asyncAfter(deadline: .now() + 2.0) {
                    lock.lock()
                    guard !flag.value else { lock.unlock(); return }
                    flag.value = true
                    lock.unlock()
                    work.cancel()
                    continuation.resume(returning: [])
                }

                inferenceQueue.async(execute: work)
            }
        } catch {
            logger.warning("detector.timeout — frameId: \(frameId)")
            return []
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        if durationMs >= 2000 {
            logger.warning("detector.timeout — frameId: \(frameId)")
        }
        logger.info("detector.detect.completed — frameId: \(frameId), count: \(results.count), durationMs: \(durationMs)")
        return results
    }

    // MARK: - Private helpers

    private func bundledModelURL() throws -> URL {
        // Look in the bundle for yolo11n-int8.mlpackage or compiled .mlmodelc
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "yolo11n-int8", withExtension: "mlpackage") {
            return url
        }
        if let url = bundle.url(forResource: "yolo11n-int8", withExtension: "mlmodelc") {
            return url
        }
        // Also try without the -int8 suffix
        if let url = bundle.url(forResource: "yolo11n", withExtension: "mlpackage") {
            return url
        }
        if let url = bundle.url(forResource: "yolo11n", withExtension: "mlmodelc") {
            return url
        }
        logger.error("detector.error — reason: modelNotFound — searched bundle for yolo11n-int8.mlpackage")
        throw EchoSightError.modelLoadFailed("yolo11n-int8.mlpackage not found in app bundle")
    }

    /// Warm up the ANE by running a dummy inference on a 1×1 black image.
    /// Uses the actor-owned `inferenceQueue` to keep VNCoreMLModel on the actor heap.
    private func warmUpInference() async {
        guard let vnModel else { return }
        let dummyImage = Self.makeBlackImage(size: CGSize(width: 1, height: 1))
        guard let cgImage = dummyImage.cgImage else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inferenceQueue.async {
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFit
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                continuation.resume()
            }
        }
    }

    // MARK: - Test helpers

    /// Creates a solid black UIImage of the given size.
    static func makeBlackImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - _ResumeFlag

/// Reference-type boolean flag used in the VisionDetector timeout pattern.
/// Wrapping the flag in a class satisfies Swift 6 Sendable checking for captured
/// variables in concurrent Dispatch closures — the NSLock in detect(in:) still
/// serializes all reads and writes; this is a cosmetic change only.
private final class _ResumeFlag: @unchecked Sendable {
    var value = false
}
