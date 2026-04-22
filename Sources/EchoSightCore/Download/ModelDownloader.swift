import Foundation
import Logging

// MARK: - ModelDownloader

/// Background `URLSession` download manager for EchoSight model weights.
///
/// Uses `URLSessionConfiguration.background(withIdentifier:)` so downloads
/// survive app kill + relaunch. Resume data is persisted to `UserDefaults`
/// under a stable key so the download continues from where it left off.
///
/// WiFi-only enforcement: `URLSessionConfiguration.allowsCellularAccess = false`
/// when `wifiOnly == true` (the default).
///
/// Thread safety: `@MainActor` because `URLSessionDownloadDelegate` is called on
/// an arbitrary thread; routing through `@MainActor` serialises state mutations.
/// Progress callbacks are delivered on `@MainActor` to allow direct SwiftUI binding.
///
/// Log category: `echosight.download`
@MainActor
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, ObservableObject, @unchecked Sendable {

    // MARK: - Types

    /// Progress for a single model entry.
    public struct EntryProgress: Sendable {
        public let id: String
        public let bytesWritten: Int64
        public let totalBytes: Int64

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesWritten) / Double(totalBytes)
        }

        /// Returns the last reported 10% milestone crossed, or nil if < 10%.
        public var lastMilestonePercent: Int? {
            let pct = Int(fraction * 100)
            let milestone = (pct / 10) * 10
            return milestone >= 10 ? milestone : nil
        }
    }

    public enum DownloadState: Sendable {
        case idle
        case downloading(progress: [String: EntryProgress])
        case paused
        case verifying
        case completed
        case failed(Error)
    }

    public enum DownloadError: Error, Sendable {
        case shaVerificationFailed(entryId: String)
        case sessionError(Error)
        case noDownloadURL
    }

    // MARK: - Constants

    private enum Keys {
        static let resumeDataPrefix = "echosight.download.resume."
        static let completedPrefix = "echosight.download.completed."
    }

    private static let sessionIdentifier = "com.wesleyshih.EchoSight.backgroundDownload"

    // MARK: - Dependencies

    private let manifest: ModelManifest
    private let destinationDirectory: URL
    private let defaults: UserDefaults
    private let log = Logger(label: "echosight.download")
    private let wifiOnly: Bool

    // MARK: - State

    private var session: URLSession?
    private var activeTasks: [String: URLSessionDownloadTask] = [:]  // entryId → task
    private var progressByEntry: [String: EntryProgress] = [:]
    private var lastMilestoneByEntry: [String: Int] = [:]

    // MARK: - Observable State

    @Published public var state: DownloadState = .idle
    @Published public var overallProgress: Double = 0

    // MARK: - Callbacks

    /// Called at each 10% VoiceOver-announcement milestone.
    public var onProgressMilestone: ((String, Int) -> Void)?

    /// Called when all entries complete + verify.
    public var onAllCompleted: (() -> Void)?

    /// Called when any entry fails.
    public var onFailure: ((Error) -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - manifest: The model manifest describing what to download.
    ///   - destinationDirectory: Where to store downloaded files. Typically Application Support.
    ///   - wifiOnly: If true, disables cellular downloads.
    ///   - defaults: UserDefaults store for resume data.
    public init(
        manifest: ModelManifest = .v01,
        destinationDirectory: URL? = nil,
        wifiOnly: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.manifest = manifest
        self.defaults = defaults
        self.wifiOnly = wifiOnly

        // P1-3 FIX: Application Support directory may be empty in headless test environments.
        // Fall back to temp directory to avoid a force-unwrap crash.
        let appSupportBase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.destinationDirectory = destinationDirectory ?? appSupportBase.appendingPathComponent("EchoSight/Models")

        super.init()
    }

    // MARK: - Public API

    /// Start or resume downloads for all manifest entries.
    ///
    /// Safe to call multiple times — already-completed entries are skipped.
    public func startDownloads() {
        // P1-1 FIX: Fail loud if any non-placeholder entry has a placeholder SHA.
        manifest.assertNonPlaceholderSHAs()
        ensureDirectoryExists()
        let config = makeSessionConfiguration()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        var anyStarted = false
        for entry in manifest.entries {
            // Skip placeholder entries (WhisperKit reserved in v0.1)
            if entry.url.pathComponents.contains("placeholder") {
                log.info("download.entry.skipped", metadata: [
                    "id": .string(entry.id), "reason": "placeholder",
                ])
                continue
            }

            // Skip already-verified entries.
            let completedKey = Keys.completedPrefix + entry.id
            if defaults.bool(forKey: completedKey) {
                let destURL = destinationDirectory.appendingPathComponent(
                    entry.url.lastPathComponent
                )
                let result = ModelVerifier.verify(
                    fileURL: destURL,
                    expectedSHA256: entry.expectedSHA256,
                    deleteOnMismatch: true
                )
                if case .verified = result {
                    log.info("download.entry.alreadyVerified", metadata: ["id": .string(entry.id)])
                    continue
                } else {
                    // File missing or corrupt — clear the completed flag and re-download.
                    defaults.removeObject(forKey: completedKey)
                }
            }

            startOrResumeTask(for: entry, session: session)
            anyStarted = true
        }

        if anyStarted {
            state = .downloading(progress: progressByEntry)
            log.info("download.started", metadata: [
                "targetBytes": .string("\(manifest.totalApproximateBytes)"),
            ])
        } else {
            log.info("download.allAlreadyCompleted")
            finalizeIfAllComplete()
        }
    }

    /// Pause all active downloads, persisting resume data.
    public func pause() {
        for (entryId, task) in activeTasks {
            let resumeKey = Keys.resumeDataPrefix + entryId
            let log = self.log
            task.cancel { [weak self] resumeData in
                guard let data = resumeData else { return }
                // Route back to @MainActor to access defaults safely.
                Task { @MainActor [weak self] in
                    self?.defaults.set(data, forKey: resumeKey)
                    log.info("download.paused", metadata: ["id": .string(entryId)])
                }
            }
        }
        activeTasks.removeAll()
        state = .paused
    }

    // MARK: - Private: Task Management

    private func startOrResumeTask(for entry: ModelManifest.ModelEntry, session: URLSession) {
        let resumeKey = Keys.resumeDataPrefix + entry.id

        if let resumeData = defaults.data(forKey: resumeKey) {
            let task = session.downloadTask(withResumeData: resumeData)
            activeTasks[entry.id] = task
            task.resume()
            defaults.removeObject(forKey: resumeKey)
            log.info("download.resumed", metadata: ["id": .string(entry.id)])
        } else {
            var request = URLRequest(url: entry.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let task = session.downloadTask(with: request)
            activeTasks[entry.id] = task
            task.resume()
            log.info("download.started", metadata: ["id": .string(entry.id)])
        }
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        config.allowsCellularAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return config
    }

    private func ensureDirectoryExists() {
        // P2-DEFERRED: Silently swallows directory-creation errors (full disk, permissions).
        // Should propagate the error so startDownloads() can fail immediately rather than
        // discovering the problem 2 GB later on file move. (P2-2, sprint-3.2)
        try? FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let entryId = self.entryId(for: downloadTask) else { return }

            let progress = EntryProgress(
                id: entryId,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
            self.progressByEntry[entryId] = progress
            self.state = .downloading(progress: self.progressByEntry)
            self.updateOverallProgress()

            // VoiceOver milestone announcements at 10/20/.../100%
            if let milestone = progress.lastMilestonePercent {
                let lastMilestone = self.lastMilestoneByEntry[entryId] ?? -1
                if milestone > lastMilestone {
                    self.lastMilestoneByEntry[entryId] = milestone
                    self.onProgressMilestone?(entryId, milestone)
                    self.log.info("download.progress", metadata: [
                        "id": .string(entryId),
                        "pct": .string("\(milestone)"),
                    ])
                }
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // P0-1 FIX: `location` is valid ONLY for the duration of this synchronous call.
        // Copy the file to a stable temp path NOW, before any Task or async boundary.
        let stableTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("echosight_dl_\(UUID().uuidString).bin")
        do {
            try FileManager.default.copyItem(at: location, to: stableTempURL)
        } catch {
            Task { @MainActor in
                self.log.error("download.tempCopyFailed", metadata: [
                    "error": .string(error.localizedDescription),
                ])
                self.state = .failed(DownloadError.sessionError(error))
                self.onFailure?(error)
            }
            return
        }

        Task { @MainActor in
            guard let entryId = self.entryId(for: downloadTask),
                  let entry = self.manifest.entries.first(where: { $0.id == entryId })
            else {
                try? FileManager.default.removeItem(at: stableTempURL)
                return
            }

            // Move stable temp to final destination.
            let destURL = self.destinationDirectory.appendingPathComponent(
                entry.url.lastPathComponent
            )
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.moveItem(at: stableTempURL, to: destURL)
            } catch {
                try? FileManager.default.removeItem(at: stableTempURL)
                self.log.error("download.moveFailed", metadata: [
                    "id": .string(entryId),
                    "error": .string(error.localizedDescription),
                ])
                self.state = .failed(DownloadError.sessionError(error))
                self.onFailure?(error)
                return
            }

            // P0-2 FIX: SHA-256 verification off @MainActor — avoids 10-30 s UI freeze on 2 GB.
            self.state = .verifying
            let expectedSHA = entry.expectedSHA256
            let result = await Task.detached(priority: .utility) {
                ModelVerifier.verify(fileURL: destURL, expectedSHA256: expectedSHA)
            }.value

            switch result {
            case .verified:
                self.defaults.set(true, forKey: Keys.completedPrefix + entryId)
                self.activeTasks.removeValue(forKey: entryId)
                self.log.info("download.completed", metadata: ["id": .string(entryId)])
                self.finalizeIfAllComplete()
            case .mismatch, .readError:
                let err = DownloadError.shaVerificationFailed(entryId: entryId)
                self.state = .failed(err)
                self.onFailure?(err)
                // Restart the download for this entry
                self.startOrResumeTask(for: entry, session: session)
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            if let nsError = error as NSError?,
               nsError.code == NSURLErrorCancelled,
               let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let entryId = self.entryId(for: task) {
                // Cancelled with resume data — persist for later resume.
                self.defaults.set(resumeData, forKey: Keys.resumeDataPrefix + entryId)
                self.log.info("download.cancelledWithResumeData", metadata: ["id": .string(entryId)])
            } else {
                self.log.error("download.failed", metadata: [
                    "error": .string(error.localizedDescription),
                ])
                self.state = .failed(DownloadError.sessionError(error))
                self.onFailure?(error)
            }
        }
    }

    // MARK: - Private: Helpers

    private func entryId(for task: URLSessionTask) -> String? {
        activeTasks.first(where: { $0.value == task })?.key
    }

    private func updateOverallProgress() {
        let totalExpected = manifest.entries.reduce(0.0) { acc, entry in
            acc + Double(entry.approximateSizeBytes)
        }
        let totalWritten = progressByEntry.values.reduce(0.0) { acc, p in
            acc + Double(p.bytesWritten)
        }
        overallProgress = totalExpected > 0 ? totalWritten / totalExpected : 0
    }

    private func finalizeIfAllComplete() {
        let nonPlaceholderEntries = manifest.entries.filter {
            !$0.url.pathComponents.contains("placeholder")
        }
        let allDone = nonPlaceholderEntries.allSatisfy { entry in
            let completedKey = Keys.completedPrefix + entry.id
            return defaults.bool(forKey: completedKey)
        }
        if allDone {
            state = .completed
            overallProgress = 1.0
            let totalDuration: Double = 0  // Approximate; precise timing requires start timestamp.
            log.info("download.completed", metadata: [
                "totalDurationSec": .string("\(Int(totalDuration))"),
            ])
            onAllCompleted?()
        }
    }
}
