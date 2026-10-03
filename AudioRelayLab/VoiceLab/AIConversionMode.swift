import Foundation

enum AIConversionMode: String, Codable, CaseIterable, Identifiable {
    case naturalSpeech, preserveProsody, balancedV2, timbrePriority
    var id: String { rawValue }
    var title: String {
        switch self {
        case .naturalSpeech: return "自然说话 · 推荐"
        case .preserveProsody: return "严格保留语调"
        case .balancedV2: return "清晰音色 · V2"
        case .timbrePriority: return "音色优先 · 调校"
        }
    }
    var explanation: String {
        switch self {
        case .naturalSpeech: return "说话专用模型，使用已调校参数；转换音色，尽量保留原话和停顿。"
        case .preserveProsody: return "跟随原声每个字的音高走势，再整体匹配目标音高；适合强调原口气的录音。"
        case .balancedV2: return "V2 只转换音色，优先咬字清晰度；语调仍可能有细微变化。"
        case .timbrePriority: return "V2 采用更高生成步数和目标音色引导；保留原话，语调仍可能微调，优先饱满的目标音色。"
        }
    }
    var isV2: Bool { self == .balancedV2 || self == .timbrePriority }
}
