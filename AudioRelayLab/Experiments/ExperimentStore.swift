import Foundation
import Combine

@MainActor final class ExperimentStore: ObservableObject {
    @Published private(set) var experiments: [Experiment] = []
    @Published private(set) var storageError: String?
    private let logger: DiagnosticsLogger
    private var directory: URL?
    init(logger: DiagnosticsLogger) {
        self.logger = logger
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Experiments", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                do { experiments.append(try decoder.decode(Experiment.self, from: Data(contentsOf: url))) }
                catch {
                    storageError = "部分历史文件无法读取，原文件已保留。"
                    logger.log("历史读取失败", "文件=\(url.lastPathComponent)；\(diagnosticError(error))")
                }
            }
            experiments.sort { $0.date > $1.date }
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
            storageError = nil
        } catch {
            storageError = "实验结果保存失败，请导出日志并检查设备存储空间。"
            logger.log("历史保存失败", diagnosticError(error))
            throw error
        }
    }
}
