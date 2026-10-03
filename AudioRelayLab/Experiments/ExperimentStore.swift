import Foundation
import Combine

@MainActor final class ExperimentStore: ObservableObject {
    @Published private(set) var experiments: [Experiment] = []
    @Published private(set) var storageError: String?
    private let logger: DiagnosticsLogger
    private var directory: URL?
    private var loadWarning: String?
    init(logger: DiagnosticsLogger, directoryURL: URL? = nil) {
        self.logger = logger
        do {
            let folder: URL
            if let directoryURL { folder = directoryURL }
            else {
                folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Experiments", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                do {
                    let report = try HistoryArchive.decode(Self.readBoundedData(url: url))
                    for experiment in report.experiments where !experiments.contains(where: { $0.id == experiment.id }) {
                        experiments.append(experiment)
                    }
                    if report.skippedCount > 0 || report.warningCount > 0 {
                        loadWarning = "部分旧历史已兼容恢复，损坏项已跳过，原文件已保留。"
                    }
                }
                catch {
                    loadWarning = "部分历史文件无法读取，其他记录仍可使用，原文件已保留。"
                    logger.log("历史读取失败", diagnosticError(error))
                }
            }
            experiments.sort { $0.date > $1.date }
            storageError = loadWarning
        } catch {
            storageError = "实验历史目录无法读取。"
            logger.log("历史初始化失败", diagnosticError(error))
        }
    }
    func save(_ experiment: Experiment) throws {
        guard let directory else { throw LabError.message("实验历史目录不可用") }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(experiment).write(to: directory.appendingPathComponent("\(experiment.id.uuidString).json"), options: .atomic)
            if let index = experiments.firstIndex(where: { $0.id == experiment.id }) { experiments[index] = experiment }
            else { experiments.insert(experiment, at: 0) }
            experiments.sort { $0.date > $1.date }
            storageError = loadWarning
        } catch {
            storageError = "实验结果保存失败，请导出日志并检查设备存储空间。"
            logger.log("历史保存失败", diagnosticError(error))
            throw error
        }
    }

    /// 相同 UUID 保留现有记录，避免导入覆盖当前实验或已填写的结果。
    func importData(_ data: Data) throws -> HistoryStoreImportSummary {
        let report = try HistoryArchive.decode(data)
        guard !report.experiments.isEmpty else { throw LabError.message("JSON 中没有可读取的实验记录。") }
        var imported = 0
        var duplicates = 0
        var failures = 0
        var recovered = 0
        for experiment in report.experiments {
            if experiments.contains(where: { $0.id == experiment.id }) { duplicates += 1; continue }
            do {
                try save(experiment)
                imported += 1
                if !experiment.migrationWarnings.isEmpty { recovered += 1 }
            } catch { failures += 1 }
        }
        logger.log("历史导入", "新增=\(imported)，重复=\(duplicates)，损坏=\(report.skippedCount)，兼容恢复=\(recovered)，保存失败=\(failures)")
        return HistoryStoreImportSummary(importedCount: imported, duplicateCount: duplicates,
            skippedCount: report.skippedCount, recoveredCount: recovered, failedSaveCount: failures)
    }

    func importFile(from source: URL) throws -> HistoryStoreImportSummary {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return try importData(Self.readBoundedData(url: source))
    }

    private static func readBoundedData(url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= HistoryArchive.maximumBytes {
            let remaining = HistoryArchive.maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(1024 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= HistoryArchive.maximumBytes else { throw LabError.message("历史 JSON 请限制在 32 MB 以内。") }
        return data
    }
}

struct HistoryStoreImportSummary {
    let importedCount: Int
    let duplicateCount: Int
    let skippedCount: Int
    let recoveredCount: Int
    let failedSaveCount: Int
    var message: String {
        "已导入 \(importedCount) 条；重复 \(duplicateCount) 条；跳过损坏 \(skippedCount) 条；兼容恢复 \(recoveredCount) 条；保存失败 \(failedSaveCount) 条。"
    }
}
