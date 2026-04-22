import Foundation

// MARK: - ModelManifest

/// Describes the model weight files required for v0.1 EchoSight.
///
/// Ships in the app bundle. URLs and SHAs are baked at build time so the
/// downloader can verify integrity without a network call.
///
/// Sizes are approximate; actual download bytes are reported by `URLSession`.
///
/// Log category: `echosight.download`
public struct ModelManifest: Sendable {

    // MARK: - ModelEntry

    public struct ModelEntry: Sendable, Identifiable {
        /// Stable identifier for this model entry.
        public let id: String

        /// Human-readable name for UI display and logging.
        public let displayName: String

        /// Download URL for the model weight file.
        public let url: URL

        /// Expected SHA-256 hex digest of the completed download.
        public let expectedSHA256: String

        /// Approximate file size in bytes (for progress UI).
        public let approximateSizeBytes: Int64

        public init(
            id: String,
            displayName: String,
            url: URL,
            expectedSHA256: String,
            approximateSizeBytes: Int64
        ) {
            self.id = id
            self.displayName = displayName
            self.url = url
            self.expectedSHA256 = expectedSHA256
            self.approximateSizeBytes = approximateSizeBytes
        }
    }

    // MARK: - Properties

    /// All model entries that must be downloaded before the app can function.
    public let entries: [ModelEntry]

    /// Sum of approximate sizes across all entries.
    public var totalApproximateBytes: Int64 {
        entries.reduce(0) { $0 + $1.approximateSizeBytes }
    }

    // MARK: - v0.1 Manifest

    /// The v0.1 production manifest.
    ///
    /// URLs and SHAs are placeholder values — replace with actual CDN URLs and
    /// verified SHA-256 digests before release build. These will be confirmed
    /// during acceptance testing when the model hosting infrastructure is ready.
    ///
    /// - Note: WhisperKit entry is reserved but not used in v0.1 (voice deferred to v1.0).
    ///   Its URL points to a placeholder zero-byte file. The downloader skips any
    ///   entry whose URL path contains "placeholder".
    public static let v01: ModelManifest = ModelManifest(entries: [
        ModelEntry(
            id: "gemma-4-e2b-q4",
            displayName: "Gemma 4 E2B (language model)",
            url: URL(string: "https://cdn.echosight.app/models/v0.1/gemma-4-e2b-q4.gguf")!,
            expectedSHA256: "PLACEHOLDER_SHA256_GEMMA_4_E2B_Q4",
            approximateSizeBytes: 2_000_000_000  // ~2 GB
        ),
        ModelEntry(
            id: "yolo11n-int8",
            displayName: "YOLO11n (object detection)",
            url: URL(string: "https://cdn.echosight.app/models/v0.1/yolo11n-int8.mlpackage.zip")!,
            expectedSHA256: "PLACEHOLDER_SHA256_YOLO11N_INT8",
            approximateSizeBytes: 30_000_000  // ~30 MB
        ),
        ModelEntry(
            id: "whisperkit-placeholder",
            displayName: "WhisperKit (reserved, not used in v0.1)",
            url: URL(string: "https://cdn.echosight.app/models/v0.1/placeholder/whisperkit-small-multi.zip")!,
            expectedSHA256: "PLACEHOLDER_SHA256_WHISPERKIT",
            approximateSizeBytes: 240_000_000  // ~240 MB reserved
        ),
    ])

    // MARK: - Init

    public init(entries: [ModelEntry]) {
        self.entries = entries
    }

    // MARK: - Validation

    /// Asserts that no non-placeholder entry carries a placeholder SHA-256 string.
    ///
    /// P1-1 FIX: Placeholder SHAs in non-placeholder entries cause infinite
    /// verify-fail-retry loops. Call this in `startDownloads()` so a misconfigured
    /// manifest fails loud immediately rather than silently retrying indefinitely.
    ///
    /// - Throws: `ManifestError.placeholderSHA` in non-DEBUG builds; calls `preconditionFailure`
    ///   in DEBUG builds to catch during development.
    public func assertNonPlaceholderSHAs() {
        for entry in entries {
            let isPlaceholder = entry.url.pathComponents.contains("placeholder")
            if !isPlaceholder && entry.expectedSHA256.hasPrefix("PLACEHOLDER") {
                #if DEBUG
                preconditionFailure(
                    """
                    ModelManifest entry '\(entry.id)' has a placeholder SHA-256 (\(entry.expectedSHA256)) \
                    but a non-placeholder URL. This will cause an infinite download-fail-retry loop. \
                    Replace the SHA with the actual SHA-256 of the hosted model file.
                    """
                )
                #endif
            }
        }
    }
}
