import SwiftUI
import EchoSightCore
import Logging

// MARK: - OnboardingCoordinator

/// Observable object that tracks the onboarding flow state.
///
/// Flow (from eng-review data flow diagram):
///   1. Privacy disclosure (HARD GATE) — must accept to proceed
///   2. Download + SHA verification (HARD GATE) — must complete to proceed
///   3. Tutorial (SOFT — non-gating, skip available as first VO focus)
///   → Enter main app
///
/// Persists completion state to `UserDefaults`. On relaunch after interrupted
/// download, resumes at the download step.
///
/// Log category: `echosight.download`
@MainActor
public final class OnboardingCoordinator: ObservableObject {

    // MARK: - State

    public enum Step: Equatable {
        case privacyDisclosure
        case downloading
        case tutorial
        case completed
    }

    @Published public var step: Step

    // MARK: - Constants

    private enum Keys {
        static let privacyAccepted = "echosight.onboarding.privacyAccepted"
        static let downloadCompleted = "echosight.onboarding.downloadCompleted"
        static let onboardingCompleted = "echosight.onboarding.completed"
    }

    // MARK: - Dependencies

    public let downloader: ModelDownloader
    private let defaults: UserDefaults
    private let log = Logger(label: "echosight.download")

    // MARK: - Init

    public init(downloader: ModelDownloader = ModelDownloader(), defaults: UserDefaults = .standard) {
        self.downloader = downloader
        self.defaults = defaults

        // Restore position in the flow.
        if defaults.bool(forKey: Keys.onboardingCompleted) {
            self.step = .completed
        } else if defaults.bool(forKey: Keys.downloadCompleted) {
            self.step = .tutorial
        } else if defaults.bool(forKey: Keys.privacyAccepted) {
            self.step = .downloading
        } else {
            self.step = .privacyDisclosure
        }
    }

    // MARK: - Actions

    public func acceptPrivacy() {
        defaults.set(true, forKey: Keys.privacyAccepted)
        log.info("privacy.accepted")
        step = .downloading
    }

    public func declinePrivacy() {
        log.info("privacy.declined")
        // Stay at privacy step — user cannot proceed until they accept.
    }

    public func downloadCompleted() {
        defaults.set(true, forKey: Keys.downloadCompleted)
        step = .tutorial
    }

    public func completeTutorial() {
        markOnboardingComplete()
    }

    public func skipTutorial() {
        log.info("tutorial.skipped")
        markOnboardingComplete()
    }

    // MARK: - Private

    private func markOnboardingComplete() {
        defaults.set(true, forKey: Keys.onboardingCompleted)
        log.info("tutorial.completed", metadata: ["durationSec": "0"])
        step = .completed
    }
}

// MARK: - OnboardingFlow

/// SwiftUI view that presents the correct onboarding screen based on coordinator state.
///
/// Plugs into `RootView` via an `.fullScreenCover` or direct view replacement.
public struct OnboardingFlow: View {

    @ObservedObject public var coordinator: OnboardingCoordinator

    public init(coordinator: OnboardingCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        switch coordinator.step {
        case .privacyDisclosure:
            PrivacyDisclosureView(
                onAccept: { coordinator.acceptPrivacy() },
                onDecline: { coordinator.declinePrivacy() }
            )

        case .downloading:
            DownloadProgressView(
                downloader: coordinator.downloader,
                onComplete: { coordinator.downloadCompleted() }
            )

        case .tutorial:
            ModeTutorialView(
                onComplete: { coordinator.completeTutorial() },
                onSkip: { coordinator.skipTutorial() }
            )

        case .completed:
            // Main app — parent handles this transition.
            EmptyView()
        }
    }
}
