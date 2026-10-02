import AVFAudio
import Combine

enum AudioSessionEvent {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case mediaLost
    case mediaReset
    case silenceHint
}

@MainActor final class AudioSessionManager: ObservableObject {
    @Published private(set) var snapshot = AudioSessionSnapshot()
    @Published private(set) var interruptionMessage: String?
    var onEvent: ((AudioSessionEvent) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private let logger: DiagnosticsLogger
    private var observers: [NSObjectProtocol] = []

    init(logger: DiagnosticsLogger) {
        self.logger = logger
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.silenceSecondaryAudioHintNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.receive(note) }
            })
        }
        capture("App 启动")
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(profile: AudioSessionProfile, speakerOverride: Bool) throws {
        interruptionMessage = nil
        capture("setCategory 前")
        do {
            try session.setCategory(profile.category, mode: .default, options: profile.options)
            logger.log("音频会话", "setCategory 成功；配置=\(profile.rawValue) \(profile.title)")
            capture("setCategory 后")
            capture("setActive 前")
            try session.setActive(true)
            logger.log("音频会话", "setActive(true) 成功")
            capture("setActive 后")
            if profile.usesInput {
                do {
                    try session.overrideOutputAudioPort(speakerOverride ? .speaker : .none)
                    logger.log("扬声器覆盖", "overrideOutputAudioPort(\(speakerOverride ? "speaker" : "none")) 成功")
                } catch {
                    logger.log("扬声器覆盖失败", diagnosticError(error))
                    throw error
                }
                capture("扬声器覆盖后")
            }
        } catch {
            logger.log("会话配置失败", diagnosticError(error))
            capture("配置失败后")
            throw error
        }
    }
    func reactivate() throws {
        capture("恢复 setActive 前")
        do { try session.setActive(true); capture("恢复 setActive 后") }
        catch { logger.log("会话恢复失败", diagnosticError(error)); throw error }
    }
    func deactivate() {
        capture("停用 setActive 前")
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            logger.log("音频会话", "setActive(false, notifyOthersOnDeactivation) 成功")
        } catch { logger.log("停用会话失败", diagnosticError(error)) }
        capture("停用 setActive 后")
    }
    @discardableResult func capture(_ reason: String) -> AudioSessionSnapshot {
        snapshot = AudioSessionSnapshot(session: session)
        logger.log("音频会话快照", "节点=\(reason)\n\(snapshot.summary)")
        return snapshot
    }
    var microphoneInjectionDiagnostic: String {
        #if compiler(>=6.1)
        if #available(iOS 18.2, *) {
            return "系统能力可用：\(session.isMicrophoneInjectionAvailable ? "是" : "否")。此页面仅读取能力，不启用注入。"
        }
        #else
        if #available(iOS 18.2, *) {
            return "此构建 SDK 未编入麦克风注入能力查询；核心声学实验仍可使用。"
        }
        #endif
        return "当前系统低于 iOS 18.2，不支持此诊断能力。"
    }
    private func receive(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? UInt.max
            let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            logger.log("音频中断", "type=\(typeValue)，options=\(optionsValue)，shouldResume=\(shouldResume)，附加信息=\(notification.userInfo ?? [:])")
            capture("interruption")
            if typeValue == AVAudioSession.InterruptionType.began.rawValue {
                interruptionMessage = "音频会话已被其他 App 中断"
                onEvent?(.interruptionBegan)
            } else if typeValue == AVAudioSession.InterruptionType.ended.rawValue {
                interruptionMessage = shouldResume ? "中断已结束，系统允许尝试恢复" : "中断已结束，系统未建议恢复"
                onEvent?(.interruptionEnded(shouldResume: shouldResume))
            } else { logger.log("音频中断", "收到未知中断类型，不执行自动恢复。") }
        case AVAudioSession.routeChangeNotification:
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            logger.log("路由变化", "原因=\(reason)（\(routeReason(reason))）\n先前路由：\(previous.map { AudioRouteSnapshot($0).summary } ?? "系统未提供")\n当前路由：\(AudioRouteSnapshot(session.currentRoute).summary)")
            capture("route change")
            onEvent?(.routeChanged)
        case AVAudioSession.mediaServicesWereLostNotification:
            logger.log("媒体服务", "媒体服务已丢失；本次播放对象不可继续使用。")
            capture("media services lost")
            onEvent?(.mediaLost)
        case AVAudioSession.mediaServicesWereResetNotification:
            logger.log("媒体服务", "媒体服务已重置；下一次准备将重建音频对象，本次实验不会自动重新开始。")
            capture("media services reset")
            onEvent?(.mediaReset)
        case AVAudioSession.silenceSecondaryAudioHintNotification:
            logger.log("次级音频提示", "附加信息=\(notification.userInfo ?? [:])")
            capture("silence hint")
            onEvent?(.silenceHint)
        default: break
        }
    }
    private func routeReason(_ value: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: value) {
        case .newDeviceAvailable: return "新设备接入"
        case .oldDeviceUnavailable: return "旧设备离开"
        case .categoryChange: return "类别改变"
        case .override: return "输出覆盖"
        case .wakeFromSleep: return "从休眠唤醒"
        case .noSuitableRouteForCategory: return "无适合此类别的路由"
        case .routeConfigurationChange: return "路由配置改变"
        default: return "未知"
        }
    }
}
