import EchoSightCore
import SwiftUI

// MARK: - HardwareEventBridge

/// SwiftUI `ViewModifier` that wires spatial input to a `ModalInputCoordinator`.
///
/// Apply via the `hardwareEventBridge(coordinator:)` view extension:
/// ```swift
/// someView.hardwareEventBridge(coordinator: coordinator)
/// ```
///
/// ## Input Mapping (visionOS v0.1)
///
/// visionOS does not expose Digital Crown rotation events to third-party apps via
/// SwiftUI (the Crown controls system volume and other OS-level functions). The
/// physical Capture Button on Apple Vision Pro is also not directly accessible
/// without the `AVCaptureEventInteraction` entitlement (deferred to v1.0).
///
/// v0.1 gesture mapping:
/// - Single tap (`SpatialTapGesture`) → fires current mode (proxies Capture Button)
/// - Double tap (`SpatialTapGesture`, count: 2) → advances to next mode (proxies Crown step)
///
/// This is a pragmatic stand-in. v1.0 will use:
/// - `AVCaptureEventInteraction` for the physical Capture Button
/// - `DigitalCrownRotation` if/when Apple exposes it to visionOS apps
///
/// ## VoiceOver Rotor
/// BLV users who prefer not to use tap gestures can cycle modes via the VoiceOver
/// rotor (standard two-finger rotation gesture). This is the primary BLV input path.
public struct HardwareEventBridgeModifier: ViewModifier {

    // MARK: - Properties

    private let coordinator: ModalInputCoordinator

    // MARK: - Init

    public init(coordinator: ModalInputCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Body

    public func body(content: Content) -> some View {
        content
            // MARK: Single Tap → Fire Current Mode (Capture Button proxy)
            .gesture(
                SpatialTapGesture()
                    .onEnded { _ in
                        Task { await coordinator.buttonPressed() }
                    }
            )
            // MARK: Double Tap → Advance Mode (Crown step proxy)
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { _ in
                        Task { await coordinator.crownRotated(delta: 0.5) }
                    }
            )
            // MARK: VoiceOver Rotor Fallback
            // BLV users cycle modes via VoiceOver rotor (two-finger rotation gesture).
            // Each rotor entry calls setMode directly for deterministic navigation.
            .accessibilityRotor("EchoSight Mode") {
                ForEach(Mode.allCases, id: \.rawValue) { mode in
                    AccessibilityRotorEntry(mode.userLabel, id: mode.rawValue) {
                        Task { await coordinator.setMode(mode) }
                    }
                }
            }
            .accessibilityLabel("EchoSight input surface")
            .accessibilityHint("Double tap to change mode. Tap to activate current mode.")
    }
}

// MARK: - View Extension

public extension View {
    /// Attaches spatial tap gestures (mode fire + mode advance) and VoiceOver rotor
    /// to this view, routing all input through the given `ModalInputCoordinator`.
    func hardwareEventBridge(coordinator: ModalInputCoordinator) -> some View {
        modifier(HardwareEventBridgeModifier(coordinator: coordinator))
    }
}
