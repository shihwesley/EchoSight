import Foundation
import simd

// MARK: - SpatialHash

/// Uniform-grid spatial index for O(1) amortised radius queries.
///
/// Grid cell size: 1 m. Annotation IDs are bucketed by their world-space grid cell.
/// A radius query returns the union of all cells overlapping the query sphere —
/// callers are expected to fine-filter results to the exact radius.
///
/// Value type: copying `SpatialHash` produces an independent snapshot, which
/// satisfies the snapshot-pinning requirement for Gemma read paths.
public struct SpatialHash: Sendable {

    // MARK: - Types

    /// Integer 3D grid cell coordinate.
    public struct GridCell: Hashable, Sendable {
        public let x: Int
        public let y: Int
        public let z: Int
    }

    // MARK: - Constants

    /// Cell edge length in meters.
    public static let cellSize: Float = 1.0

    // MARK: - Storage

    /// Maps grid cell → set of annotation UUIDs whose position falls in that cell.
    private var cells: [GridCell: Set<UUID>] = [:]

    /// Reverse map: annotation UUID → current cell. Needed for O(1) update/remove.
    private var idToCell: [UUID: GridCell] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Mutation

    /// Inserts `id` at `position`. Idempotent — re-inserting the same id at the
    /// same cell is a no-op.
    public mutating func insert(id: UUID, position: SIMD3<Float>) {
        let cell = gridCell(for: position)
        if idToCell[id] == cell { return }  // already in correct cell
        // Remove from old cell if moving
        if let old = idToCell[id] {
            cells[old]?.remove(id)
            if cells[old]?.isEmpty == true { cells.removeValue(forKey: old) }
        }
        cells[cell, default: []].insert(id)
        idToCell[id] = cell
    }

    /// Updates the position of an existing annotation.
    /// Equivalent to `insert` — handles cell change automatically.
    public mutating func update(id: UUID, position: SIMD3<Float>) {
        insert(id: id, position: position)
    }

    /// Removes an annotation from the index.
    public mutating func remove(id: UUID) {
        guard let cell = idToCell.removeValue(forKey: id) else { return }
        cells[cell]?.remove(id)
        if cells[cell]?.isEmpty == true { cells.removeValue(forKey: cell) }
    }

    // MARK: - Query

    /// Returns all annotation IDs in cells that overlap a sphere of `radius` centred at `point`.
    ///
    /// Callers must fine-filter to exact distance. The returned set may contain IDs
    /// outside the sphere (cells are square, spheres are round).
    public func candidateIds(near point: SIMD3<Float>, radius: Float) -> Set<UUID> {
        let cellRadius = Int((radius / Self.cellSize).rounded(.up))
        let origin = gridCell(for: point)
        var result: Set<UUID> = []
        for dx in -cellRadius...cellRadius {
            for dy in -cellRadius...cellRadius {
                for dz in -cellRadius...cellRadius {
                    let candidate = GridCell(
                        x: origin.x + dx,
                        y: origin.y + dy,
                        z: origin.z + dz
                    )
                    if let ids = cells[candidate] {
                        result.formUnion(ids)
                    }
                }
            }
        }
        return result
    }

    /// Total number of indexed annotations.
    public var count: Int { idToCell.count }

    // MARK: - Private

    private func gridCell(for position: SIMD3<Float>) -> GridCell {
        GridCell(
            x: Int(floor(position.x / Self.cellSize)),
            y: Int(floor(position.y / Self.cellSize)),
            z: Int(floor(position.z / Self.cellSize))
        )
    }
}
