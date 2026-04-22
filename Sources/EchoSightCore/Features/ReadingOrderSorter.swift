import Foundation

// MARK: - ReadingOrderSorter

/// Sorts `RawTextObservation` values into natural reading order.
///
/// Algorithm:
/// 1. Partition observations into horizontal y-bands. Band threshold: ~5% of image height
///    (0.05 in normalized coordinates). Observations whose bounding-box `minY` values
///    fall within the same band are considered the same "row".
/// 2. Within each band, sort by `boundingBox.minX` (left-to-right).
/// 3. Bands are sorted top-to-bottom (descending `boundingBox.minY` because Vision
///    uses a bottom-left origin — higher `minY` = closer to top of image).
///
/// Note: Vision coordinates have origin at bottom-left, Y increasing upward.
/// "Top" of image = highest `minY` value. We sort bands descending by `minY`.
///
/// This heuristic handles:
/// - Signs and labels: single row, sorted left-to-right.
/// - Bullet lists: each bullet = one row.
/// - Multi-column (magazine/newspaper): reads left column top-to-bottom, then
///   right column top-to-bottom. Not ideal for interleaved columns but acceptable
///   for v0.1 — degrades gracefully (reads something, never crashes).
public enum ReadingOrderSorter {

    // MARK: - Configuration

    /// Y-band threshold in normalized image coordinates (0–1).
    /// Observations within this vertical range of each other are in the same row.
    public static let bandThreshold: CGFloat = 0.05

    // MARK: - Public API

    /// Sort observations into reading order.
    ///
    /// - Parameters:
    ///   - observations: `RawTextObservation` values extracted from Vision results.
    ///   - bandThreshold: Override the Y-band threshold. Default `bandThreshold`.
    /// - Returns: Observations sorted top-to-bottom, left-to-right within each row.
    public static func sort(
        _ observations: [RawTextObservation],
        bandThreshold: CGFloat = ReadingOrderSorter.bandThreshold
    ) -> [RawTextObservation] {
        guard observations.count > 1 else { return observations }

        // Group by y-band. Key = representative minY for the band.
        var bands: [(bandY: CGFloat, observations: [RawTextObservation])] = []

        for obs in observations {
            let y = obs.boundingBox.minY
            if let idx = bands.firstIndex(where: { abs($0.bandY - y) < bandThreshold }) {
                bands[idx].observations.append(obs)
            } else {
                bands.append((bandY: y, observations: [obs]))
            }
        }

        // Sort bands top-to-bottom: highest minY first (Vision: Y=1 = top of image).
        let sortedBands = bands.sorted { $0.bandY > $1.bandY }

        // Within each band, sort left-to-right by minX.
        return sortedBands.flatMap { band in
            band.observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }
}
