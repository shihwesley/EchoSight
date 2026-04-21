import CryptoKit
import Foundation

// MARK: - PrivacyFilter

/// Sanitizes `PipelineEvent` metadata before log export, and provides the
/// canonical anchor-ID hashing helper used at every log call site.
///
/// Strips metadata keys matching sensitive patterns (content, text, frame,
/// prompt, transcript) so raw captured text, OCR results, and Gemma prompts
/// never appear in exported log files.
public enum PrivacyFilter {

    // MARK: - Key Patterns

    /// Case-insensitive patterns. Any metadata key matching one of these is stripped.
    private static let sensitivePatterns: [String] = [
        "content", "text", "frame", "prompt", "transcript",
    ]

    // MARK: - API

    /// Returns a copy of `event` with sensitive metadata keys removed.
    public static func sanitize(event: PipelineEvent) -> PipelineEvent {
        let sanitizedMetadata = event.metadata.filter { key, _ in
            !isSensitive(key: key)
        }
        return PipelineEvent(
            category: event.category,
            event: event.event,
            durationMs: event.durationMs,
            outcome: event.outcome,
            metadata: sanitizedMetadata,
            timestamp: event.timestamp
        )
    }

    /// Returns `true` if the key matches any sensitive pattern (case-insensitive).
    public static func isSensitive(key: String) -> Bool {
        let lower = key.lowercased()
        return sensitivePatterns.contains { lower.contains($0) }
    }

    /// Returns the 12-hex-char SHA-256 prefix of a UUID for use in log lines.
    ///
    /// Use this at the call site of any log emission that mentions an anchor
    /// identifier so raw UUIDs never reach stdout or OSLog, even before
    /// `LogExporter` runs.
    public static func hashAnchorId(_ id: UUID) -> String {
        let data = Data(id.uuidString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(12) + "…"
    }
}
