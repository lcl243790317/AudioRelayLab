import SwiftUI

struct HistoryView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var store: ExperimentStore
    @State private var shareItem: ShareItem?
    @State private var editing: Experiment?
    @State private var failure: String?
    init(coordinator: ExperimentCoordinator) { self.coordinator = coordinator; store = coordinator.store }
    var body: some View {
        List {
            Section("导出全部历史") {
                Button("导出 JSON") { exportJSON() }.disabled(store.experiments.isEmpty)
                Button("导出 CSV") { exportCSV() }.disabled(store.experiments.isEmpty)
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
                    Text("\(experiment.settings.profile.rawValue) · \(experiment.settings.engine.rawValue) · \(experiment.settings.delay, specifier: "%.1f") 秒 · \(Int(experiment.settings.volume * 100))%")
                        .font(.caption)
                    Text(experiment.resultReviewed ? experiment.result.title : "诊断草稿：尚未填写真机结果")
                    Text(experiment.finalState.title).font(.caption).foregroundStyle(.secondary)
                    if !experiment.notes.isEmpty { Text(experiment.notes).font(.caption) }
                    Button("查看并填写结果") { editing = experiment }
                    NavigationLink("查看实验日志") {
                        List(experiment.logs) { Text($0.line).font(.caption.monospaced()).textSelection(.enabled) }
                            .navigationTitle("实验日志")
                    }
                }
            }
        }
        .navigationTitle("实验历史")
        .onAppear { coordinator.checkpoint() }
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
                    updated.logs.append(coordinator.logger.log("历史结果更新", "实验=\(experiment.id)，结果=\(result.title)，备注=\(notes)"))
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
        failure = "历史操作失败，请检查存储空间并查看诊断日志。"
    }
}
