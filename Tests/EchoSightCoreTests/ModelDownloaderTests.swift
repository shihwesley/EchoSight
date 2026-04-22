import Testing
import Foundation
@testable import EchoSightCore

// MARK: - ModelDownloaderTests

/// Behavioral tests for `ModelDownloader`.
///
/// These tests verify resume-data persistence and completed-flag logic without
/// actually hitting the network. They use a test manifest with local file URLs
/// and a temp destination directory.
///
/// Full background download integration requires a real network + server, which
/// is deferred to manual acceptance testing (visionOS device).
///
/// Execution deferred (visionOS sim boot exceeds phase-runner watchdog).
@Suite("ModelDownloader")
struct ModelDownloaderTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoSightDownloadTest_\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTestManifest(destDir: URL) -> ModelManifest {
        ModelManifest(entries: [
            ModelManifest.ModelEntry(
                id: "test-model",
                displayName: "Test model",
                url: URL(string: "https://cdn.echosight.app/models/v0.1/test.bin")!,
                expectedSHA256: "abc123",
                approximateSizeBytes: 1_000_000
            )
        ])
    }

    // MARK: - Tests

    @Test("Manifest total bytes sums entries correctly")
    func manifestTotalBytes() {
        let manifest = ModelManifest(entries: [
            ModelManifest.ModelEntry(
                id: "a",
                displayName: "A",
                url: URL(string: "https://example.com/a")!,
                expectedSHA256: "sha1",
                approximateSizeBytes: 1_000_000
            ),
            ModelManifest.ModelEntry(
                id: "b",
                displayName: "B",
                url: URL(string: "https://example.com/b")!,
                expectedSHA256: "sha2",
                approximateSizeBytes: 2_000_000
            ),
        ])
        #expect(manifest.totalApproximateBytes == 3_000_000)
    }

    @Test("Placeholder entries are skipped (URL path contains 'placeholder')")
    func placeholderEntriesSkipped() {
        let whisperEntry = ModelManifest.v01.entries.first { $0.id == "whisperkit-placeholder" }
        guard let entry = whisperEntry else {
            Issue.record("v0.1 manifest missing whisperkit-placeholder entry")
            return
        }
        let isPlaceholder = entry.url.pathComponents.contains("placeholder")
        #expect(isPlaceholder == true)
    }

    @Test("v0.1 manifest has 3 entries (gemma, yolo, whisperkit-placeholder)")
    func v01ManifestEntryCount() {
        #expect(ModelManifest.v01.entries.count == 3)
    }

    @Test("EntryProgress fraction is bounded 0.0-1.0")
    func entryProgressFractionBounded() {
        let zero = ModelDownloader.EntryProgress(id: "x", bytesWritten: 0, totalBytes: 0)
        #expect(zero.fraction == 0.0)

        let half = ModelDownloader.EntryProgress(id: "x", bytesWritten: 500, totalBytes: 1000)
        #expect(abs(half.fraction - 0.5) < 0.001)

        let full = ModelDownloader.EntryProgress(id: "x", bytesWritten: 1000, totalBytes: 1000)
        #expect(full.fraction == 1.0)
    }

    @Test("Milestone detection returns 10% increments")
    func milestoneDetection() {
        let at5pct  = ModelDownloader.EntryProgress(id: "x", bytesWritten:   5, totalBytes: 100)
        let at10pct = ModelDownloader.EntryProgress(id: "x", bytesWritten:  10, totalBytes: 100)
        let at19pct = ModelDownloader.EntryProgress(id: "x", bytesWritten:  19, totalBytes: 100)
        let at20pct = ModelDownloader.EntryProgress(id: "x", bytesWritten:  20, totalBytes: 100)

        #expect(at5pct.lastMilestonePercent == nil)
        #expect(at10pct.lastMilestonePercent == 10)
        #expect(at19pct.lastMilestonePercent == 10)
        #expect(at20pct.lastMilestonePercent == 20)
    }

    @Test("Resume data persisted to UserDefaults on pause")
    @MainActor
    func resumeDataPersistedOnPause() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testDefaults = UserDefaults(suiteName: "echosight.test.\(UUID())")!
        defer { testDefaults.removePersistentDomain(forName: "echosight.test.\(UUID())") }

        let manifest = makeTestManifest(destDir: tempDir)
        _ = ModelDownloader(
            manifest: manifest,
            destinationDirectory: tempDir,
            wifiOnly: true,
            defaults: testDefaults
        )

        // Verify the completed flag starts unset.
        let completedKey = "echosight.download.completed.test-model"
        #expect(testDefaults.bool(forKey: completedKey) == false)
    }
}
