import Foundation

enum ExperimentResult: String, Codable, CaseIterable, Identifiable {
    case captured, playbackStopped, notCaptured, quieter, wechatInterrupted, uncertain, unknown
    static let selectableCases: [ExperimentResult] = [.captured, .playbackStopped, .notCaptured, .quieter, .wechatInterrupted, .uncertain]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captured: return "音频成功进入微信语音"
        case .playbackStopped: return "播放被停止"
        case .notCaptured: return "播放继续但微信没有录进去"
        case .quieter: return "播放音量明显降低"
        case .wechatInterrupted: return "微信录音被中断"
        case .uncertain: return "不确定"
        case .unknown: return "旧版未知结果"
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self = Self(rawValue: (try? value.decode(String.self)) ?? "") ?? .unknown
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

struct ExperimentSettings: Codable {
    let engine: PlaybackEngineKind
    let profile: AudioSessionProfile
    let delay: Double
    let volume: Float
    let voiceOptimized: Bool
    let speakerOverride: Bool
    let requestedDuration: Double?
    let startOffset: Double
    let playbackRate: Float
    let endOffset: Double?

    init(engine: PlaybackEngineKind, profile: AudioSessionProfile, delay: Double, volume: Float,
         voiceOptimized: Bool, speakerOverride: Bool, requestedDuration: Double? = nil, startOffset: Double = 0, playbackRate: Float = 1, endOffset: Double? = nil) {
        self.engine = engine
        self.profile = profile
        self.delay = delay
        self.volume = volume
        self.voiceOptimized = voiceOptimized
        self.speakerOverride = speakerOverride
        self.requestedDuration = requestedDuration
        self.startOffset = startOffset
        self.playbackRate = playbackRate
        self.endOffset = endOffset
    }

    private enum CodingKeys: String, CodingKey {
        case engine, profile, delay, volume, voiceOptimized, speakerOverride, requestedDuration, startOffset, playbackRate, endOffset
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = values.historyValue(PlaybackEngineKind.self, forKey: .engine, default: .unknown)
        profile = values.historyValue(AudioSessionProfile.self, forKey: .profile, default: .unknown)
        let storedDelay = values.historyValue(Double.self, forKey: .delay, default: 0)
        delay = storedDelay.isFinite && storedDelay >= 0 ? storedDelay : 0
        let storedVolume = values.historyValue(Float.self, forKey: .volume, default: 0.5)
        volume = storedVolume.isFinite ? min(1, max(0, storedVolume)) : 0.5
        voiceOptimized = values.historyValue(Bool.self, forKey: .voiceOptimized, default: false)
        speakerOverride = values.historyValue(Bool.self, forKey: .speakerOverride, default: false)
        let duration = try? values.decodeIfPresent(Double.self, forKey: .requestedDuration)
        requestedDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let offset = values.historyValue(Double.self, forKey: .startOffset, default: 0)
        let validOffset = offset.isFinite && offset >= 0 ? offset : 0
        startOffset = validOffset
        let rate = values.historyValue(Float.self, forKey: .playbackRate, default: 1)
        playbackRate = rate.isFinite && (0.5...2).contains(rate) ? rate : 1
        let end = try? values.decode(Double.self,forKey:.endOffset)
        endOffset = end.flatMap { $0.isFinite && $0 > validOffset ? $0 : nil }
    }
}

struct Experiment: Codable, Identifiable {
    let id: UUID
    let date: Date
    let device: DeviceInfo
    let audio: AudioFileMetadata
    let settings: ExperimentSettings
    var schedule: PlaybackSchedule?
    var finalState: PlaybackState
    var result: ExperimentResult
    var resultReviewed: Bool
    var notes: String
    var finishedAt: Date?
    var logs: [DiagnosticEntry]
    var schemaVersion: Int
    var sessionSnapshots: [AudioSessionSnapshot]
    var errorDetails: [String]
    var migrationWarnings: [String]

    init(id: UUID, date: Date, device: DeviceInfo, audio: AudioFileMetadata, settings: ExperimentSettings,
         schedule: PlaybackSchedule?, finalState: PlaybackState, result: ExperimentResult,
         resultReviewed: Bool, notes: String, finishedAt: Date?, logs: [DiagnosticEntry],
         schemaVersion: Int = 2, sessionSnapshots: [AudioSessionSnapshot] = [],
         errorDetails: [String] = [], migrationWarnings: [String] = []) {
        self.id = id
        self.date = date
        self.device = device
        self.audio = audio
        self.settings = settings
        self.schedule = schedule
        self.finalState = finalState
        self.result = result
        self.resultReviewed = resultReviewed
        self.notes = notes
        self.finishedAt = finishedAt
        self.logs = logs
        self.schemaVersion = schemaVersion
        self.sessionSnapshots = sessionSnapshots
        self.errorDetails = errorDetails
        self.migrationWarnings = migrationWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, device, audio, settings, schedule, finalState, result, resultReviewed, notes, finishedAt, logs
        case schemaVersion, sessionSnapshots, errorDetails, migrationWarnings
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identityKeys: [CodingKeys] = [.id, .date, .audio, .settings]
        guard identityKeys.contains(where: { values.contains($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "不是实验记录对象"))
        }
        var warnings = values.historyValue([String].self, forKey: .migrationWarnings, default: [])
        func recovered<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: @autoclosure () -> T) -> T {
            if let decoded = try? values.decode(type, forKey: key) { return decoded }
            warnings.append("\(key.rawValue) 字段缺失或损坏，已使用历史兼容值。")
            return fallback()
        }
        id = recovered(UUID.self, .id, UUID())
        date = recovered(Date.self, .date, Date(timeIntervalSince1970: 0))
        device = recovered(DeviceInfo.self, .device,
            DeviceInfo(model: "未知", modelIdentifier: "未知", systemVersion: "未知", appVersion: "未知", build: "未知"))
        audio = recovered(AudioFileMetadata.self, .audio,
            AudioFileMetadata(id: UUID(), fileName: "历史音频（未随历史导入）", sandboxFileName: "",
                              duration: 0, sampleRate: 0, channelCount: 0, byteCount: 0))
        settings = recovered(ExperimentSettings.self, .settings,
            ExperimentSettings(engine: .unknown, profile: .unknown, delay: 0, volume: 0.5,
                               voiceOptimized: false, speakerOverride: false))
        schedule = try? values.decodeIfPresent(PlaybackSchedule.self, forKey: .schedule)
        finalState = values.historyValue(PlaybackState.self, forKey: .finalState, default: .failed)
        result = values.historyValue(ExperimentResult.self, forKey: .result, default: .uncertain)
        resultReviewed = values.historyValue(Bool.self, forKey: .resultReviewed, default: false)
        notes = values.historyValue(String.self, forKey: .notes, default: "")
        finishedAt = try? values.decodeIfPresent(Date.self, forKey: .finishedAt)
        let decodedLogs = try? values.decode(LossyHistoryArray<DiagnosticEntry>.self, forKey: .logs)
        logs = decodedLogs?.elements ?? []
        let snapshots = try? values.decode(LossyHistoryArray<AudioSessionSnapshot>.self, forKey: .sessionSnapshots)
        sessionSnapshots = snapshots?.elements ?? []
        if let lost = decodedLogs?.skippedCount, lost > 0 { warnings.append("已跳过 \(lost) 条损坏日志。") }
        if let lost = snapshots?.skippedCount, lost > 0 { warnings.append("已跳过 \(lost) 条损坏会话快照。") }
        let decodedErrors = try? values.decode(LossyHistoryArray<String>.self, forKey: .errorDetails)
        errorDetails = decodedErrors?.elements ?? []
        if let lost = decodedErrors?.skippedCount, lost > 0 { warnings.append("已跳过 \(lost) 条损坏技术错误。") }
        schemaVersion = max(2, values.historyValue(Int.self, forKey: .schemaVersion, default: 1))
        if settings.profile == .unknown { warnings.append("未知配置仅供历史查看，不能用于新实验。") }
        if settings.engine == .unknown { warnings.append("未知播放引擎仅供历史查看。") }
        if result == .unknown { warnings.append("未知人工结果已保留为旧版未知结果。") }
        migrationWarnings = Array(Set(warnings)).sorted()
    }
}

extension KeyedDecodingContainer {
    func historyValue<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback()
    }
}

/// superDecoder 消费一个完整 JSON 值，因此坏项不会卡住后面的有效项。
struct LossyHistoryArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let skippedCount: Int
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        var accepted: [Element] = []
        var skipped = 0
        while !values.isAtEnd {
            let elementDecoder = try values.superDecoder()
            do { accepted.append(try Element(from: elementDecoder)) }
            catch { skipped += 1 }
        }
        elements = accepted
        skippedCount = skipped
    }
}

struct HistoryImportReport {
    let experiments: [Experiment]
    let skippedCount: Int
    var warningCount: Int { experiments.filter { !$0.migrationWarnings.isEmpty }.count }
}

enum HistoryArchive {
    static let maximumBytes = 32 * 1024 * 1024
    static func encode(_ experiments: [Experiment]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(experiments)
    }
    static func decode(_ data: Data) throws -> HistoryImportReport {
        guard data.count <= maximumBytes else { throw LabError.message("历史 JSON 请限制在 32 MB 以内。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) {
                let precise = ISO8601DateFormatter()
                precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = precise.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
            }
            if let seconds = try? value.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "历史时间格式无法读取")
        }
        // 接受旧版数组导出、单条本地记录和带 experiments 的版本化归档。
        if let list = try? decoder.decode(LossyHistoryArray<Experiment>.self, from: data) {
            return HistoryImportReport(experiments: list.elements, skippedCount: list.skippedCount)
        }
        if let archive = try? decoder.decode(VersionedArchive.self, from: data) {
            return HistoryImportReport(experiments: archive.experiments.elements, skippedCount: archive.experiments.skippedCount)
        }
        let experiment = try decoder.decode(Experiment.self, from: data)
        return HistoryImportReport(experiments: [experiment], skippedCount: 0)
    }
    private struct VersionedArchive: Decodable {
        let experiments: LossyHistoryArray<Experiment>
    }
}
