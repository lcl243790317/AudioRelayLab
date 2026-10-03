import AVFAudio

enum AudioRuntimeValidation {
    static func validate(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate), (1...8).contains(channels) else {
            throw LabError.invalidFormat
        }
    }
    static func validate(_ format: AVAudioFormat) throws {
        try validate(sampleRate: format.sampleRate, channels: format.channelCount)
        guard [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].contains(format.commonFormat) else {
            throw LabError.invalidFormat
        }
    }
}
