import AVFoundation
import Foundation

internal final class GraphAudio {
    internal enum SoundKind {
        case hover
        case snip
        case archive
        case water
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var isWarm = false

    @MainActor
    internal func warm() {
        guard !isWarm else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
        player.play()
        isWarm = true
    }

    @MainActor
    internal func play(_ kind: SoundKind, settings: GraphCanvasSettings) {
        guard settings.soundOn, isSystemUISoundEnabled else { return }
        warm()
        guard let buffer = makeBuffer(for: ToneEnvelope(kind: kind)) else { return }
        player.scheduleBuffer(buffer, at: nil)
    }

    private var isSystemUISoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    private func makeBuffer(for envelope: ToneEnvelope) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(envelope.duration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let progress = Double(frame) / Double(frameCount)
            let gain = envelope.gain * Float(1 - progress)
            let sample = sin(2 * .pi * envelope.frequency * Double(frame) / format.sampleRate)
            channel[frame] = Float(sample) * gain
        }
        return buffer
    }
}

private struct ToneEnvelope {
    let frequency: Double
    let gain: Float
    let duration: Double
    init(kind: GraphAudio.SoundKind) {
        switch kind {
        case .hover:
            frequency = 660
            gain = 0.045
            duration = 0.055
        case .snip:
            frequency = 220
            gain = 0.08
            duration = 0.18
        case .archive:
            frequency = 330
            gain = 0.055
            duration = 0.14
        case .water:
            frequency = 520
            gain = 0.065
            duration = 0.22
        }
    }
}
