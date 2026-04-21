import SwiftUI
import EchoSightCore

// MARK: - DebugConsoleView

/// In-app debug surface for EchoSight.
///
/// Shows the last-N events from each log category in accessible sections.
/// Reachable from Settings. In Release builds, hidden behind a 5-tap-logo gesture
/// (`LogoTapGate`).
///
/// Fully VoiceOver navigable: each section header is labeled, events read as
/// "category — event — duration — outcome".
public struct DebugConsoleView: View {

    // MARK: - State

    @State private var allEvents: [PipelineEvent] = []
    @State private var isLoading = true

    private let buffer: PipelineMetricsBuffer

    // MARK: - Init

    public init(buffer: PipelineMetricsBuffer = .shared) {
        self.buffer = buffer
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading logs…")
                        .accessibilityLabel("Loading debug logs")
                } else if allEvents.isEmpty {
                    Text("No events recorded yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No events recorded")
                } else {
                    eventList
                }
            }
            .navigationTitle("Debug Console")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Export") {
                        Task { await exportLog() }
                    }
                }
            }
        }
        .task { await loadEvents() }
        .task { await streamLiveEvents() }
    }

    // MARK: - Event List

    private var eventList: some View {
        let grouped = Dictionary(grouping: allEvents, by: \.category)
        let sortedKeys = grouped.keys.sorted()

        return List {
            ForEach(sortedKeys, id: \.self) { category in
                DebugConsoleSection(
                    category: category,
                    events: grouped[category] ?? []
                )
            }
        }
    }

    // MARK: - Data

    private func loadEvents() async {
        allEvents = await buffer.recentAll()
        isLoading = false
    }

    private func streamLiveEvents() async {
        let stream = await buffer.liveStream()
        for await event in stream {
            allEvents.append(event)
        }
    }

    private func exportLog() async {
        let exporter = LogExporter(buffer: buffer)
        do {
            let url = try await exporter.export()
            // Present share sheet — requires UIKit interop in visionOS.
            // Simplified for v0.1; full share sheet wired in Phase 3.
            print("Export written to: \(url.path)")
        } catch {
            print("Export failed: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    DebugConsoleView()
}
