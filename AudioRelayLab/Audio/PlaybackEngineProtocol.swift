import Foundation

enum PlaybackEngineKind: String, Codable, CaseIterable, Identifiable {
    case audioPlayer = "AVAudioPlayer"
    case audioEngine = "AVAudioEngine"
    var id: String { rawValue }
}

enum PlaybackState: String, Codable {
    case idle, prepared, waiting, playing, interrupted, completed, stopped, failed
    var title: String {
        switch self {
        case .idle: return "尚未开始"
        case .prepared: return "已准备"
        case .waiting: return "等待播放"
        case .playing: return "正在播放（已观察到时间线推进）"
        case .interrupted: return "已被中断"
        case .completed: return "播放完成"
        case .stopped: return "已停止"
        case .failed: return "播放失败"
        }
    }
    var canInterrupt: Bool { self == .waiting || self == .playing || self == .prepared }
}

struct PlaybackSchedule: Codable {
    let requestedTime: Date
    let scheduleCallTime: Date
    let requestedDelay: TimeInterval
    let targetUptime: TimeInterval
    let audioClock: String
    let scheduledAudioTime: String
    let accepted: Bool
}

@MainActor protocol PlaybackEngineProtocol: AnyObject {
    var kind: PlaybackEngineKind { get }
    var state: PlaybackState { get }
    var volume: Float { get set }
    var diagnosticState: String { get }
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    func prepare(url: URL, voiceOptimized: Bool) throws
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule
    func observe()
    func stop()
    func interruptionBegan()
    func resumeIfPossible() throws -> Bool
    func mediaServicesLost()
}
