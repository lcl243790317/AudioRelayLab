import Foundation

enum RevoiceJobFailureKind:String,Codable,Sendable {
    case busy, network, authentication, configuration, expired, generation, validation, localSave, parameters
    var message:String {
        switch self {
        case .busy: return "云端忙碌或限流；稍后在最近任务中重试同一任务，或完成旧任务取回后再生成"
        case .network: return "网络暂不可用，任务编号已保留；恢复网络后继续取回同一任务"
        case .authentication: return "认证失败；打开云端连接设置修复配置，再继续取回"
        case .configuration: return "连接配置与这份任务不匹配；可导入原配置继续取回，或停止等待。已有下载凭据的任务可直接取回"
        case .expired: return "任务已超过 24 小时取回窗口；草稿仍在，可手动生成新配音"
        case .generation: return "云端生成失败；草稿仍在，请检查参数后手动生成新配音"
        case .validation: return "下载来源或 WAV／哈希／时长校验失败，未保存半成品；可重新取回同一任务"
        case .localSave: return "本地保存失败；请检查可用空间，随后继续取回同一任务"
        case .parameters: return "云端拒绝了配音参数；请检查文字与表达指令后手动生成新配音"
        }
    }
    var canRetry:Bool { ![.expired,.generation,.parameters].contains(self) }
    static func classify(_ error:Error) -> Self {
        if let error = error as? RevoiceServiceError { return error.kind }
        if let error = error as? URLError {
            switch error.code {
            case .badServerResponse,.dataLengthExceedsMaximum,.httpTooManyRedirects,.redirectToNonExistentLocation: return .validation
            case .badURL,.unsupportedURL: return .configuration
            case .userAuthenticationRequired,.userCancelledAuthentication: return .authentication
            default: return .network
            }
        }
        if let error = error as? RevoiceTransferError {
            if error.failure.domain == NSURLErrorDomain,let code = URLError.Code(rawValue:error.failure.code) {
                return classify(URLError(code))
            }
            return .localSave
        }
        let value = error as NSError
        if [NSCocoaErrorDomain,NSPOSIXErrorDomain].contains(value.domain) { return .localSave }
        if error is DecodingError { return .configuration }
        return .configuration
    }
}

struct RevoiceServiceError:Error {
    let kind:RevoiceJobFailureKind
    var notAccepted = false
}

extension PendingRevoiceJob {
    var blocksNewSubmission:Bool {
        guard expiresAt > Date(),submissionRejected != true else { return false }
        return isUnfinished || (phase == .abandoned && !["complete","failed"].contains(reply?.state ?? ""))
    }
    var canRetrieve:Bool {
        expiresAt > Date() && (isUnfinished || phase == .abandoned || (phase == .failed && failureKind?.canRetry == true))
    }
    var readableStatus:String {
        if expiresAt <= Date(),phase != .completed { return "已过期" }
        switch phase {
        case .submitting: return "正在提交 · 尚未确认接受"
        case .saving: return "正在校验并保存到音频库"
        case .downloading:
            switch reply?.state { case "queued": return "云端排队 · 正在取回"; case "running": return "云端生成中 · 正在取回"; case "complete": return "云端已完成 · 正在下载"; default: return "正在取回 · 云端状态待确认" }
        case .waitingForForeground: return "等待返回 App 取回"
        case .suspended: return "取回暂停 · 任务已保留"
        case .abandoned: return "已停止等待 · 云端可能继续"
        case .completed: return "成品已入库"
        case .failed: return submissionRejected == true ? "提交未被接受" : "任务未完成"
        }
    }
}
