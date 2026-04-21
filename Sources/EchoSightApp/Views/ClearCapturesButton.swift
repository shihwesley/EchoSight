import SwiftUI
import Photos
import Logging
import EchoSightCore

// MARK: - ClearCapturesButton

/// A button that deletes all assets in the EchoSight Captures album.
///
/// The system's `deleteAssets` always shows a confirmation dialog —
/// there is no way to delete silently. The system dialog is VoiceOver-compatible,
/// so no custom SwiftUI confirmation alert is needed.
///
/// ## Accessibility
/// - `accessibilityLabel`: "Clear Captures"
/// - `accessibilityHint`: describes what happens
/// - Disabled state when album is empty
struct ClearCapturesButton: View {

    // MARK: - Dependencies

    let album: EchoSightAlbum

    // MARK: - State

    @State private var captureCount: Int = 0
    @State private var isClearing = false
    @State private var errorMessage: String?

    private let logger = Logger(label: "echosight.capture")

    // MARK: - Body

    var body: some View {
        Button {
            Task { await clearCaptures() }
        } label: {
            HStack {
                if isClearing {
                    ProgressView()
                        .accessibilityLabel("Clearing captures")
                } else {
                    Label(buttonTitle, systemImage: "trash")
                }
            }
        }
        .disabled(captureCount == 0 || isClearing)
        .accessibilityLabel("Clear Captures")
        .accessibilityHint(accessibilityHint)
        .task { await refreshCount() }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    // MARK: - Helpers

    private var buttonTitle: String {
        if captureCount == 0 {
            return "No Captures"
        }
        return "Clear \(captureCount) Capture\(captureCount == 1 ? "" : "s")"
    }

    private var accessibilityHint: String {
        if captureCount == 0 {
            return "Nothing to clear. The EchoSight Captures album is empty."
        }
        return "Deletes all \(captureCount) captured photo\(captureCount == 1 ? "" : "s") from the EchoSight Captures album. The system will ask you to confirm."
    }

    private func refreshCount() async {
        do {
            captureCount = try await album.assetCount()
        } catch {
            logger.warning("capture.clearCaptures.countFailed — \(error.localizedDescription)")
        }
    }

    private func clearCaptures() async {
        guard captureCount > 0 else {
            // Announce empty state to VoiceOver
            AccessibilityNotification.Announcement("Nothing to clear").post()
            return
        }

        isClearing = true
        defer { isClearing = false }

        do {
            try await album.clearAll()
            await refreshCount()
        } catch {
            // System dialog cancellation throws — treat as user cancellation, not an error
            let nsError = error as NSError
            if nsError.domain == "com.apple.photos" && nsError.code == 3072 {
                // User cancelled the system delete dialog — no-op
                logger.info("capture.clearCaptures.cancelled — user dismissed system dialog")
            } else {
                logger.warning("capture.clearCaptures.error — \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - AlbumCaptureObservingView

/// Convenience wrapper that observes the EchoSight Captures album for changes
/// and posts the first-capture session reminder via AccessibilityNotification.
///
/// Add this view once at a high level in the hierarchy to enable the
/// first-capture accessibility announcement.
struct AlbumCaptureObservingView: View {

    @State private var hasAnnouncedFirstCapture = false

    var body: some View {
        EmptyView()
            .onReceive(
                NotificationCenter.default.publisher(for: PeekABooSource.firstCaptureNotification)
            ) { _ in
                guard !hasAnnouncedFirstCapture else { return }
                hasAnnouncedFirstCapture = true
                AccessibilityNotification.Announcement(
                    "EchoSight capture saved to EchoSight Captures album. You can clear captures from Settings."
                ).post()
            }
    }
}
