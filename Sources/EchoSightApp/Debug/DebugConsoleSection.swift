import SwiftUI
import EchoSightCore

// MARK: - DebugConsoleSection

/// A collapsible section in `DebugConsoleView` for one log category.
struct DebugConsoleSection: View {

    let category: String
    let events: [PipelineEvent]

    @State private var isExpanded = true

    var body: some View {
        Section(isExpanded: $isExpanded) {
            if events.isEmpty {
                Text("No events")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(category): no events")
            } else {
                ForEach(events.indices, id: \.self) { index in
                    let event = events[events.count - 1 - index] // newest first
                    EventRow(event: event)
                }
            }
        } header: {
            Text(category)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Category: \(category), \(events.count) events")
        }
    }
}

// MARK: - EventRow

private struct EventRow: View {

    let event: PipelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.event)
                .font(.caption.monospaced())

            HStack(spacing: 8) {
                if let dur = event.durationMs {
                    Text(String(format: "%.1fms", dur))
                        .foregroundStyle(.secondary)
                }
                Text(outcomeLabel)
                    .foregroundStyle(outcomeColor)
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var outcomeLabel: String {
        switch event.outcome {
        case .ok: "ok"
        case .degraded(let r): "degraded: \(r)"
        case .cancelled: "cancelled"
        case .failed(let r): "failed: \(r)"
        case .dropped(let r): "dropped: \(r)"
        }
    }

    private var outcomeColor: Color {
        switch event.outcome {
        case .ok: .green
        case .degraded: .orange
        case .cancelled: .secondary
        case .failed: .red
        case .dropped: .yellow
        }
    }

    private var accessibilityDescription: String {
        var parts = [event.event, outcomeLabel]
        if let dur = event.durationMs {
            parts.append(String(format: "%.0f milliseconds", dur))
        }
        return parts.joined(separator: ", ")
    }
}
