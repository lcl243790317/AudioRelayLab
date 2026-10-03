import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var store: ExperimentStore
    @State private var shareItem: ShareItem?
    @State private var editing: Experiment?
    @State private var failure: String?
    @State private var importing = false
    @State private var importSummary: String?
    init(coordinator: ExperimentCoordinator) { self.coordinator = coordinator; store = coordinator.store }
    var body: some View {
        List {
            Section("导入与导出历史") {
                Button("导入历史 JSON") { importing = true }
                Button("导出 JSON") { exportJSON() }.disabled(store.experiments.isEmpty)
                Button("导出 CSV") { exportCSV() }.disabled(store.experiments.isEmpty)
                Text("导入保留已有相同编号的记录。历史只包含实验资料，不包含原音频文件。备注由你填写，分享前请检查是否包含个人信息。")
                    .font(.caption).foregroundStyle(.secondary)
                if let importSummary { Text(importSummary).font(.caption) }
                if let warning = store.storageError { Text(warning).foregroundStyle(.orange) }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }
            if store.experiments.isEmpty {
                Section { Text("尚无实验历史。开始实验后会自动保存诊断草稿，返回后可填写结果。") }
            }
            ForEach(store.experiments) { experiment in
                Section {
                    Text(experiment.date.formatted(date: .numeric, time: .standard)).font(.headline)
                    Text(experiment.audio.fileName)
                    Text("\(experiment.settings.profile.historyTitle) · \(experiment.settings.engine.rawValue) · \(experiment.settings.delay, specifier: "%.1f") 秒 · \(Int(experiment.settings.volume * 100))%")
                        .font(.caption)
                    Text(experiment.resultReviewed ? experiment.result.title : "诊断草稿：尚未填写真机结果")
                    Text(experiment.finalState.title).font(.caption).foregroundStyle(.secondary)
                    if !experiment.notes.isEmpty { Text(experiment.notes).font(.caption) }
                    if !experiment.migrationWarnings.isEmpty {
                        Text("部分旧版字段已兼容恢复，可在结果详情中查看。").font(.caption).foregroundStyle(.orange)
                    }
                    Button("查看并填写结果") { editing = experiment }
                    NavigationLink("查看实验日志") {
                        List(experiment.logs) { Text($0.line).font(.caption.monospaced()).textSelection(.enabled) }
                            .navigationTitle("实验日志")
                    }
                    if !experiment.errorDetails.isEmpty {
                        NavigationLink("查看技术详情") {
                            List(Array(experiment.errorDetails.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
                            }.navigationTitle("技术详情")
                        }
                    }
                }
            }
        }
        .navigationTitle("实验历史")
        .onAppear { coordinator.checkpoint() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let source = urls.first else { return }
                coordinator.checkpoint()
                do {
                    importSummary = try store.importFile(from: source).message
                    failure = nil
                } catch { fail(error) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { fail(error) }
            }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .sheet(item: $editing) { experiment in
            ExperimentResultView(experiment: experiment) { result, notes in
                if coordinator.currentExperiment?.id == experiment.id {
                    coordinator.saveResult(result: result, notes: notes)
                } else {
                    var updated = experiment
                    updated.result = result
                    updated.resultReviewed = true
                    updated.notes = notes
                    updated.logs.append(coordinator.logger.log("历史结果更新", "实验=\(experiment.id)，结果=\(result.title)，备注字数=\(notes.count)",
                        explicitExperimentID: experiment.id))
                    do { try store.save(updated) }
                    catch { fail(error) }
                }
            }
        }
    }
    private func exportJSON() {
        coordinator.checkpoint()
        do { shareItem = ShareItem(url: try ExportManager.jsonFile(experiments: store.experiments)) }
        catch { fail(error) }
    }
    private func exportCSV() {
        coordinator.checkpoint()
        do { shareItem = ShareItem(url: try ExportManager.csvFile(experiments: store.experiments)) }
        catch { fail(error) }
    }
    private func fail(_ error: Error) {
        coordinator.logger.log("历史操作失败", diagnosticError(error))
        failure = "历史操作失败。请确认文件是本 App 导出的有效 JSON、大小不超过 32 MB，并检查存储空间；详情见诊断日志。"
    }
}
