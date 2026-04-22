import Foundation

// MARK: - DefaultQuerySet

/// The default set of object classes to detect for "describe scene" mode.
///
/// These labels correspond to COCO-80 class names used by the YOLO11n model.
/// Tuned for indoor navigation relevance (BLV use case).
public enum DefaultQuerySet {

    /// The default indoor scene labels (8 classes).
    public static let labels: Set<String> = [
        "person",
        "chair",
        "door",       // not a COCO class, but VNRecognizeObjectsRequest may return it
        "wall",       // not a COCO class; kept for VNRecognizeObjectsRequest fallback
        "table",
        "stairs",     // not standard COCO; kept for future model
        "step",
        "window"
    ]

    /// The subset of DefaultQuerySet labels that appear in the COCO-80 vocabulary.
    /// Used to filter YOLO results to relevant classes only.
    public static let cocoLabels: Set<String> = [
        "person",
        "chair",
        "dining table"
    ]

    /// Returns true if the given label is in the default query set or its COCO
    /// equivalent set. Case-insensitive comparison.
    public static func contains(_ label: String) -> Bool {
        let lower = label.lowercased()
        return labels.contains(lower) || cocoLabels.contains(lower)
    }
}
