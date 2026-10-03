import AVFAudio

/// Local comparison only. Device identifiers are never logged or persisted.
struct VoiceHardwareRoute: Equatable {
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
    let inputPorts: [String]
    let outputPorts: [String]
    var isUsable: Bool {
        sampleRate.isFinite && (8_000...384_000).contains(sampleRate) && (1...8).contains(inputChannels)
            && (1...8).contains(outputChannels) && !inputPorts.isEmpty && !outputPorts.isEmpty
    }
    static func current() -> VoiceHardwareRoute {
        let s = AVAudioSession.sharedInstance()
        return .init(sampleRate:s.sampleRate,inputChannels:s.inputNumberOfChannels,outputChannels:s.outputNumberOfChannels,
            inputPorts:s.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.uid)" },
            outputPorts:s.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.uid)" })
    }
    enum Action { case keepRunning, restartSameFormat, stop }
    func action(comparedTo current: VoiceHardwareRoute, engineRunning:Bool, alreadyRestarted:Bool) -> Action {
        guard isUsable, current.isUsable, self == current else { return .stop }
        if engineRunning { return .keepRunning }
        return alreadyRestarted ? .stop : .restartSameFormat
    }
}
