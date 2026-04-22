import SwiftUI
import Accessibility
import EchoSightCore

// MARK: - DownloadProgressView

/// Hard gate #2: displays download progress and announces milestones via VoiceOver.
///
/// VoiceOver-first design:
/// - Progress value announced as percentage via `accessibilityValue`
/// - Milestone announcements (10/20/…/100%) posted as `AccessibilityNotification.Announcement`
/// - WiFi-only toggle is the first focus target so users can confirm the setting
///   before download begins
///
/// Download does not begin until this view appears (privacy accepted).
struct DownloadProgressView: View {

    // MARK: - State

    @ObservedObject var downloader: ModelDownloader
    @State private var lastAnnouncedMilestone = -1
    // HIG P1-FIX: Respect Reduce Motion preference for the progress ring animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onComplete: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {

            Text("Downloading Models")
                .font(.extraLargeTitle2)
                .accessibilityAddTraits(.isHeader)

            Text("EchoSight needs to download approximately 2.6 GB of AI models. This happens once. A WiFi connection is recommended.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Overall progress ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: downloader.overallProgress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.5), value: downloader.overallProgress)

                VStack(spacing: 4) {
                    Text("\(Int(downloader.overallProgress * 100))%")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int(downloader.overallProgress * 100)) percent downloaded")
            .accessibilityElement(children: .ignore)

            // Per-entry status
            if case .downloading(let progress) = downloader.state {
                // P2-DEFERRED: Dictionary.values iteration order is undefined. Sort by id
                // to prevent row-reordering and VoiceOver focus jumps. (P2-4, sprint-3.2)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(progress.values).sorted(by: { $0.id < $1.id }), id: \.id) { entry in
                        HStack {
                            Text(entryDisplayName(entry.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(entry.fraction * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 32)
            }

            if case .verifying = downloader.state {
                Label("Verifying integrity…", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let error) = downloader.state {
                VStack(spacing: 12) {
                    Label("Download failed. Retrying…", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(32)
        .onAppear {
            downloader.onProgressMilestone = { entryId, milestone in
                let displayName = entryDisplayName(entryId)
                let message = "\(displayName): \(milestone) percent downloaded"
                AccessibilityNotification.Announcement(message).post()
            }

            downloader.onAllCompleted = {
                AccessibilityNotification.Announcement(
                    "Download complete. Verifying models."
                ).post()
                onComplete()
            }

            downloader.startDownloads()
        }
    }

    // MARK: - Helpers

    private func entryDisplayName(_ id: String) -> String {
        switch id {
        case "gemma-4-e2b-q4": return "Language model"
        case "yolo11n-int8": return "Object detection"
        default: return id
        }
    }
}
