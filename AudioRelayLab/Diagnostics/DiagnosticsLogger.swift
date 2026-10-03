import Foundation
import Combine

struct DiagnosticEntry: Codable, Identifiable {
    let id: UUID
    let sequence: Int
    let date: Date
    let localTime: String
    let uptime: TimeInterval
    let elapsed: TimeInterval
    let category: String
    let message: String
    var experimentID: UUID? = nil

    enum CodingKeys: String, CodingKey { case id, sequence, date, localTime, uptime, elapsed, category, message, experimentID }

    var line: String {
        "\(localTime) | +\(String(format: "%.3f", elapsed))s | uptime=\(String(format: "%.3f", uptime))s | \(category) | [sequence=\(sequence)] \(experimentID.map { "[实验=\($0.uuidString)] " } ?? "")\(message)"
    }
}

extension DiagnosticEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        sequence = (try? c.decode(Int.self, forKey: .sequence)) ?? 0
        date = (try? c.decode(Date.self, forKey: .date)) ?? .distantPast
        localTime = (try? c.decode(String.self, forKey: .localTime)) ?? "旧记录未提供"
        uptime = (try? c.decode(Double.self, forKey: .uptime)) ?? 0
        elapsed = (try? c.decode(Double.self, forKey: .elapsed)) ?? 0
        category = (try? c.decode(String.self, forKey: .category)) ?? "旧记录"
        message = (try? c.decode(String.self, forKey: .message)) ?? "旧记录未提供消息"
        experimentID = try? c.decode(UUID.self, forKey: .experimentID)
    }
}

final class DiagnosticsLogger: ObservableObject, @unchecked Sendable {
    @Published private(set) var revision = 0
    @Published private(set) var storageWarning: String?
    private let lock = NSLock()
    private var records: [DiagnosticEntry] = []
    private var displayBoundary = 0
    private var experimentID: UUID?
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private let formatter: DateFormatter
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?
    let logFileURL: URL?

    init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var fileURL: URL?
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fileURL = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
            guard let url = fileURL, FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw LabError.message("无法创建诊断日志文件")
            }
            fileHandle = try FileHandle(forWritingTo: url)
        } catch {
            storageWarning = "诊断日志无法写入磁盘，当前仅保留内存记录。"
        }
        logFileURL = fileURL
    }

    deinit { try? fileHandle?.close() }

    @discardableResult func log(_ category: String, _ message: String, explicitExperimentID: UUID? = nil) -> DiagnosticEntry {
        lock.lock()
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let entry = DiagnosticEntry(id: UUID(), sequence: records.count, date: date,
            localTime: formatter.string(from: date), uptime: uptime, elapsed: uptime - startedUptime,
            category: category, message: message, experimentID: explicitExperimentID ?? experimentID)
        records.append(entry)
        var failed = false
        if let fileHandle {
            do {
                var data = try encoder.encode(entry)
                data.append(0x0A)
                try fileHandle.write(contentsOf: data)
            } catch { failed = true }
        }
        lock.unlock()
        let writeFailed = failed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revision += 1
            if writeFailed { self.storageWarning = "诊断日志写入失败，当前记录仍保留在内存中。" }
        }
        return entry
    }

    var nextSequence: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }
    func setExperimentID(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        experimentID = id
    }
    func entries(since sequence: Int = 0) -> [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.dropFirst(max(0, sequence)))
    }
    var visibleEntries: [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.dropFirst(displayBoundary))
    }
    var text: String { visibleEntries.map(\.line).joined(separator: "\n") }

    func clearDisplay() {
        lock.lock()
        displayBoundary = records.count
        lock.unlock()
        log("诊断", "已清空当前页面日志；本次实验的完整审计记录仍保留。")
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        do { try fileHandle?.synchronize() }
        catch { DispatchQueue.main.async { [weak self] in self?.storageWarning = "日志同步到磁盘失败。" } }
    }
}
