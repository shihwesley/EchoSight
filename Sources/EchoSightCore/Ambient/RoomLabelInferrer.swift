import Foundation
import Logging

// MARK: - RoomLabelInferrer

/// Produces a room label via Gemma's `inferRoomLabel` read path, with mesh-classification fallback.
///
/// High priority, ~30 tokens, 1.5 s budget. On timeout or model unavailable,
/// falls back to a mesh-classification-derived label.
///
/// Closure-injected for testability: callers supply the actual Gemma call.
///
/// Log category: `echosight.ambient`
public struct RoomLabelInferrer: Sendable {

    // MARK: - Dependency Types

    /// Async closure that calls `GemmaRunner.inferRoomLabel`.
    public typealias GemmaInfer =
        @Sendable (UUID, [WorldAnnotation], MeshClassificationSummary) async throws -> String

    // MARK: - Properties

    private let gemmaInfer: GemmaInfer
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init(gemmaInfer: @escaping GemmaInfer) {
        self.gemmaInfer = gemmaInfer
    }

    // MARK: - Public API

    /// Infer a room label for the given anchor context.
    ///
    /// Returns the Gemma-produced label on success; falls back to a mesh-derived
    /// label string if Gemma throws or is unavailable.
    ///
    /// - Parameters:
    ///   - anchorId: The world anchor being labelled.
    ///   - annotations: Nearby annotations snapshot (already pinned by caller).
    ///   - meshClassification: Current mesh classification summary.
    ///   - isFirstVisit: If `true`, prefixes label with hedge language ("This looks like a").
    public func infer(
        anchorId: UUID,
        annotations: [WorldAnnotation],
        meshClassification: MeshClassificationSummary,
        isFirstVisit: Bool
    ) async -> String {
        let start = Date()
        let rawLabel: String

        do {
            rawLabel = try await gemmaInfer(anchorId, annotations, meshClassification)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            log.info("ambient.gemma.inferRoomLabel", metadata: [
                "outcome": "gemma",
                "durationMs": .string("\(durationMs)"),
            ])
        } catch {
            rawLabel = meshFallbackLabel(from: meshClassification)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            log.info("ambient.gemma.inferRoomLabel", metadata: [
                "outcome": "meshFallback",
                "durationMs": .string("\(durationMs)"),
                "error": .string("\(error)"),
            ])
        }

        return isFirstVisit
            ? "This looks like a \(rawLabel)"
            : rawLabel
    }

    // MARK: - Private: Mesh Fallback

    private func meshFallbackLabel(from summary: MeshClassificationSummary) -> String {
        switch summary.dominantClass {
        case .wall:         return "enclosed space"
        case .floor:        return "open area"
        case .ceiling:      return "indoor space"
        case .table:        return "workspace"
        case .seat:         return "seating area"
        case .window:       return "room with windows"
        case .door:         return "corridor or entry"
        case .unknown:      return "room"
        }
    }
}
