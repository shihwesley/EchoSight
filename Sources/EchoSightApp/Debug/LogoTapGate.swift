import SwiftUI

// MARK: - LogoTapGate

/// 5-tap gesture modifier that reveals `DebugConsoleView` in Release builds.
///
/// In DEBUG builds, the console is always accessible from Settings.
/// In Release builds, tap the app logo 5 times within 2 seconds to unlock.
/// This is the standard iOS debug-surface pattern used across Apple's own apps.
struct LogoTapGate: ViewModifier {

    @State private var tapCount = 0
    @State private var tapTimer: Timer?
    @State private var isDebugUnlocked: Bool

    init() {
        #if DEBUG
        self._isDebugUnlocked = State(initialValue: true)
        #else
        self._isDebugUnlocked = State(initialValue: false)
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 1) {
                handleTap()
            }
            .sheet(isPresented: $isDebugUnlocked) {
                DebugConsoleView()
            }
    }

    private func handleTap() {
        #if DEBUG
        isDebugUnlocked = true
        return
        #else
        tapTimer?.invalidate()
        tapCount += 1
        if tapCount >= 5 {
            isDebugUnlocked = true
            tapCount = 0
        } else {
            tapTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                tapCount = 0
            }
        }
        #endif
    }
}

extension View {
    /// Attach the 5-tap debug unlock gesture to this view.
    func logoTapDebugGate() -> some View {
        modifier(LogoTapGate())
    }
}
