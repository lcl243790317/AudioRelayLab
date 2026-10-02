import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var logger: DiagnosticsLogger
    @ObservedObject var session: AudioSessionManager
    @ObservedObject var store: ExperimentStore
    @State private var shareItem: ShareItem?
    @State private var feedback: String?
    init(coordinator: ExperimentCoordinator) {
        self.coordinator = coordinator
        logger = coordinator.logger
        session = coordinator.session
        store = coordinator.store
    }
    var body: some View {
        List {
            Section("音频会话与当前路由") {
                Text(session.snapshot.summary).font(.caption.monospaced()).textSelection(.enabled)
                Button("刷新快照") { session.capture("用户刷新诊断"); coordinator.refresh() }
                if session.snapshot.currentRoute.usesExternalDevice {
                    Text("当前实验建议使用 iPhone 自带扬声器和麦克风。").foregroundStyle(.orange)
                }
            }
            Section("播放器与引擎状态") {
                Text(coordinator.diagnosticState).font(.caption.monospaced()).textSelection(.enabled)
                Text("可观察播放开始来自前台采样，不能作为声学测量。无法直接确认实际扬声器起始时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("麦克风注入诊断") { Text(session.microphoneInjectionDiagnostic).font(.caption) }
            Section("日志操作") {
                Button("复制日志") { UIPasteboard.general.string = logger.text; feedback = "日志已复制" }
                Button("清空日志") { logger.clearDisplay() }
                Button("导出日志") { exportLog() }
                Button("分享日志") { exportLog() }
                Text("导出后可在系统分享菜单中保存到文件。清空页面不会移除实验审计记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if let feedback { Text(feedback).font(.caption) }
                if let warning = logger.storageWarning { Text(warning).foregroundStyle(.orange) }
                if let warning = store.storageError { Text(warning).foregroundStyle(.orange) }
            }
            Section("完整日志（\(logger.visibleEntries.count) 条）") {
                ForEach(logger.visibleEntries) { entry in
                    Text(entry.line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("诊断")
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
    }
    private func exportLog() {
        do { logger.flush(); shareItem = ShareItem(url: try ExportManager.logFile(text: logger.text)) }
        catch { logger.log("日志导出失败", diagnosticError(error)); feedback = "日志导出失败，请检查存储空间。" }
    }
}
