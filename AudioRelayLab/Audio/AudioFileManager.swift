import AVFoundation

struct AudioFileMetadata: Codable, Identifiable {
    let id: UUID
    let fileName: String
    let sandboxFileName: String
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: UInt32
    let byteCount: Int64
    enum CodingKeys: String, CodingKey { case id, fileName, sandboxFileName, duration, sampleRate, channelCount, byteCount }
}

extension AudioFileMetadata {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? "旧记录音频"
        sandboxFileName = (try? c.decode(String.self, forKey: .sandboxFileName)) ?? ""
        duration = (try? c.decode(Double.self, forKey: .duration)) ?? 0
        sampleRate = (try? c.decode(Double.self, forKey: .sampleRate)) ?? 0
        channelCount = (try? c.decode(UInt32.self, forKey: .channelCount)) ?? 0
        byteCount = (try? c.decode(Int64.self, forKey: .byteCount)) ?? 0
    }
}

enum AudioFileManager {
    static func audioDirectory() throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func url(for metadata: AudioFileMetadata) throws -> URL {
        let name = metadata.sandboxFileName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw LabError.message("记录中的音频文件路径无效，请重新导入音频")
        }
        return try audioDirectory().appendingPathComponent(metadata.sandboxFileName)
    }
    static func inspect(url: URL, displayName: String? = nil) throws -> AudioFileMetadata {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, (8_000...384_000).contains(format.sampleRate),
            (1...8).contains(format.channelCount), file.length > 0 else {
            throw LabError.message("音频文件为空或格式无法读取")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return AudioFileMetadata(id: UUID(), fileName: displayName ?? url.lastPathComponent,
            sandboxFileName: url.lastPathComponent, duration: Double(file.length) / format.sampleRate,
            sampleRate: format.sampleRate, channelCount: format.channelCount,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }
    static func importFile(from source: URL) throws -> AudioFileMetadata {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 256 * 1024 * 1024 else { throw LabError.message("请导入小于 256 MB 的实验音频") }
        let destination = try audioDirectory().appendingPathComponent("\(UUID().uuidString).\(source.pathExtension.isEmpty ? "audio" : source.pathExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return try inspect(url: destination, displayName: source.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    static func generateTestAudio() throws -> AudioFileMetadata {
        let url = try audioDirectory().appendingPathComponent("test-tone.wav")
        // 3 × (1 + .3 + 1 + .3 + 1 + .3) = 11.7 秒。
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false) else { throw LabError.message("无法创建测试音频格式") }
        try writeTestAudio(url: url, format: format, sampleRate: sampleRate)
        return try inspect(url: url, displayName: "测试音频（440 / 660 / 880 Hz）.wav")
    }
    private static func writeTestAudio(url: URL, format: AVAudioFormat, sampleRate: Double) throws {
        let output = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        for _ in 0..<3 {
            for (frequency, silence) in [(440.0, 0.3), (660.0, 0.3), (880.0, 0.3)] {
                let count = AVAudioFrameCount(sampleRate * (1 + silence))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                    let samples = buffer.floatChannelData?[0] else { throw LabError.message("无法分配测试音频缓冲") }
                buffer.frameLength = count
                for index in 0..<Int(count) {
                    let seconds = Double(index) / sampleRate
                    if seconds < 1 {
                        let fade = min(1, min(seconds / 0.01, (1 - seconds) / 0.01))
                        samples[index] = Float(0.28 * fade * sin(2 * .pi * frequency * seconds))
                    } else { samples[index] = 0 }
                }
                try output.write(from: buffer)
            }
        }
    }
}
