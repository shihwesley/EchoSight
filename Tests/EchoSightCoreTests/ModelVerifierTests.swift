import Testing
import Foundation
import CryptoKit
@testable import EchoSightCore

// MARK: - ModelVerifierTests

@Suite("ModelVerifier")
struct ModelVerifierTests {

    // MARK: - Helpers

    private func tmpFile(content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try content.write(to: url)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Tests

    @Test("Correct SHA-256 returns .verified")
    func correctSHAVerifies() throws {
        let content = Data("EchoSight model content".utf8)
        let url = try tmpFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = sha256Hex(content)
        let result = ModelVerifier.verify(fileURL: url, expectedSHA256: expected, deleteOnMismatch: false)
        guard case .verified = result else {
            Issue.record("Expected .verified, got \(result)")
            return
        }
    }

    @Test("Mismatched SHA-256 returns .mismatch and deletes file")
    func mismatchedSHADeletesFile() throws {
        let content = Data("model content".utf8)
        let url = try tmpFile(content: content)

        let result = ModelVerifier.verify(
            fileURL: url,
            expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
            deleteOnMismatch: true
        )
        guard case .mismatch = result else {
            Issue.record("Expected .mismatch, got \(result)")
            // Clean up if test assertion fails
            try? FileManager.default.removeItem(at: url)
            return
        }
        // File should be deleted
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Mismatched SHA-256 with deleteOnMismatch=false preserves file")
    func mismatchNoDeletePreservesFile() throws {
        let content = Data("model content".utf8)
        let url = try tmpFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = ModelVerifier.verify(
            fileURL: url,
            expectedSHA256: "bad_hash",
            deleteOnMismatch: false
        )
        guard case .mismatch = result else {
            Issue.record("Expected .mismatch")
            return
        }
        // File should still exist
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Non-existent file returns .readError")
    func nonExistentFileReadError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID()).bin")
        let result = ModelVerifier.verify(
            fileURL: url,
            expectedSHA256: "abc123",
            deleteOnMismatch: false
        )
        guard case .readError = result else {
            Issue.record("Expected .readError for missing file")
            return
        }
    }

    @Test("Empty file verifies against correct empty-file SHA")
    func emptyFileVerifiesCorrectly() throws {
        let url = try tmpFile(content: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = sha256Hex(Data())
        let result = ModelVerifier.verify(fileURL: url, expectedSHA256: expected, deleteOnMismatch: false)
        guard case .verified = result else {
            Issue.record("Expected .verified for empty file with correct SHA")
            return
        }
    }

    @Test("SHA comparison is case-insensitive")
    func shaComparisonCaseInsensitive() throws {
        let content = Data("test".utf8)
        let url = try tmpFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = sha256Hex(content).uppercased()  // uppercase version
        let result = ModelVerifier.verify(fileURL: url, expectedSHA256: expected, deleteOnMismatch: false)
        guard case .verified = result else {
            Issue.record("SHA comparison should be case-insensitive")
            return
        }
    }
}
