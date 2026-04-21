import Foundation
import Testing
@testable import EchoSightCore

// MARK: - LabelReconcilerTests

struct LabelReconcilerTests {

    // MARK: - Rule 1: Person bypass

    @Test
    func personLabelBypassesMesh() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "person",
            meshClassification: LabelReconciler.MeshClass.floor,
            meshDistance: 1.5
        )
        #expect(result.label == "person")
        if case .degraded(let reason) = result.outcome {
            #expect(reason == .personBypass, "Expected .personBypass, got \(reason)")
        } else {
            Issue.record("Expected .degraded(.personBypass), got \(result.outcome)")
        }
        // Person uses shoulder heuristic, not mesh distance
        #expect(abs(result.distance - kPersonShoulderHeightM) < 1e-5)
    }

    @Test
    func personLabelBypassesMeshEvenWithNoMeshHit() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "person",
            meshClassification: nil,
            meshDistance: nil
        )
        if case .degraded(let reason) = result.outcome {
            #expect(reason == .personBypass)
        } else {
            Issue.record("Expected .personBypass for person with no mesh hit")
        }
    }

    // MARK: - Rule 2: No mesh hit → raycastMiss

    @Test
    func noMeshHitProducesRaycastMiss() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "chair",
            meshClassification: nil,
            meshDistance: nil
        )
        #expect(result.label == "chair")
        if case .degraded(let reason) = result.outcome {
            #expect(reason == .raycastMiss, "Expected .raycastMiss, got \(reason)")
        } else {
            Issue.record("Expected .degraded(.raycastMiss), got \(result.outcome)")
        }
        #expect(abs(result.distance - kDefaultRaycastDistanceM) < 1e-5)
    }

    @Test
    func noMeshHitPreservesDetectorLabel() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "window",
            meshClassification: nil,
            meshDistance: nil
        )
        #expect(result.label == "window")
    }

    // MARK: - Rule 3: Agreement → normal

    @Test
    func chairAndSeatMeshAgree() {
        // "chair" from detector, "seat" from mesh — semantic equivalence
        let result = LabelReconciler.reconcile(
            detectorLabel: "chair",
            meshClassification: LabelReconciler.MeshClass.seat,
            meshDistance: 2.5
        )
        #expect(result.label == "chair")
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for chair/seat agreement, got \(result.outcome)")
        }
        #expect(abs(result.distance - 2.5) < 1e-5)
    }

    @Test
    func wallAndWallAgree() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "wall",
            meshClassification: LabelReconciler.MeshClass.wall,
            meshDistance: 1.8
        )
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for wall/wall agreement, got \(result.outcome)")
        }
    }

    @Test
    func windowAndWindowAgree() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "window",
            meshClassification: LabelReconciler.MeshClass.window,
            meshDistance: 3.0
        )
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for window/window agreement, got \(result.outcome)")
        }
    }

    // MARK: - Rule 4: Small object + supporting surface → prefer detector

    @Test
    func chairOnFloorPrefersDetectorLabel() {
        // Detector says "chair", mesh says "floor" — small object on supporting surface
        let result = LabelReconciler.reconcile(
            detectorLabel: "chair",
            meshClassification: LabelReconciler.MeshClass.floor,
            meshDistance: 2.0
        )
        #expect(result.label == "chair", "Should prefer detector label 'chair' over mesh 'floor'")
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for small-object-on-surface, got \(result.outcome)")
        }
        // Keep mesh distance (more accurate than default)
        #expect(abs(result.distance - 2.0) < 1e-5)
    }

    @Test
    func cupOnTablePrefersDetectorLabel() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "cup",
            meshClassification: LabelReconciler.MeshClass.table,
            meshDistance: 0.8
        )
        #expect(result.label == "cup")
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for cup/table, got \(result.outcome)")
        }
    }

    // MARK: - Rule 5: Other disagreement → prefer detector

    @Test
    func chairOnWallPrefersDetectorLabel() {
        // Unusual case: raycast hits wall but detector says chair
        let result = LabelReconciler.reconcile(
            detectorLabel: "chair",
            meshClassification: LabelReconciler.MeshClass.wall,
            meshDistance: 3.5
        )
        #expect(result.label == "chair")
        if case .normal = result.outcome {
            // pass
        } else {
            Issue.record("Expected .normal for other disagreement, got \(result.outcome)")
        }
    }

    // MARK: - Distance preservation

    @Test
    func meshDistancePreservedOnAgreement() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "chair",
            meshClassification: LabelReconciler.MeshClass.seat,
            meshDistance: 1.23
        )
        #expect(abs(result.distance - 1.23) < 1e-4)
    }

    @Test
    func defaultDistanceUsedOnRaycastMiss() {
        let result = LabelReconciler.reconcile(
            detectorLabel: "door",
            meshClassification: nil,
            meshDistance: nil
        )
        #expect(abs(result.distance - kDefaultRaycastDistanceM) < 1e-5)
    }
}
