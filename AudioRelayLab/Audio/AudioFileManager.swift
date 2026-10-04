import AVFoundation
import UniformTypeIdentifiers

enum AudioSource: String, Codable { case bundled, imported, voiceLabRecording, mixedRecording, aiConverted }

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
    var aiConversion: AIConversionMetadata? = nil
    var revoice: RevoiceMetadata? = nil
    var addedAt: Date? = nil
    enum CodingKeys: String, CodingKey { case id, fileName, sandboxFileName, duration, sampleRate, channelCount, byteCount, source, formatDescription, presetName, aiConversion, revoice, addedAt }
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
        aiConversion = try? c.decode(AIConversionMetadata.self, forKey: .aiConversion)
        revoice = try? c.decode(RevoiceMetadata.self, forKey: .revoice)
        addedAt = try? c.decode(Date.self, forKey: .addedAt)
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
    static let defaultTestID = UUID(uuid: (0,0,0,0,0,0,0x40,0,0x80,0,0,0,0,0,0,1))
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
        // Old bundled UUID copies resolve to the single canonical file after migration.
        return try audioDirectory().appendingPathComponent(metadata.source == .bundled ? "test-tone.wav" : metadata.sandboxFileName)
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
            formatDescription: "\(url.pathExtension.uppercased()) / \(format.channelCount)ch PCM 解码", presetName: presetName, addedAt: (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date) ?? Date())
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
        try defaultTestAudio(resource: nil)
    }
    private static func defaultTestAudio(resource: URL?) throws -> AudioAsset {
        let directory = try audioDirectory()
        let url = directory.appendingPathComponent("test-tone.wav")
        if (try? inspect(url: url)) == nil {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            if let resource { try FileManager.default.copyItem(at: resource, to: url) }
            else { try createTestAudio(at: url) }
        }
        let asset = try inspect(url: url, displayName: "内置测试音（440 / 660 / 880 Hz）.wav", id: defaultTestID, source: .bundled)
        let sidecar = url.appendingPathExtension("metadata.json")
        let existing = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(AudioAsset.self, from: $0) }
        if existing?.id != defaultTestID || existing?.source != .bundled { try register(asset) }
        // Only generated bundle copies are removed. Imported audio and recordings stay intact.
        for sidecar in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where sidecar.lastPathComponent.hasSuffix(".metadata.json") {
            guard let old = try? JSONDecoder().decode(AudioAsset.self, from: Data(contentsOf: sidecar)),
                old.source == .bundled, old.sandboxFileName != "test-tone.wav",
                !old.sandboxFileName.contains("/"), !old.sandboxFileName.contains("\\"),
                UUID(uuidString: URL(fileURLWithPath: old.sandboxFileName).deletingPathExtension().lastPathComponent) != nil else { continue }
            let oldURL = directory.appendingPathComponent(old.sandboxFileName)
            if FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
            try FileManager.default.removeItem(at: sidecar)
        }
        return asset
    }
    private static func createTestAudio(at url: URL) throws {
        // 3 × (1 + .3 + 1 + .3 + 1 + .3) = 11.7 秒。
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false) else { throw LabError.message("无法创建测试音频格式") }
        try writeTestAudio(url: url, format: format, sampleRate: sampleRate)
    }
    static func loadBundledAudio() throws -> AudioAsset {
        try defaultTestAudio(resource: Bundle.main.url(forResource: "BundledTest", withExtension: "wav"))
    }
    static func register(_ asset: AudioAsset) throws {
        let url = try self.url(for: asset)
        let sidecar = url.appendingPathExtension("metadata.json")
        var stored = asset
        // Re-registering metadata must never move an existing recording to the top.
        if let data = try? Data(contentsOf: sidecar),
           let existing = try? JSONDecoder().decode(AudioAsset.self, from: data) {
            stored.addedAt = existing.addedAt ?? legacyAddedAt(url)
        } else if stored.addedAt == nil { stored.addedAt = legacyAddedAt(url) }
        try JSONEncoder().encode(stored).write(to: sidecar, options: .atomic)
    }
    static func listLocalAudio() throws -> [AudioAsset] {
        try FileManager.default.contentsOfDirectory(at: audioDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".metadata.json") }
            .compactMap { url in
                guard var asset = try? JSONDecoder().decode(AudioAsset.self, from: Data(contentsOf: url)),
                    let local = try? self.url(for: asset), FileManager.default.fileExists(atPath: local.path) else { return nil }
                asset.addedAt = asset.addedAt ?? legacyAddedAt(local)
                return asset
            }.sorted(by: newestFirst)
    }
    static func newestFirst(_ lhs: AudioAsset, _ rhs: AudioAsset) -> Bool {
        if (lhs.source == .bundled) != (rhs.source == .bundled) { return rhs.source == .bundled }
        let left = lhs.addedAt ?? .distantPast, right = rhs.addedAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    private static func legacyAddedAt(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
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
