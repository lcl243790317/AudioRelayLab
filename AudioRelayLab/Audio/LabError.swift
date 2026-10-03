import Foundation
import AVFAudio

enum LabError: LocalizedError {
    case message(String)
    case audioUnavailable
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .audioUnavailable: return "当前音频环境不允许开始实验。可能存在系统通话或其他高优先级音频会话。结束通话后可以重新尝试。"
        case .invalidFormat: return "当前音频路由或格式不可用。请等待音频环境稳定后重试。"
        }
    }
}

func diagnosticError(_ error: Error) -> String {
    let value = error as NSError
    let status = UInt32(truncatingIfNeeded: value.code)
    let bytes = [UInt8((status >> 24) & 255), UInt8((status >> 16) & 255), UInt8((status >> 8) & 255), UInt8(status & 255)]
    let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? String(bytes: bytes, encoding: .ascii) : nil
    // 不导出 NSError.userInfo 中的私人文件路径、URL 或其他个人资料。
    let rawDescription = value.domain == NSOSStatusErrorDomain || error is LabError ? value.localizedDescription : "操作失败（原始详情不导出，避免包含私人路径）"
    let description = rawDescription.replacingOccurrences(of: #"(?i)(?:file|https?)://\S+|/(?:Users|private|var|tmp|home)/\S+|[A-Z]:[\\/]\S+"#,
        with: "[私人路径已隐藏]", options: .regularExpression)
    return "错误域=\(value.domain)，错误码=\(value.code)\(fourCC.map { "，fourCC=\($0)" } ?? "")，详情=\(description)"
}

func userFacingAudioError(_ error: Error) -> String {
    if let parameter = error as? ExperimentParameterError { return parameter.errorDescription ?? "实验参数无效" }
    if let lab = error as? LabError { return lab.errorDescription ?? "当前音频环境不可用，请稍后重试。" }
    let value = error as NSError
    if value.domain == NSOSStatusErrorDomain {
        let blocked: [AVAudioSession.ErrorCode] = [.cannotInterruptOthers, .insufficientPriority, .cannotStartPlaying, .cannotStartRecording, .resourceNotAvailable]
        if blocked.contains(where: { $0.rawValue == value.code }) { return LabError.audioUnavailable.errorDescription ?? "音频环境不可用" }
    }
    return "音频操作未能完成。请等待当前音频环境稳定后重试；技术详情已写入诊断。"
}
