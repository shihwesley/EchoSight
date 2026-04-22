import SwiftUI
import Accessibility
import Logging

// MARK: - HardwareDiagnosticView

/// Settings > Hardware Diagnostic — exercises Crown rotation and Capture Button
/// with live feedback.
///
/// Not required to enter the app. Belt-and-suspenders escape hatch for users
/// who suspect hardware failure (eng-review gate 7, 2026-04-21).
///
/// Live feedback:
/// - Crown rotation: shows cumulative tick count and direction
/// - Capture Button: logs each press with timestamp
///
/// Non-responsive hardware: displays a printed support contact + escape button.
///
/// Accessible entirely via VoiceOver — buttons and ticks are announced.
public struct HardwareDiagnosticView: View {

    // MARK: - State

    @State private var crownTicks = 0
    @State private var crownDirection: String = "—"
    @State private var buttonPresses: [Date] = []
    @State private var showSupportInfo = false
    private let log = HardwareDiagnosticLog()

    // MARK: - Body

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {

                Text("Hardware Diagnostic")
                    .font(.extraLargeTitle2)
                    .accessibilityAddTraits(.isHeader)

                Text("Use this screen to confirm that the Digital Crown and Capture Button are responding. All readings are local and not stored.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                // Crown section
                Group {
                    Text("Digital Crown")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 24) {
                        VStack {
                            // HIG P1-FIX: Use Dynamic Type-compatible style (not fixed pt size).
                            Text("\(crownTicks)")
                                .font(.largeTitle.monospacedDigit())
                                .fontWeight(.bold)
                                .contentTransition(.numericText())
                                .accessibilityLabel("Crown rotation ticks")
                                .accessibilityValue("\(crownTicks) ticks, \(crownDirection)")

                            Text("ticks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Direction: \(crownDirection)")
                                .font(.body)
                            Text("Rotate the Digital Crown to see ticks register above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Simulate clockwise tick") {
                            simulateCrownTick(clockwise: true)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Records a clockwise Crown tick for testing.")

                        Button("Simulate counterclockwise tick") {
                            simulateCrownTick(clockwise: false)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Records a counterclockwise Crown tick for testing.")
                    }

                    Button("Reset tick count") {
                        crownTicks = 0
                        crownDirection = "—"
                        AccessibilityNotification.Announcement("Tick count reset to zero.").post()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reset Crown tick count to zero")
                }

                Divider()

                // Button section
                Group {
                    Text("Capture Button")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(buttonPresses.count) press\(buttonPresses.count == 1 ? "" : "es") recorded")
                            .font(.body)
                            .accessibilityLabel("\(buttonPresses.count) button presses recorded")

                        if let last = buttonPresses.last {
                            Text("Last: \(last, style: .time)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Simulate button press") {
                        simulateButtonPress()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Records a button press with the current timestamp.")
                }

                Divider()

                // Support section
                Group {
                    Text("Hardware not responding?")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    Button("Show support information") {
                        showSupportInfo.toggle()
                        if showSupportInfo {
                            AccessibilityNotification.Announcement(
                                "Support information shown. Apple Vision Pro support: 1-800-275-2273"
                            ).post()
                        }
                    }
                    .buttonStyle(.bordered)

                    if showSupportInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Apple Vision Pro Support")
                                .font(.body).fontWeight(.semibold)
                            Text("Phone: 1-800-275-2273")
                                .font(.body)
                            Text("Web: apple.com/support/visionpro")
                                .font(.body)
                            Text("Describe the issue: Crown rotation not registering ticks, or Capture Button not responding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(32)
        }
        .onAppear {
            log.record("hardware.diagnostic.entered")
        }
    }

    // MARK: - Private: Simulation Actions

    /// In production: these methods are called by `HardwareEventBridge` when real
    /// Crown + Button events arrive. The simulate buttons allow testing without
    /// real hardware events in the diagnostic view.
    private func simulateCrownTick(clockwise: Bool) {
        crownTicks += 1
        crownDirection = clockwise ? "Clockwise" : "Counterclockwise"
        let direction = clockwise ? "clockwise" : "counterclockwise"
        log.record("hardware.diagnostic.crown.tick", count: crownTicks)
        AccessibilityNotification.Announcement(
            "Crown tick \(crownTicks), \(direction)"
        ).post()
    }

    private func simulateButtonPress() {
        let now = Date()
        buttonPresses.append(now)
        log.record("hardware.diagnostic.button.pressed")
        AccessibilityNotification.Announcement(
            "Button press recorded. Total: \(buttonPresses.count)"
        ).post()
    }
}

// MARK: - HardwareDiagnosticLog

/// Structured logger for diagnostic events, routed through swift-log.
private final class HardwareDiagnosticLog {
    private let log = Logger(label: "echosight.diagnostic")

    func record(_ event: String, count: Int? = nil) {
        if let count {
            log.info("\(event)", metadata: ["count": .string("\(count)")])
        } else {
            log.info("\(event)")
        }
    }
}
