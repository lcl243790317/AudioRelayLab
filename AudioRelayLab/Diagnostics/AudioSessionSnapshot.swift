import AVFAudio

struct AudioPortSnapshot: Codable {
    let portType: String
    let portName: String
    let uid: String
    let channels: [String]
    enum CodingKeys: String, CodingKey { case portType, portName, uid, channels }

    init(_ port: AVAudioSessionPortDescription) {
        portType = port.portType.rawValue
        // 自动诊断仅记录端口类型，不保存个人耳机名称和设备 UID。
        portName = Self.displayName(port.portType.rawValue)
        uid = ""
        channels = port.channels?.map { String($0.channelNumber) } ?? []
    }
    var summary: String { "\(portName)（\(portType)），声道=\(channels.joined(separator: ","))" }
    static func displayName(_ type: String) -> String {
        switch type {
        case AVAudioSession.Port.builtInMic.rawValue: return "内置麦克风"
        case AVAudioSession.Port.builtInSpeaker.rawValue: return "内置扬声器"
        case AVAudioSession.Port.builtInReceiver.rawValue: return "内置听筒"
        case AVAudioSession.Port.bluetoothHFP.rawValue: return "蓝牙 HFP"
        case AVAudioSession.Port.bluetoothA2DP.rawValue: return "蓝牙 A2DP"
        default: return type
        }
    }
}

extension AudioPortSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portType = (try? c.decode(String.self, forKey: .portType)) ?? "Unknown"
        portName = (try? c.decode(String.self, forKey: .portName)) ?? Self.displayName(portType)
        uid = (try? c.decode(String.self, forKey: .uid)) ?? ""
        channels = (try? c.decode([String].self, forKey: .channels)) ?? []
    }
}

struct AudioRouteSnapshot: Codable {
    let inputs: [AudioPortSnapshot]
    let outputs: [AudioPortSnapshot]
    enum CodingKeys: String, CodingKey { case inputs, outputs }
    init(inputs: [AudioPortSnapshot], outputs: [AudioPortSnapshot]) {
        self.inputs = inputs
        self.outputs = outputs
    }
    init(_ route: AVAudioSessionRouteDescription) {
        inputs = route.inputs.map(AudioPortSnapshot.init)
        outputs = route.outputs.map(AudioPortSnapshot.init)
    }
    var summary: String {
        "输入：\(inputs.map(\.summary).joined(separator: "；"))\n输出：\(outputs.map(\.summary).joined(separator: "；"))"
    }
    var usesExternalDevice: Bool {
        (inputs + outputs).contains { ![AVAudioSession.Port.builtInSpeaker.rawValue,
            AVAudioSession.Port.builtInMic.rawValue, AVAudioSession.Port.builtInReceiver.rawValue].contains($0.portType) }
    }
    var usesSpeaker: Bool { outputs.contains { $0.portType == AVAudioSession.Port.builtInSpeaker.rawValue } }
}

extension AudioRouteSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputs = (try? c.decode([AudioPortSnapshot].self, forKey: .inputs)) ?? []
        outputs = (try? c.decode([AudioPortSnapshot].self, forKey: .outputs)) ?? []
    }
}

struct AudioSessionSnapshot: Codable {
    let date: Date
    let category: String
    let mode: String
    let categoryOptions: UInt
    let isOtherAudioPlaying: Bool
    let secondaryAudioShouldBeSilencedHint: Bool
    let sampleRate: Double
    let preferredSampleRate: Double
    let ioBufferDuration: Double
    let preferredIOBufferDuration: Double
    let outputVolume: Float
    var inputLatency: Double = 0
    var outputLatency: Double = 0
    let inputAvailable: Bool
    let currentRoute: AudioRouteSnapshot
    let availableInputs: [AudioPortSnapshot]
    enum CodingKeys: String, CodingKey {
        case date, category, mode, categoryOptions, isOtherAudioPlaying, secondaryAudioShouldBeSilencedHint,
            sampleRate, preferredSampleRate, ioBufferDuration, preferredIOBufferDuration, outputVolume,
            inputAvailable, currentRoute, availableInputs, inputLatency, outputLatency
    }

    init(session: AVAudioSession = .sharedInstance()) {
        date = Date()
        category = session.category.rawValue
        mode = session.mode.rawValue
        categoryOptions = session.categoryOptions.rawValue
        isOtherAudioPlaying = session.isOtherAudioPlaying
        secondaryAudioShouldBeSilencedHint = session.secondaryAudioShouldBeSilencedHint
        sampleRate = session.sampleRate
        preferredSampleRate = session.preferredSampleRate
        ioBufferDuration = session.ioBufferDuration
        preferredIOBufferDuration = session.preferredIOBufferDuration
        outputVolume = session.outputVolume
        inputLatency = session.inputLatency
        outputLatency = session.outputLatency
        inputAvailable = session.isInputAvailable
        currentRoute = AudioRouteSnapshot(session.currentRoute)
        availableInputs = session.availableInputs?.map(AudioPortSnapshot.init) ?? []
    }
    var summary: String {
        "类别：\(category)\n模式：\(mode)\n选项位掩码：\(categoryOptions)\n其他音频：\(isOtherAudioPlaying)\n次级音频静音提示：\(secondaryAudioShouldBeSilencedHint)\n采样率：\(sampleRate) Hz（偏好 \(preferredSampleRate)）\n缓冲时长：\(ioBufferDuration) s（偏好 \(preferredIOBufferDuration)）\n系统输出音量：\(outputVolume)\n输入可用：\(inputAvailable)\n可选输入：\(availableInputs.map(\.summary).joined(separator: "；"))\n\(currentRoute.summary)"
    }
}

extension AudioSessionSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(Date.self, forKey: .date)) ?? .distantPast
        category = (try? c.decode(String.self, forKey: .category)) ?? "未知"
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "未知"
        categoryOptions = (try? c.decode(UInt.self, forKey: .categoryOptions)) ?? 0
        isOtherAudioPlaying = (try? c.decode(Bool.self, forKey: .isOtherAudioPlaying)) ?? false
        secondaryAudioShouldBeSilencedHint = (try? c.decode(Bool.self, forKey: .secondaryAudioShouldBeSilencedHint)) ?? false
        sampleRate = (try? c.decode(Double.self, forKey: .sampleRate)) ?? 0
        preferredSampleRate = (try? c.decode(Double.self, forKey: .preferredSampleRate)) ?? 0
        ioBufferDuration = (try? c.decode(Double.self, forKey: .ioBufferDuration)) ?? 0
        preferredIOBufferDuration = (try? c.decode(Double.self, forKey: .preferredIOBufferDuration)) ?? 0
        outputVolume = (try? c.decode(Float.self, forKey: .outputVolume)) ?? 0
        inputLatency = (try? c.decode(Double.self, forKey: .inputLatency)) ?? 0
        outputLatency = (try? c.decode(Double.self, forKey: .outputLatency)) ?? 0
        inputAvailable = (try? c.decode(Bool.self, forKey: .inputAvailable)) ?? false
        availableInputs = (try? c.decode([AudioPortSnapshot].self, forKey: .availableInputs)) ?? []
        if let route = try? c.decode(AudioRouteSnapshot.self, forKey: .currentRoute) { currentRoute = route }
        else { currentRoute = AudioRouteSnapshot(inputs: [], outputs: []) }
    }
}
