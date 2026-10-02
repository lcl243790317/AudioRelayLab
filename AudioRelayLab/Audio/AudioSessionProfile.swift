import AVFAudio

enum AudioSessionProfile: String, Codable, CaseIterable, Identifiable {
    case mixingPlayback = "A"
    case playback = "B"
    case mixingSpeaker = "C"
    case bluetooth = "D"
    case ambient = "E"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixingPlayback: return "播放 + 混音"
        case .playback: return "普通播放"
        case .mixingSpeaker: return "播放和录音 + 混音 + 扬声器"
        case .bluetooth: return "播放和录音 + 蓝牙实验"
        case .ambient: return "环境音（Ambient）"
        }
    }
    var usesInput: Bool { self == .mixingSpeaker || self == .bluetooth }
    var category: AVAudioSession.Category {
        if usesInput { return .playAndRecord }
        return self == .ambient ? .ambient : .playback
    }
    var options: AVAudioSession.CategoryOptions {
        switch self {
        case .mixingPlayback: return [.mixWithOthers]
        case .mixingSpeaker: return [.mixWithOthers, .defaultToSpeaker]
        case .bluetooth:
            // Xcode 26 起使用 HFP 的明确名称；旧 SDK 保留同等公开选项。
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                return [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
            }
            #endif
            return [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
        case .playback, .ambient: return []
        }
    }
}
