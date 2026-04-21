import Testing
import Logging
@testable import EchoSightCore

// MARK: - PlaceholderTests

/// Placeholder test suite for EchoSightCore.
///
/// Verifies that the observability bootstrap runs without crashing and that
/// the swift-log system accepts a category under `echosight.app`.
/// Real unit tests for each spec land in their own test files.
@Suite("EchoSightCore Placeholder")
struct PlaceholderTests {

    @Test("ObservabilityBootstrap installs without crash")
    func bootstrapIsIdempotent() {
        // First install
        ObservabilityBootstrap.install()
        // Second install must be a no-op (no crash, no double-bootstrap)
        ObservabilityBootstrap.install()
    }

    @Test("echosight.app logger accepts a log event")
    func appLoggerWorks() {
        ObservabilityBootstrap.install()
        let logger = Logger(label: "echosight.app")
        // Should not crash — just exercises the logging stack.
        logger.info("app.launch", metadata: ["test": "placeholder"])
    }
}
