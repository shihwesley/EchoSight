import AVFoundation
import Foundation
import Logging

// MARK: - ChimeRenderer

/// Plays a short spatial chime to signal world-anchor novelty.
///
/// Uses `AVAudioEngine` with an `AVAudioEnvironmentNode` to position the sound
/// at 1 m ahead of the user's current head position. The chime is generated
/// programmatically (sine burst) so no audio asset file is required.
///
/// visionOS note: `AVAudioEngine` is the correct cross-platform API for spatial
/// audio rendering without a RealityKit scene. The chime is non-speech, non-critical:
/// if the engine is unavailable (e.g., audio session conflict), the error is logged
/// and playback is skipped — the speech path is the accessibility-critical path.
///
/// Log category: `echosight.ambient`
public actor ChimeRenderer {

    // MARK: - Constants

    private enum Constants {
        static let chimeFrequencyHz: Float = 880.0   // A5 — clear, short, pleasant
        static let chimeDurationSec: Double = 0.35
        static let sampleRate: Double = 44_100.0
        static let chimeGain: Float = 0.4
        static let positionAheadMeters: Float = 1.0
    }

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let environmentNode = AVAudioEnvironmentNode()
    private let playerNode = AVAudioPlayerNode()
    private var isConfigured = false
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Play the spatial chime at 1 m ahead of the user.
    ///
    /// Suspends briefly while the buffer is scheduled (not until playback completes).
    /// Re-entrancy during the suspension window is safe: AmbientAnnounceCoordinator's
    /// 2-second chime gate prevents concurrent calls under normal operation.
    /// Failure is logged, not thrown.
    public func play() async {
        if !isConfigured {
            configure()
        }
        guard isConfigured else { return }

        guard let buffer = makeSineBurst() else {
            log.error("ambient.chime.bufferFailed")
            return
        }

        // Position the sound 1 m ahead (ARKit: -Z is forward).
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        playerNode.position = AVAudio3DPoint(
            x: 0,
            y: 0,
            z: -Constants.positionAheadMeters
        )

        // Suspends until buffer is queued (not until playback ends). Returns well before audio plays.
        await playerNode.scheduleBuffer(buffer)

        if !playerNode.isPlaying {
            playerNode.play()
        }

        log.info("ambient.chime.fired")
    }

    // MARK: - Private: Setup

    private func configure() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            engine.attach(environmentNode)
            engine.attach(playerNode)

            let format = AVAudioFormat(
                standardFormatWithSampleRate: Constants.sampleRate,
                channels: 2
            )!
            engine.connect(playerNode, to: environmentNode, format: format)
            engine.connect(environmentNode, to: engine.mainMixerNode, format: format)

            try engine.start()
            isConfigured = true
            log.info("ambient.chime.engineStarted")
        } catch {
            log.error("ambient.chime.engineFailed", metadata: [
                "error": .string(error.localizedDescription),
            ])
        }
    }

    // MARK: - Private: Buffer Generation

    private func makeSineBurst() -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: Constants.sampleRate,
            channels: 2
        )!
        let frameCount = AVAudioFrameCount(Constants.chimeDurationSec * Constants.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let omega = 2.0 * Float.pi * Constants.chimeFrequencyHz / Float(Constants.sampleRate)
        let frames = Int(frameCount)

        for ch in 0..<Int(format.channelCount) {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            for frame in 0..<frames {
                // Sine with linear attack (10%) and release (30%) envelope
                let t = Float(frame)
                let total = Float(frames)
                let envelope: Float
                let attackFrames = total * 0.10
                let releaseStart = total * 0.70
                if t < attackFrames {
                    envelope = t / attackFrames
                } else if t > releaseStart {
                    envelope = 1.0 - (t - releaseStart) / (total - releaseStart)
                } else {
                    envelope = 1.0
                }
                channelData[frame] = sinf(omega * t) * Constants.chimeGain * envelope
            }
        }
        return buffer
    }
}
