import SwiftUI

struct ExperimentResultView: View {
    let experiment: Experiment
    let onSave: (ExperimentResult, String) -> Void
    @State private var result: ExperimentResult
    @State private var notes: String
    @Environment(\.dismiss) private var dismiss
    init(experiment: Experiment, onSave: @escaping (ExperimentResult, String) -> Void) {
        self.experiment = experiment
        self.onSave = onSave
        _result = State(initialValue: experiment.result)
        _notes = State(initialValue: experiment.notes)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("实验配置") {
                    Text(experiment.audio.fileName)
                    Text("\(experiment.settings.engine.rawValue) · \(experiment.settings.profile.title)")
                    Text("延迟 \(experiment.settings.delay, specifier: "%.1f") 秒 · 初始音量 \(Int(experiment.settings.volume * 100))%")
                    Text("\(experiment.device.modelIdentifier) · iOS \(experiment.device.systemVersion)").font(.caption)
                }
                Section("听取微信语音后的判断") {
                    Picker("实验结果", selection: $result) {
                        ForEach(ExperimentResult.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                    Text("失败和不确定都是有效实验结果。请根据真实听到的内容填写。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("备注") { TextEditor(text: $notes).frame(minHeight: 120).accessibilityLabel("实验备注") }
            }
            .navigationTitle("保存实验结果")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(result, notes); dismiss() } }
            }
        }
    }
}
