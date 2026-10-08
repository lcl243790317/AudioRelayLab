import SwiftUI

struct RevoiceRecognitionRangeView:View {
    @ObservedObject var ai:RevoiceController
    let asset:AudioAsset
    @Environment(\.dismiss) private var dismiss
    @State private var start:Double
    @State private var end:Double
    @State private var error:String?
    @FocusState private var editing:Bool
    init(ai:RevoiceController,asset:AudioAsset) {
        self.ai = ai; self.asset = asset
        _start = State(initialValue:ai.recognitionRange?.start ?? 0)
        _end = State(initialValue:ai.recognitionRange?.end ?? min(60,asset.duration))
    }
    var body:some View {
        NavigationStack {
            PaperScreen {
                PaperCard("识别片段") {
                    Text(asset.libraryName).font(.headline)
                    LabeledContent("完整时长",value:AudioPlaybackSettings.time(asset.duration))
                    PaperCaption("只在手机识别你确认的 0.3～60 秒片段。不会修改原音频、播放页设置或音乐片段。")
                    if asset.duration >= 0.3,asset.duration.isFinite {
                        AudioRangeSlider(start:Binding(get:{bounded(start)},set:{start = $0}),
                            end:Binding(get:{bounded(end)},set:{end = $0}),duration:asset.duration)
                    }
                    rangeField("开始位置（秒）",value:$start,id:"revoice.range.start")
                    rangeField("结束位置（秒）",value:$end,id:"revoice.range.end")
                    LabeledContent("预计识别时长",value:String(format:"%.3f 秒",max(0,end-start)))
                        .accessibilityIdentifier("revoice.range.duration")
                    if asset.duration <= 60 {
                        Button("使用完整音频") { start = 0; end = asset.duration }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("确认识别片段") {
                        editing = false; KeyboardDismiss.perform()
                        guard ai.input?.id == asset.id else { error = "输入音频已变化，请重新打开识别片段"; return }
                        do {
                            let range = RevoiceRecognitionRange(start:start,end:end)
                            try range.validate(duration:asset.duration)
                            ai.setRecognitionRange(range); dismiss()
                        } catch { self.error = RevoiceError.message(error) }
                    }.buttonStyle(PaperButtonStyle(primary:true)).accessibilityIdentifier("revoice.range.apply")
                }
            }.keyboardDone { editing = false }.navigationTitle("识别片段").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
        }.appSheetAppearance()
    }
    private func bounded(_ value:Double) -> Double { value.isFinite ? min(asset.duration,max(0,value)) : 0 }
    private func rangeField(_ title:String,value:Binding<Double>,id:String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.subheadline)
            TextField(title,value:value,format:.number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad).focused($editing).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(id)
        }
    }
}

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
