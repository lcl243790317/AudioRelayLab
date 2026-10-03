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
        _result = State(initialValue: experiment.result == .unknown ? .uncertain : experiment.result)
        _notes = State(initialValue: experiment.notes)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("实验配置") {
                    Text(experiment.audio.fileName)
                    Text("\(experiment.settings.engine.rawValue) · \(experiment.settings.profile.historyTitle)")
                    Text("延迟 \(experiment.settings.delay, specifier: "%.1f") 秒 · 初始音量 \(Int(experiment.settings.volume * 100))%")
                    Text(experiment.settings.requestedDuration.map { "请求播放 \(String(format: "%.1f", $0)) 秒" } ?? "播放完整文件")
                    Text("源起点 \(AudioPlaybackSettings.time(experiment.settings.startOffset)) → \(AudioPlaybackSettings.time(experiment.settings.endOffset ?? experiment.audio.duration)) · \(String(format:"%gx",experiment.settings.playbackRate)) · 预计播放 \(AudioPlaybackSettings.time(AudioPlaybackSettings(startOffset:experiment.settings.startOffset,playbackRate:experiment.settings.playbackRate,endOffset:experiment.settings.endOffset).estimatedDuration(duration:experiment.audio.duration,sourceLimit:experiment.settings.requestedDuration)))")
                    Text("最终状态：\(experiment.finalState.title)")
                    Text("\(experiment.device.modelIdentifier) · iOS \(experiment.device.systemVersion)").font(.caption)
                }
                Section("实验后的人工判断") {
                    Picker("实验结果", selection: $result) {
                        ForEach(ExperimentResult.selectableCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                    Text("失败和不确定都是有效实验结果。请根据真实观察填写；未检查时可暂时不保存人工判断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("备注") { TextEditor(text: $notes).frame(minHeight: 120).accessibilityLabel("实验备注") }
                if !experiment.sessionSnapshots.isEmpty {
                    Section("音频会话快照") {
                        ForEach(Array(experiment.sessionSnapshots.enumerated()), id: \.offset) { item in
                            DisclosureGroup(item.element.date.formatted(date: .numeric, time: .standard)) {
                                Text(item.element.summary).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !experiment.errorDetails.isEmpty {
                    Section("技术详情") {
                        ForEach(Array(experiment.errorDetails.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                if !experiment.migrationWarnings.isEmpty {
                    Section("旧历史兼容提示") {
                        ForEach(experiment.migrationWarnings, id: \.self) { Text($0).font(.caption) }
                    }
                }
            }
            .navigationTitle("保存实验结果")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(result, notes); dismiss() } }
            }
        }
    }
}
