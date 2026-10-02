import AVFAudio

struct AudioPortSnapshot: Codable {
    let portType: String
    let portName: String
    let uid: String
    let channels: [String]

    init(_ port: AVAudioSessionPortDescription) {
        portType = port.portType.rawValue
        portName = port.portName
        uid = port.uid
        channels = port.channels?.map { "\($0.channelNumber):\($0.channelName)" } ?? []
    }
    var summary: String { "\(portName)（\(portType)），UID=\(uid)，声道=\(channels.joined(separator: ","))" }
}

struct AudioRouteSnapshot: Codable {
    let inputs: [AudioPortSnapshot]
    let outputs: [AudioPortSnapshot]
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
    let inputAvailable: Bool
    let currentRoute: AudioRouteSnapshot

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
        inputAvailable = session.isInputAvailable
        currentRoute = AudioRouteSnapshot(session.currentRoute)
    }
    var summary: String {
        "类别：\(category)\n模式：\(mode)\n选项位掩码：\(categoryOptions)\n其他音频：\(isOtherAudioPlaying)\n次级音频静音提示：\(secondaryAudioShouldBeSilencedHint)\n采样率：\(sampleRate) Hz（偏好 \(preferredSampleRate)）\n缓冲时长：\(ioBufferDuration) s（偏好 \(preferredIOBufferDuration)）\n系统输出音量：\(outputVolume)\n输入可用：\(inputAvailable)\n\(currentRoute.summary)"
    }
}
