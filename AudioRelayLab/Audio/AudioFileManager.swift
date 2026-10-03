import AVFoundation
import UniformTypeIdentifiers

enum AudioSource: String, Codable { case bundled, imported, voiceLabRecording, mixedRecording }

struct AudioFileMetadata: Codable, Identifiable {
    let id: UUID
    let fileName: String
    let sandboxFileName: String
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: UInt32
    let byteCount: Int64
    var source: AudioSource = .imported
    var formatDescription: String = "音频"
    var presetName: String? = nil
    enum CodingKeys: String, CodingKey { case id, fileName, sandboxFileName, duration, sampleRate, channelCount, byteCount, source, formatDescription, presetName }
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
        source = (try? c.decode(AudioSource.self, forKey: .source)) ?? (sandboxFileName == "test-tone.wav" ? .bundled : .imported)
        formatDescription = (try? c.decode(String.self, forKey: .formatDescription)) ?? URL(fileURLWithPath: sandboxFileName).pathExtension.uppercased()
        presetName = try? c.decode(String.self, forKey: .presetName)
    }
}

typealias AudioAsset = AudioFileMetadata

/// Acquire in the picker completion, before handing work to a detached task.
final class AudioAccessLease: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
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
    static func inspect(url: URL, displayName: String? = nil, id: UUID = UUID(), source: AudioSource = .imported,
                        presetName: String? = nil) throws -> AudioFileMetadata {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, (8_000...384_000).contains(format.sampleRate),
            (1...8).contains(format.channelCount), file.length > 0 else {
            throw LabError.message("音频文件为空或格式无法读取")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else { throw LabError.invalidFormat }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(256, file.length)))
        guard buffer.frameLength > 0 else { throw LabError.invalidFormat }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return AudioFileMetadata(id: id, fileName: displayName ?? url.lastPathComponent,
            sandboxFileName: url.lastPathComponent, duration: Double(file.length) / format.sampleRate,
            sampleRate: format.sampleRate, channelCount: format.channelCount,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0, source: source,
            formatDescription: "\(url.pathExtension.uppercased()) / \(format.channelCount)ch PCM 解码", presetName: presetName)
    }
    static func importFile(from source: URL) throws -> AudioFileMetadata {
        try importFile(lease: AudioAccessLease(source))
    }
    static func importFile(lease: AudioAccessLease) throws -> AudioFileMetadata {
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<AudioFileMetadata, Error>?
        NSFileCoordinator().coordinate(readingItemAt: lease.url, options: [], error: &coordinationError) { readable in
            result = Result { try copyIntoLibrary(readable, displayName: lease.url.lastPathComponent, source: .imported) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LabError.message("文件提供器没有返回可读取文件，请先下载到本机后重试") }
        return try result.get()
    }
    static func copyIntoLibrary(_ sourceURL: URL, displayName: String, source: AudioSource) throws -> AudioFileMetadata {
        try Task.checkCancellation()
        let destination = try audioDirectory().appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased())")
        do {
            let reader = try FileHandle(forReadingFrom: sourceURL)
            defer { try? reader.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw LabError.audioUnavailable }
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }
            var bytes = 0
            while let data = try reader.read(upToCount: 512 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                bytes += data.count
                guard bytes <= 256 * 1024 * 1024 else { throw LabError.message("请导入小于 256 MB 的音频") }
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            let metadata = try inspect(url: destination, displayName: displayName, source: source)
            try register(metadata)
            return metadata
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
        let metadata = try inspect(url: url, displayName: "测试音频（440 / 660 / 880 Hz）.wav", source: .bundled)
        try register(metadata)
        return metadata
    }
    static func loadBundledAudio() throws -> AudioAsset {
        guard let source = Bundle.main.url(forResource: "BundledTest", withExtension: "wav") else {
            // Older project checkouts may not yet have generated the resource.
            return try generateTestAudio()
        }
        return try copyIntoLibrary(source, displayName: "内置测试音（440 / 660 / 880 Hz）.wav", source: .bundled)
    }
    static func register(_ asset: AudioAsset) throws {
        let url = try self.url(for: asset)
        try JSONEncoder().encode(asset).write(to: url.appendingPathExtension("metadata.json"), options: .atomic)
    }
    static func listLocalAudio() throws -> [AudioAsset] {
        try FileManager.default.contentsOfDirectory(at: audioDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".metadata.json") }
            .compactMap { url in
                guard let asset = try? JSONDecoder().decode(AudioAsset.self, from: Data(contentsOf: url)),
                    let local = try? self.url(for: asset), FileManager.default.fileExists(atPath: local.path) else { return nil }
                return asset
            }.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }
    static func removeAudio(_ asset: AudioAsset) throws {
        let local = try url(for: asset)
        if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
        let sidecar = local.appendingPathExtension("metadata.json")
        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
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
