import Foundation
import Logging

// MARK: - FalconDetector

/// Stub implementation of `Detector` for the Falcon-Perception mlx-swift port.
///
/// The Falcon port lands post-v0.1 as a drop-in replacement for `VisionDetector`.
/// This stub satisfies the protocol so dependents can reference it without
/// functional implementation.
///
/// Calling `detect(in:)` throws `EchoSightError.detectorUnavailable`.
public actor FalconDetector: Detector {

    // MARK: - Private

    private let logger = Logger(label: LogCategories.detector)

    // MARK: - Init

    public init() {}

    // MARK: - Detector

    public var isReady: Bool { false }

    public func load() async throws {
        logger.warning("detector.falcon — load() called but Falcon is not available in v0.1")
        throw EchoSightError.detectorUnavailable
    }

    public func unload() async {
        // No-op: nothing to unload
    }

    public func detect(in frame: CapturedFrame) async throws -> [DetectionResult] {
        logger.warning("detector.falcon — detect() called but Falcon is not available in v0.1")
        throw EchoSightError.detectorUnavailable
    }
}
