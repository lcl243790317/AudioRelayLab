import Foundation

enum ExperimentParameterError: LocalizedError {
    case invalidDelay
    case invalidVolume
    case invalidAudioDuration
    case invalidRequestedDuration

    var errorDescription: String? {
        switch self {
        case .invalidDelay: return "延迟必须是 0.1～60 秒之间的有限数值。"
        case .invalidVolume: return "App 内音量必须在 0%～100% 之间。"
        case .invalidAudioDuration: return "音频文件时长无效，无法开始实验。"
        case .invalidRequestedDuration: return "播放时长必须至少 0.1 秒，不超过文件时长或 600 秒；也可以选择播放完整文件。"
        }
    }
}

enum ExperimentParameters {
    static let minimumDelay: Double = 0.1
    static let maximumDelay: Double = 60
    static let minimumRequestedDuration: Double = 0.1
    static let maximumRequestedDuration: Double = 600

    /// nil duration means the complete file. An explicit duration is additionally capped at 600 seconds.
    static func validate(delay: Double, volume: Double, requestedDuration: Double?, audioDuration: Double,
                         startOffset: Double = 0, playbackRate: Float = 1, endOffset: Double? = nil) throws {
        guard delay.isFinite, (minimumDelay...maximumDelay).contains(delay) else {
            throw ExperimentParameterError.invalidDelay
        }
        guard volume.isFinite, (0...1).contains(volume) else {
            throw ExperimentParameterError.invalidVolume
        }
        guard audioDuration.isFinite, audioDuration > 0 else {
            throw ExperimentParameterError.invalidAudioDuration
        }
        let selected = try AudioPlaybackSettings(startOffset:startOffset,playbackRate:playbackRate,volume:Float(volume),endOffset:endOffset).validated(duration:audioDuration)
        if let requestedDuration {
            guard requestedDuration.isFinite,
                  requestedDuration >= minimumRequestedDuration,
                  requestedDuration <= min(selected.remaining(duration:audioDuration), maximumRequestedDuration) else {
                throw ExperimentParameterError.invalidRequestedDuration
            }
        }
    }
}
