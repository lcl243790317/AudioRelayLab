import SwiftUI

struct RevoiceRecentTasks:View {
    @ObservedObject var ai:RevoiceController
    var body:some View {
        if !ai.recentJobs.isEmpty {
            PaperCard {
                DisclosureGroup("最近任务（\(ai.recentJobs.count)）") {
                    ForEach(Array(ai.recentJobs.prefix(8))) { job in
                        VStack(alignment:.leading,spacing:8) {
                            Text(job.context.voiceName).font(.headline)
                            Text(job.context.text).font(.callout).lineLimit(3)
                            PaperCaption(job.readableStatus)
                            if let kind = job.failureKind { Text(kind.message).font(.caption).foregroundStyle(.orange) }
                            if job.canRetrieve {
                                Button(job.submissionRejected == true ? "重试这份固定内容" : "继续取回这份配音") { ai.retrieve(job.id) }
                                    .disabled(ai.cloudStage != .idle || ai.connecting)
                                    .accessibilityIdentifier("revoice.recent.retrieve.\(job.id.uuidString)")
                                PaperCaption("取回窗口截止：\(job.expiresAt.formatted(date:.abbreviated,time:.shortened))。沿用原任务编号和固定内容。")
                            } else if job.phase == .completed { PaperCaption("可在音频库查看成品。") }
                        }.padding(.vertical,8)
                        Divider()
                    }
                    PaperCaption("停止等待只停止取回，云端可能继续。停止后的任务须手动继续取回，迟到结果不会自动保存。")
                }.accessibilityIdentifier("revoice.recent.tasks")
            }
        }
    }
}
