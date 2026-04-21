import CryptoKit
import Foundation
import Logging

// MARK: - LogExporter

/// Composes a shareable log file from the last 15 minutes of metrics.
///
/// The file is plain text, <1 MB for typical sessions. Anchor UUIDs are
/// SHA-256 hashed. No captured frames, OCR text, or Gemma prompts are included.
public actor LogExporter {

    // MARK: - Constants

    private let windowSeconds: TimeInterval = 15 * 60
    private let maxFileSizeBytes = 1_048_576 // 1 MB

    // MARK: - Dependencies

    private let buffer: PipelineMetricsBuffer
    private let log = Logger(label: LogCategories.app)

    // MARK: - Init

    public init(buffer: PipelineMetricsBuffer = .shared) {
        self.buffer = buffer
    }

    // MARK: - Export

    /// Compose and write the export file.
    ///
    /// - Returns: URL of the written file in the app's Documents directory.
    /// - Throws: If file writing fails.
    public func export() async throws -> URL {
        let events = await buffer.recentAll()
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let recent = events.filter { $0.timestamp >= cutoff }

        var lines: [String] = []
        lines.append("# EchoSight Log Export")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Events: \(recent.count)")
        lines.append("")

        for event in recent {
            let sanitized = PrivacyFilter.sanitize(event: event)
            var line = "[\(formatDate(sanitized.timestamp))] [\(sanitized.category)] \(sanitized.event)"
            if let dur = sanitized.durationMs {
                line += " \(String(format: "%.1f", dur))ms"
            }
            if !sanitized.metadata.isEmpty {
                let meta = sanitized.metadata
                    .map { k, v in "\(k)=\(hashIfAnchorId(key: k, value: v))" }
                    .joined(separator: " ")
                line += " \(meta)"
            }
            lines.append(line)
        }

        var content = lines.joined(separator: "\n")

        // Truncate if over limit.
        if content.utf8.count > maxFileSizeBytes {
            let truncated = String(content.utf8.prefix(maxFileSizeBytes)) ?? content
            content = truncated + "\n[TRUNCATED — session exceeded 1 MB export limit]"
            log.warning("echosight.app.logExport.truncated")
        }

        let url = try writeToDocuments(content: content)
        log.info("echosight.app.logExport.complete", metadata: ["url": .string(url.lastPathComponent)])
        return url
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    /// If the key is `anchorId` or contains `"anchor"`, SHA-256 hash the value.
    private func hashIfAnchorId(key: String, value: String) -> String {
        guard key.lowercased().contains("anchor") else { return value }
        let data = Data(value.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(12) + "…"
    }

    private func writeToDocuments(content: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = docs.appendingPathComponent("echosight-log-\(timestamp).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
