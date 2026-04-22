import Foundation
import CryptoKit
import Logging

// MARK: - ModelVerifier

/// Verifies a downloaded model file by comparing its SHA-256 digest against the manifest entry.
///
/// Reading the file is synchronous on the calling thread. Callers should dispatch to a
/// background queue (e.g., Task { ... }) to avoid blocking the main actor.
///
/// On mismatch: deletes the file and returns `.mismatch`. The caller is responsible
/// for restarting the download.
///
/// Log category: `echosight.download`
public enum ModelVerifier {

    // MARK: - Result

    public enum VerifyResult: Sendable {
        case verified
        case mismatch(fileDigest: String, expected: String)
        case readError(Error)
    }

    // MARK: - Public API

    /// Verify a file at `fileURL` against the expected SHA-256 hex string.
    ///
    /// Deletes the file if the digest does not match.
    public static func verify(
        fileURL: URL,
        expectedSHA256: String,
        deleteOnMismatch: Bool = true
    ) -> VerifyResult {
        let log = Logger(label: "echosight.download")

        let fileDigest: String
        do {
            fileDigest = try sha256HexDigest(of: fileURL)
        } catch {
            log.error("download.shaVerify.readError", metadata: [
                "file": .string(fileURL.lastPathComponent),
                "error": .string(error.localizedDescription),
            ])
            return .readError(error)
        }

        // SHA256 hex strings are case-insensitive.
        if fileDigest.lowercased() == expectedSHA256.lowercased() {
            log.info("download.shaVerify.success", metadata: [
                "fileName": .string(fileURL.lastPathComponent),
            ])
            return .verified
        } else {
            log.error("download.shaVerify.failed", metadata: [
                "fileName": .string(fileURL.lastPathComponent),
                "expected": .string(String(expectedSHA256.prefix(16)) + "…"),
                "actual":   .string(String(fileDigest.prefix(16)) + "…"),
            ])
            if deleteOnMismatch {
                try? FileManager.default.removeItem(at: fileURL)
                log.info("download.shaVerify.deletedMismatch", metadata: [
                    "fileName": .string(fileURL.lastPathComponent),
                ])
            }
            return .mismatch(fileDigest: fileDigest, expected: expectedSHA256)
        }
    }

    // MARK: - Private

    private static func sha256HexDigest(of fileURL: URL) throws -> String {
        let bufferSize = 1024 * 1024  // 1 MB chunks
        guard let stream = InputStream(url: fileURL) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if bytesRead == 0 { break }
            hasher.update(data: Data(buffer[..<bytesRead]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
