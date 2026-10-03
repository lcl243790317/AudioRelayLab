import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var logger: DiagnosticsLogger
    @ObservedObject var session: AudioSessionManager
    @ObservedObject var store: ExperimentStore
    @State private var shareItem: ShareItem?
    @State private var feedback: String?
    @State private var confirmClear = false

    init(coordinator: ExperimentCoordinator) {
        self.coordinator = coordinator
        logger = coordinator.logger
        session = coordinator.session
        store = coordinator.store
    }

    var body: some View {
        List {
            Section("音频环境") {
                Text(session.availabilityMessage).font(.headline)
                if let message = session.interruptionMessage {
                    Label(message, systemImage: "waveform.slash").foregroundStyle(.orange)
                }
                Text("这里只观察系统公开状态，不能可靠判断哪个 App 正在录音或通话。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("音频会话与当前路由") {
                Text(session.snapshot.summary).font(.caption.monospaced()).textSelection(.enabled)
                Button("刷新快照") { session.capture("用户刷新诊断"); coordinator.refresh() }
                Text("允许蓝牙 HFP 与实际使用 HFP 是两项不同状态，以 currentRoute 的端口类型为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("可用输入") {
                if session.snapshot.availableInputs.isEmpty {
                    Text("系统当前没有提供可用输入列表。A / E 不启用录音输入，空列表不能证明其他 App 无法录音。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.snapshot.availableInputs.enumerated()), id: \.offset) { _, port in
                        Text(port.summary).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("播放器与引擎状态") {
                LabeledContent("当前实验", value: coordinator.state.title)
                Text(coordinator.diagnosticState).font(.caption.monospaced()).textSelection(.enabled)
                Text("可观察播放开始来自前台采样，不能作为声学测量。无法直接确认实际扬声器起始时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let details = coordinator.technicalDetails {
                Section("最近技术错误") {
                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("麦克风能力诊断") { Text(session.microphoneInjectionDiagnostic).font(.caption) }
            Section("日志操作") {
                Button("复制显示日志") { UIPasteboard.general.string = logger.text; feedback = "显示日志已复制" }
                Button("导出 TXT 日志") { exportLog(asJSON: false) }
                Button("导出 JSON 日志") { exportLog(asJSON: true) }
                Button("清空日志页面", role: .destructive) { confirmClear = true }
                Text("导出当前页面可见日志；系统分享菜单可保存到文件。清空页面只改变显示边界，实验审计日志仍保存在历史中。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("自动诊断避免设备 UID、私人设备名称及文件路径。人工备注和原有历史可能含你填写的内容，分享前可检查导出。")
                    .font(.caption).foregroundStyle(.secondary)
                if let feedback { Text(feedback).font(.caption) }
                if let warning = logger.storageWarning { Text(warning).foregroundStyle(.orange) }
                if let warning = store.storageError { Text(warning).foregroundStyle(.orange) }
            }
            Section("显示日志（\(logger.visibleEntries.count) 条）") {
                ForEach(logger.visibleEntries) { entry in
                    Text(entry.line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .paperList().navigationTitle("诊断与日志")
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .confirmationDialog("清空页面中的日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空页面", role: .destructive) { logger.clearDisplay(); feedback = "已清空显示，实验审计记录仍保留。" }
        }
    }

    private func exportLog(asJSON: Bool) {
        do {
            logger.flush()
            let url: URL
            if asJSON { url = try ExportManager.jsonLogFile(entries: logger.visibleEntries) }
            else { url = try ExportManager.logFile(text: logger.text) }
            shareItem = ShareItem(url: url)
            feedback = asJSON ? "JSON 日志已生成" : "TXT 日志已生成"
        } catch {
            logger.log("日志导出失败", diagnosticError(error))
            feedback = "日志导出失败，请检查存储空间后重试。"
        }
    }
}
