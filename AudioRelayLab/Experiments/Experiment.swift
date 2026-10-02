import Foundation

enum ExperimentResult: String, Codable, CaseIterable, Identifiable {
    case captured, playbackStopped, notCaptured, quieter, wechatInterrupted, uncertain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captured: return "音频成功进入微信语音"
        case .playbackStopped: return "播放被停止"
        case .notCaptured: return "播放继续但微信没有录进去"
        case .quieter: return "播放音量明显降低"
        case .wechatInterrupted: return "微信录音被中断"
        case .uncertain: return "不确定"
        }
    }
}

struct ExperimentSettings: Codable {
    let engine: PlaybackEngineKind
    let profile: AudioSessionProfile
    let delay: Double
    let volume: Float
    let voiceOptimized: Bool
    let speakerOverride: Bool
}

struct Experiment: Codable, Identifiable {
    let id: UUID
    let date: Date
    let device: DeviceInfo
    let audio: AudioFileMetadata
    let settings: ExperimentSettings
    var schedule: PlaybackSchedule?
    var finalState: PlaybackState
    var result: ExperimentResult
    var resultReviewed: Bool
    var notes: String
    var finishedAt: Date?
    var logs: [DiagnosticEntry]
}
