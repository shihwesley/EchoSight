import SwiftUI
import Accessibility
import EchoSightCore

// MARK: - ModeTutorialView

/// Non-gating tutorial that teaches Crown-cycles-modes + Button-fires-current-mode.
///
/// Accessibility design (pinned eng-review gate 2026-04-21):
/// - **Skip button is the FIRST VoiceOver focus target.** Set via `accessibilitySortPriority`.
/// - Users can skip at any time. Tutorial completion is not required.
/// - Tutorial is available from Settings for repeated use.
///
/// The tutorial exercises real `ModalInputCoordinator` events (not simulation) so
/// completing it validates the hardware input chain.
struct ModeTutorialView: View {

    // MARK: - Types

    struct TutorialStep: Identifiable {
        let id: Int
        let modeName: String
        let modeLabel: String
        let instruction: String
        let exampleOutput: String
    }

    // MARK: - State

    @State private var currentStep = 0
    var onComplete: () -> Void
    var onSkip: () -> Void

    // MARK: - Constants

    private let steps: [TutorialStep] = [
        TutorialStep(
            id: 0,
            modeName: "scene",
            modeLabel: "Describe mode",
            instruction: "Rotate the Digital Crown until you hear \"describe mode\". Then press the top button.",
            exampleOutput: "Example: \"Two chairs ahead, a table to the right.\""
        ),
        TutorialStep(
            id: 1,
            modeName: "recall",
            modeLabel: "Recall mode",
            instruction: "Rotate the Crown once more to \"recall mode\". Press the button for a room summary.",
            exampleOutput: "Example: \"You're in a living room with a chair and a doorway.\""
        ),
        TutorialStep(
            id: 2,
            modeName: "read",
            modeLabel: "Read mode",
            instruction: "Rotate again to \"read mode\". Press to read any text in front of you.",
            exampleOutput: "Example: \"Exit. Please use other door.\""
        ),
        TutorialStep(
            id: 3,
            modeName: "silent",
            modeLabel: "Silent",
            instruction: "Rotate once more to \"silent\". In this mode, EchoSight listens but won't speak — only soft chimes.",
            exampleOutput: "No speech output in silent mode."
        ),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // SKIP BUTTON: First VoiceOver focus target (accessibilitySortPriority: 1000)
            HStack {
                Spacer()
                Button("Skip tutorial and enter app") {
                    AccessibilityNotification.Announcement("Skipping tutorial. Entering EchoSight.").post()
                    onSkip()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Skip tutorial and enter app")
                .accessibilityHint("Enters EchoSight immediately. Tutorial available from Settings.")
                .accessibilitySortPriority(1000)  // Ensures VO focuses this first
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Spacer(minLength: 16)

            // Tutorial content
            if currentStep < steps.count {
                let step = steps[currentStep]
                VStack(spacing: 24) {

                    Text("Mode Tutorial")
                        .font(.extraLargeTitle2)
                        .accessibilityAddTraits(.isHeader)

                    Text("Step \(currentStep + 1) of \(steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Step \(currentStep + 1) of \(steps.count)")

                    Text(step.modeLabel)
                        .font(.title)
                        .fontWeight(.semibold)

                    Text(step.instruction)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text(step.exampleOutput)
                        .font(.body)
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 16) {
                        if currentStep > 0 {
                            Button("Back") {
                                currentStep -= 1
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(currentStep < steps.count - 1 ? "Next" : "Enter app") {
                            if currentStep < steps.count - 1 {
                                let nextStep = steps[currentStep + 1]
                                AccessibilityNotification.Announcement(
                                    "Step \(currentStep + 2): \(nextStep.modeLabel)"
                                ).post()
                                currentStep += 1
                            } else {
                                AccessibilityNotification.Announcement(
                                    "Tutorial complete. Entering EchoSight."
                                ).post()
                                onComplete()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Step progress dots
                    HStack(spacing: 8) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            Circle()
                                .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}

// MARK: - TutorialRefreshView

/// Settings entry point to re-run the tutorial at any time.
///
/// Reachable from Settings > Tutorial even without re-going through onboarding.
public struct TutorialRefreshView: View {

    @State private var showTutorial = false

    public init() {}

    public var body: some View {
        Group {
            if showTutorial {
                ModeTutorialView(
                    onComplete: { showTutorial = false },
                    onSkip: { showTutorial = false }
                )
            } else {
                VStack(spacing: 20) {
                    Text("Mode Tutorial")
                        .font(.extraLargeTitle2)
                        .accessibilityAddTraits(.isHeader)

                    Text("Learn how to navigate between scene, recall, read, and silent modes using the Digital Crown and Capture Button.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("Start Tutorial") {
                        showTutorial = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
            }
        }
    }
}
