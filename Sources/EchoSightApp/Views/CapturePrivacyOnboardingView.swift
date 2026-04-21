import SwiftUI
import PeekABoo

// MARK: - CapturePrivacyOnboardingView

/// Shown before the first capture to explain the screenshot capture model
/// and request Full Photo Library access.
///
/// ## Accessibility
/// All interactive elements carry explicit `accessibilityLabel` and `accessibilityHint`
/// values. Text uses system font styles (Dynamic Type compatible).
///
/// ## Flow
/// - Granted: calls `onAccessGranted()`
/// - Denied: shows Settings deep-link
/// - Already denied on entry: shows Settings path immediately
struct CapturePrivacyOnboardingView: View {

    // MARK: - State

    @State private var isRequesting = false
    @State private var accessDenied = false

    // MARK: - Callbacks

    var onAccessGranted: () -> Void
    var onDismissed: (() -> Void)?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                explanation
                albumNote
                actionButtons
            }
            .padding(32)
        }
        .task {
            // If already denied on entry, skip the prompt and show settings path
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .denied || status == .restricted {
                accessDenied = true
            } else if status == .authorized {
                onAccessGranted()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EchoSight needs Photos access")
                .font(.title)
                .accessibilityAddTraits(.isHeader)

            Text("EchoSight captures your view using the Vision Pro screenshot system.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How it works", systemImage: "camera.viewfinder")
                .font(.headline)

            Text("When you press Digital Crown + Capture Button, the system saves a screenshot of what you're seeing. EchoSight reads that screenshot to identify objects and text.")
                .font(.body)

            Text("Full Photos access is required. \"Limited\" access won't work because EchoSight needs to monitor the screenshot album in real time.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var albumNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your photo library", systemImage: "photo.on.rectangle")
                .font(.headline)

            Text("Screenshots are saved to a dedicated \"EchoSight Captures\" album in your Photos app. You can delete them any time from Settings in EchoSight, or directly from Photos.")
                .font(.body)

            Text("These screenshots will appear in your Photos app. EchoSight does not share or upload them anywhere — all processing happens on this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if accessDenied {
            deniedState
        } else {
            grantButton
        }
    }

    private var grantButton: some View {
        Button {
            Task {
                isRequesting = true
                let granted = await PeekABoo.requestAccess()
                isRequesting = false
                if granted {
                    onAccessGranted()
                } else {
                    accessDenied = true
                }
            }
        } label: {
            HStack {
                if isRequesting {
                    ProgressView()
                        .accessibilityLabel("Requesting access")
                }
                Text(isRequesting ? "Requesting…" : "Grant Full Access")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRequesting)
        .accessibilityLabel("Grant Full Photos Access")
        .accessibilityHint("Opens the system permission dialog. Choose \"Allow Full Access\" to enable capture.")
    }

    private var deniedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos access was denied.")
                .font(.body)
                .foregroundStyle(.red)

            Text("To enable capture, go to Settings → Privacy & Security → Photos → EchoSight and choose \"Full Access\".")
                .font(.body)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Open Settings")
            .accessibilityHint("Opens the iOS Settings app where you can grant Photos access to EchoSight.")

            if let onDismissed {
                Button("Not now", action: onDismissed)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                    .accessibilityHint("Skip Photos access for now. Capture will not work until access is granted.")
            }
        }
    }
}
