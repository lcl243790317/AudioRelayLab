import AVFAudio

enum AudioSessionProfile: String, Codable, CaseIterable, Identifiable {
    case mixingPlayback = "A"
    case playback = "B"
    case mixingSpeaker = "C"
    case bluetooth = "D"
    case ambient = "E"
    case unknown

    /// B 和未知值仅供旧记录读取，不能作为新的会话配置。
    static let selectableCases: [AudioSessionProfile] = [.mixingPlayback, .mixingSpeaker, .bluetooth, .ambient]
    var isSelectable: Bool { Self.selectableCases.contains(self) }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self = Self(rawValue: (try? value.decode(String.self)) ?? "") ?? .unknown
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixingPlayback: return "播放 + 混音"
        case .playback: return "B（旧版普通播放，已停用）"
        case .mixingSpeaker: return "播放和录音 + 混音 + 默认扬声器"
        case .bluetooth: return "播放和录音 + 混音 + 蓝牙 HFP"
        case .ambient: return "Ambient"
        case .unknown: return "未知旧版配置（不可新建）"
        }
    }
    var historyTitle: String {
        isSelectable ? "\(rawValue) · \(title)" : title
    }
    var shortDescription: String {
        switch self {
        case .mixingPlayback: return "适合普通播放与其他音频混音实验。"
        case .mixingSpeaker: return "启用输入会话并默认扬声器；通话占用时可能无法激活。"
        case .bluetooth: return "允许蓝牙 HFP；实际路由由系统和连接设备决定。"
        case .ambient: return "环境音配置，受静音和系统音频环境影响。"
        case .playback: return "旧版非混音配置，仅供历史查看。"
        case .unknown: return "此配置来自其他版本，仅供历史查看。"
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
            return [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
            #else
            return [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            #endif
        case .playback, .ambient, .unknown: return []
        }
    }
}
