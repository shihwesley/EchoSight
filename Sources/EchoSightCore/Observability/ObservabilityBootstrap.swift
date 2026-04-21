import Logging
import Foundation

// MARK: - ObservabilityBootstrap

/// Single-call bootstrap for EchoSight's observability stack.
///
/// `EchoSightApp.init` calls `ObservabilityBootstrap.install()` before any
/// feature code runs. Subsequent calls are no-ops (idempotent). The observability
/// spec (`Sources/EchoSightCore/Observability/`) fills in the full implementation:
/// swift-log multiplex handler (os_log + in-memory ring), PipelineMetricsBuffer,
/// and the DebugConsoleView data source.
///
/// This stub satisfies the project-skeleton build gate. It is replaced by the
/// full implementation when the observability spec lands.
public enum ObservabilityBootstrap {

    // MARK: - State

    // nonisolated(unsafe) is the Swift 6 idiom for mutable statics protected
    // by an explicit lock. The NSLock below is the actual synchronization.
    private nonisolated(unsafe) static let installLock = NSLock()
    private nonisolated(unsafe) static var installed = false

    // MARK: - Public API

    /// Install the observability stack. Safe to call from any thread; idempotent.
    ///
    /// Called by `EchoSightApp.init` before SwiftUI body evaluates.
    public static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else {
            // Observability spec will replace this with a structured warning log.
            return
        }
        installed = true
        bootstrapLogging()
    }

    // MARK: - Private

    private static func bootstrapLogging() {
        // Stub: wire a simple StreamLogHandler to stdout for development.
        // The observability spec replaces this with a multiplex handler
        // (OSLogHandler + PipelineMetricsBuffer in-memory ring).
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
    }
}
