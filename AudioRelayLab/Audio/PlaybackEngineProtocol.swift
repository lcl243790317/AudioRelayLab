import Foundation

enum PlaybackEngineKind: String, Codable, CaseIterable, Identifiable {
    case audioPlayer = "AVAudioPlayer"
    case audioEngine = "AVAudioEngine"
    case unknown = "unknown"
    var id: String { rawValue }
    static var selectableCases: [Self] { [.audioPlayer, .audioEngine] }
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "unknown") ?? .unknown
    }
}

enum PlaybackState: String, Codable {
    case idle, preparing, prepared, waiting, playing, interrupted, completed, stopped, failed, cancelled
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "failed") ?? .failed
    }
    var title: String {
        switch self {
        case .idle: return "未准备"
        case .preparing: return "准备中"
        case .prepared: return "已准备"
        case .waiting: return "等待播放"
        case .playing: return "正在播放（已观察到时间线推进）"
        case .interrupted: return "已被中断"
        case .completed: return "播放完成"
        case .stopped: return "已停止"
        case .failed: return "实验失败"
        case .cancelled: return "已取消"
        }
    }
    var canInterrupt: Bool { self == .waiting || self == .playing || self == .prepared || self == .preparing }
}

struct PlaybackSchedule: Codable {
    let requestedTime: Date
    let scheduleCallTime: Date
    let requestedDelay: TimeInterval
    let targetUptime: TimeInterval
    let audioClock: String
    let scheduledAudioTime: String
    let accepted: Bool
    var requestedDuration: TimeInterval? = nil
    var startOffset: TimeInterval = 0
    var playbackRate: Float = 1
    var endOffset: TimeInterval? = nil
    enum CodingKeys: String, CodingKey {
        case requestedTime, scheduleCallTime, requestedDelay, targetUptime, audioClock, scheduledAudioTime, accepted, requestedDuration, startOffset, playbackRate, endOffset
    }
}

extension PlaybackSchedule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedTime = (try? c.decode(Date.self, forKey: .requestedTime)) ?? .distantPast
        scheduleCallTime = (try? c.decode(Date.self, forKey: .scheduleCallTime)) ?? requestedTime
        requestedDelay = (try? c.decode(Double.self, forKey: .requestedDelay)) ?? 0
        targetUptime = (try? c.decode(Double.self, forKey: .targetUptime)) ?? 0
        audioClock = (try? c.decode(String.self, forKey: .audioClock)) ?? "旧记录未提供"
        scheduledAudioTime = (try? c.decode(String.self, forKey: .scheduledAudioTime)) ?? "未知"
        accepted = (try? c.decode(Bool.self, forKey: .accepted)) ?? false
        requestedDuration = try? c.decode(Double.self, forKey: .requestedDuration)
        startOffset = (try? c.decode(Double.self, forKey: .startOffset)) ?? 0
        playbackRate = (try? c.decode(Float.self, forKey: .playbackRate)) ?? 1
        endOffset = try? c.decode(Double.self,forKey:.endOffset)
    }
}

@MainActor protocol PlaybackEngineProtocol: AnyObject {
    var kind: PlaybackEngineKind { get }
    var state: PlaybackState { get }
    var volume: Float { get set }
    var diagnosticState: String { get }
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    func prepare(url: URL, voiceOptimized: Bool, requestedDuration: TimeInterval?, startOffset: TimeInterval, playbackRate: Float, endOffset: TimeInterval?) async throws
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule
    func observe()
    func stop()
    func interruptionBegan()
    func resumeIfPossible() throws -> Bool
    func mediaServicesLost()
    func teardown()
}

extension PlaybackEngineProtocol {
    func prepare(url: URL, voiceOptimized: Bool, requestedDuration: TimeInterval?, startOffset: TimeInterval = 0, playbackRate: Float = 1) async throws {
        try await prepare(url:url,voiceOptimized:voiceOptimized,requestedDuration:requestedDuration,startOffset:startOffset,playbackRate:playbackRate,endOffset:nil)
    }
}
