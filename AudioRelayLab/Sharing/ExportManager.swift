import Foundation

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum ExportManager {
    private static func destination(prefix: String = "AudioRelayLab", extension ext: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(ext)")
    }
    static func logFile(text: String) throws -> URL {
        let url = try destination(extension: "txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    static func jsonFile(experiments: [Experiment]) throws -> URL {
        let url = try destination(prefix: "AudioRelayLab-history", extension: "json")
        try HistoryArchive.encode(experiments).write(to: url, options: .atomic)
        return url
    }
    static func jsonLogFile(entries: [DiagnosticEntry]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = try destination(prefix: "AudioRelayLab-diagnostics", extension: "json")
        try encoder.encode(entries).write(to: url, options: .atomic)
        return url
    }
    static func csvFile(experiments: [Experiment]) throws -> URL {
        let iso = ISO8601DateFormatter()
        var rows = [["实验编号", "日期", "设备", "iOS 版本", "App 版本", "构建", "音频", "引擎", "音频模式", "延迟秒", "请求播放时长秒", "初始播放音量", "语音优化", "扬声器覆盖", "最终状态", "结果", "用户已判断", "备注", "请求时间", "调度调用时间", "目标音频时间", "结束时间", "会话快照", "技术错误", "历史兼容提示", "记录版本", "完整日志", "开始位置秒", "播放倍速", "音频来源", "音频格式"]]
        rows += experiments.map { value -> [String] in
            var row = [value.id.uuidString, iso.string(from: value.date), value.device.modelIdentifier,
                       value.device.systemVersion, value.device.appVersion, value.device.build, value.audio.fileName]
            row += [value.settings.engine.rawValue, value.settings.profile.historyTitle, String(value.settings.delay),
                    value.settings.requestedDuration.map { String($0) } ?? "完整文件", String(value.settings.volume),
                    value.settings.voiceOptimized ? "是" : "否", value.settings.speakerOverride ? "是" : "否"]
            row += [value.finalState.title, value.result.title, value.resultReviewed ? "是" : "否", value.notes,
                    value.schedule.map { iso.string(from: $0.requestedTime) } ?? "",
                    value.schedule.map { iso.string(from: $0.scheduleCallTime) } ?? "",
                    value.schedule?.scheduledAudioTime ?? "", value.finishedAt.map { iso.string(from: $0) } ?? ""]
            row += [value.sessionSnapshots.map(\.summary).joined(separator: "\n\n"), value.errorDetails.joined(separator: "\n"),
                    value.migrationWarnings.joined(separator: "\n"), String(value.schemaVersion),
                    value.logs.map(\.line).joined(separator: "\n")]
            row += [String(value.settings.startOffset),String(value.settings.playbackRate),value.audio.source.rawValue,value.audio.formatDescription]
            return row
        }
        let content = "\u{FEFF}" + rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        let url = try destination(prefix: "AudioRelayLab-history", extension: "csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private static func csvCell(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let protected = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
