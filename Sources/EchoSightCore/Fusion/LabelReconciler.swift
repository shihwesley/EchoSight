import Foundation

// MARK: - LabelReconciler

/// Reconciles a detector label with an optional mesh classification and distance.
///
/// All logic is table-driven and runs on any queue (no RealityKit dependency).
/// Rules are applied in priority order; the first matching rule wins.
///
/// Rule table (priority order):
/// 1. `"person"` detected → bypass mesh, use shoulder-height heuristic
/// 2. No mesh hit (nil classification) → use detector label, default distance
/// 3. Agreement between detector label and mesh class → high confidence, normal
/// 4. Disagreement: "small object + supporting surface" → prefer detector, mesh distance
/// 5. Disagreement: other → prefer detector label, mesh distance, normal
public enum LabelReconciler {

    // MARK: - Result

    public struct Result {
        public let label: String
        public let distance: Float
        public let outcome: AnnotationCandidate.Outcome

        public init(label: String, distance: Float, outcome: AnnotationCandidate.Outcome) {
            self.label = label
            self.distance = distance
            self.outcome = outcome
        }
    }

    // MARK: - Mesh classification string alias

    /// Mesh classification string values from `SceneUnderstandingComponent.EntityClassification`.
    /// Defined here as strings to keep this type free of RealityKit dependency,
    /// which lets the reconciler be unit-tested without a RealityKit import.
    public enum MeshClass {
        public static let wall     = "wall"
        public static let floor    = "floor"
        public static let ceiling  = "ceiling"
        public static let table    = "table"
        public static let seat     = "seat"
        public static let window   = "window"
        public static let door     = "door"
        public static let unknown  = "unknown"

        /// All "supporting surface" classes where a small object resting on them
        /// should prefer the detector label over the mesh class.
        static let supportingSurfaces: Set<String> = [floor, table, seat]
    }

    // MARK: - Main reconcile

    /// Reconcile detector label against optional mesh classification.
    ///
    /// - Parameters:
    ///   - detectorLabel: Label from `VisionDetector` or `FalconDetector`.
    ///   - meshClassification: String representation of the mesh entity's classification,
    ///     or `nil` if the ray-cast missed or the entity has no `SceneUnderstandingComponent`.
    ///   - meshDistance: Distance from device to mesh hit in meters. Ignored when nil.
    /// - Returns: Reconciled label, distance, and quality outcome.
    public static func reconcile(
        detectorLabel: String,
        meshClassification: String?,
        meshDistance: Float?
    ) -> Result {
        let label = detectorLabel.lowercased()

        // Rule 1: Person detected → bypass mesh entirely
        if label == "person" {
            return Result(
                label: detectorLabel,
                distance: kPersonShoulderHeightM,
                outcome: .degraded(.personBypass)
            )
        }

        // Rule 2: No mesh hit
        guard let meshClass = meshClassification, let meshDist = meshDistance else {
            return Result(
                label: detectorLabel,
                distance: kDefaultRaycastDistanceM,
                outcome: .degraded(.raycastMiss)
            )
        }

        // Rule 3: Agreement
        if labelsAgree(detector: label, mesh: meshClass.lowercased()) {
            return Result(
                label: detectorLabel,
                distance: meshDist,
                outcome: .normal
            )
        }

        // Rule 4: Disagreement — small object on supporting surface
        // Prefer detector label (specific object), keep mesh distance (more accurate)
        if MeshClass.supportingSurfaces.contains(meshClass.lowercased()) {
            return Result(
                label: detectorLabel,
                distance: meshDist,
                outcome: .normal
            )
        }

        // Rule 5: Disagreement — other cases
        // Trust the detector for specific object identification over generic mesh class
        return Result(
            label: detectorLabel,
            distance: meshDist,
            outcome: .normal
        )
    }

    // MARK: - Private helpers

    /// Returns true if the detector label and mesh classification are semantically equivalent.
    private static func labelsAgree(detector: String, mesh: String) -> Bool {
        // Direct match
        if detector == mesh { return true }

        // Semantic equivalence table
        let equivalences: [(detector: String, mesh: String)] = [
            ("chair", MeshClass.seat),
            ("sofa", MeshClass.seat),
            ("couch", MeshClass.seat),
            ("bench", MeshClass.seat),
            ("dining table", MeshClass.table),
            ("table", MeshClass.table),
            ("wall", MeshClass.wall),
            ("window", MeshClass.window),
            ("door", MeshClass.door),
        ]
        return equivalences.contains { $0.detector == detector && $0.mesh == mesh }
    }
}
