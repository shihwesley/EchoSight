import SwiftUI
import Accessibility

// MARK: - PrivacyDisclosureView

/// Hard gate #1: privacy disclosure before any download begins.
///
/// Users must accept before proceeding. Declining exits the onboarding flow
/// (app remains in onboarding state on next launch).
///
/// VoiceOver-first design:
/// - Heading-level labels on each section for rotor navigation
/// - Accept and Decline buttons are the last two focus targets
/// - Copy reviewed against BLV accessibility guidance
struct PrivacyDisclosureView: View {

    // MARK: - Callbacks

    var onAccept: () -> Void
    var onDecline: () -> Void

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                Text("Privacy & Storage")
                    .font(.extraLargeTitle2)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 8)

                privacySection(
                    heading: "Photos & Captures",
                    body: "Screenshots you trigger go into an album called \"EchoSight Captures\" in your Photos library. You can clear this album anytime from Settings."
                )

                privacySection(
                    heading: "On-Device Only",
                    body: "All scene analysis and object recognition happens entirely on your device. EchoSight makes no network calls after the initial model download. Your spatial data never leaves the headset."
                )

                privacySection(
                    heading: "Storage",
                    body: "The app downloads about 2.6 GB of model files on first launch. These stay on your Vision Pro and are removed when you delete EchoSight."
                )

                Divider()
                    .padding(.vertical, 8)

                HStack(spacing: 16) {
                    Button("Accept and continue") {
                        AccessibilityNotification.Announcement("Privacy accepted. Download starting.")
                            .post()
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Accept privacy terms and continue to download")
                    .accessibilityHint("Opens the model download screen.")

                    Button("Decline") {
                        // HIG P2-FIX: Announce decline so BLV users hear confirmation.
                        AccessibilityNotification.Announcement(
                            "Privacy declined. EchoSight requires acceptance to continue."
                        ).post()
                        onDecline()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Decline")
                    .accessibilityHint("You cannot use EchoSight without accepting these terms.")
                }
                .padding(.top, 8)
            }
            .padding(32)
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func privacySection(heading: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.title3)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
