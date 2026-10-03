import AVFAudio

struct AudioPlaybackSettings: Codable, Equatable {
    var startOffset: TimeInterval = 0
    var playbackRate: Float = 1
    var volume: Float = 0.5
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    func validated(duration: TimeInterval) throws -> Self {
        guard duration.isFinite, duration > 0, startOffset.isFinite, startOffset >= 0, startOffset < duration,
            playbackRate.isFinite, (0.5...2).contains(playbackRate), volume.isFinite, (0...1).contains(volume) else {
            throw LabError.message("开始位置必须在音频结束之前，速度为 0.5～2x，音量为 0%～100%。")
        }
        return self
    }
    func remaining(duration: Double) -> Double { max(0, duration - startOffset) }
    func estimatedDuration(duration: Double, sourceLimit: Double? = nil) -> Double {
        guard duration.isFinite, startOffset.isFinite, playbackRate.isFinite, playbackRate > 0 else { return 0 }
        return min(remaining(duration: duration), sourceLimit ?? .infinity) / Double(playbackRate)
    }
    static func clamp(_ offset: Double, duration: Double) -> Double {
        guard offset.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(duration, max(0, offset))
    }
    static func frame(_ offset: Double, sampleRate: Double, length: AVAudioFramePosition) throws -> AVAudioFramePosition {
        guard offset.isFinite, offset >= 0, sampleRate.isFinite, sampleRate > 0, length > 0,
            offset * sampleRate < Double(length) else { throw LabError.invalidFormat }
        return AVAudioFramePosition((offset * sampleRate).rounded(.down))
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--.-" }
        let bounded = min(seconds, 86_400_000)
        return String(format: "%02d:%04.1f", Int(bounded / 60), bounded.truncatingRemainder(dividingBy: 60))
    }
}
