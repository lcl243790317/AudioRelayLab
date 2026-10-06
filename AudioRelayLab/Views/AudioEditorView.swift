import SwiftUI

struct AudioEditorView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var preview: PreviewPlaybackController
    @State private var adjustingEnd = false
    init(coordinator: ExperimentCoordinator) { self.coordinator = coordinator; preview = coordinator.preview }
    private var duration: Double { max(0.001, coordinator.audio?.duration ?? 0.001) }
    private var offset: Binding<Double> {
        Binding(get: { AudioPlaybackSettings.clamp(coordinator.editing.startOffset, duration: duration) },
                set: { preview.stop(); coordinator.editing.startOffset = AudioRangeSelection.start($0,end:end.wrappedValue,duration:duration) })
    }
    private var end: Binding<Double> {
        Binding(get: { AudioPlaybackSettings.clamp(coordinator.editing.endPosition(duration:duration),duration:duration) },
                set: {
                    preview.stop()
                    let value = AudioRangeSelection.end($0,start:offset.wrappedValue,duration:duration)
                    coordinator.editing.endOffset = value >= duration ? nil : value
                })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            LabeledContent("总时长", value: AudioPlaybackSettings.time(duration))
            AudioRangeSlider(start:offset,end:end,duration:duration)
            LabeledContent("编辑开始位置", value: AudioPlaybackSettings.time(coordinator.editing.startOffset))
            LabeledContent("编辑结束位置", value: AudioPlaybackSettings.time(end.wrappedValue))
            PaperCaption("拖动左圆点设置起点，右圆点设置终点；播放与 AI 使用已应用的区间。")
            DisclosureGroup("微调起止位置") {
              Picker("调整位置",selection:$adjustingEnd) { Text("起点").tag(false); Text("终点").tag(true) }.pickerStyle(.segmented)
              LazyVGrid(columns:[GridItem(.adaptive(minimum:100))],spacing:8) {
                ForEach([-1.0, -0.1, 0.1, 1], id: \.self) { step in
                    Button(String(format: "%+.1fs", step)) {
                        if adjustingEnd { end.wrappedValue += step } else { offset.wrappedValue += step }
                    }
                        .buttonStyle(PaperButtonStyle()).font(.caption)
                }
            }
            Button("恢复完整音频区间") { preview.stop(); coordinator.editing.startOffset=0; coordinator.editing.endOffset=nil }
            }
            StablePicker(title:"播放速度",selection:$coordinator.editing.playbackRate,
                choices:AudioPlaybackSettings.rates.map { .init(id:$0,title:String(format:"%gx",$0)) }).onChange(of: coordinator.editing.playbackRate) { _, _ in preview.stop() }
            DisclosureGroup("试听音量与时长") {
            Slider(value: Binding(get: { coordinator.editing.volume.isFinite ? Double(min(1,max(0,coordinator.editing.volume))) : 0 }, set: { coordinator.editing.volume = Float($0) }), in: 0...1)
            LabeledContent("试听/待应用音量", value: coordinator.editing.volume.isFinite ? "\(Int(min(1,max(0,coordinator.editing.volume)) * 100))%" : "不可用")
            LabeledContent("所选片段时长", value: AudioPlaybackSettings.time(coordinator.editing.remaining(duration: duration)))
            LabeledContent("预计播放时间", value: AudioPlaybackSettings.time(coordinator.editing.estimatedDuration(duration: duration)))
            }
            HStack {
                Button("从这里试听") { coordinator.audition() }.buttonStyle(PaperButtonStyle())
                Button("▶ 试听 5 秒") { coordinator.audition(fiveSeconds: true) }.buttonStyle(PaperButtonStyle())
            }
            Button("■ 停止试听") { preview.stop() }.disabled(!preview.isActive)
            LabeledContent("试听进度", value: AudioPlaybackSettings.time(preview.currentTime))
            if let error = preview.errorMessage { Text(error).foregroundStyle(.orange) }
            Button("应用这个播放设置") { coordinator.applyPlaybackSettings() }.buttonStyle(PaperButtonStyle(primary:true))
            Text(coordinator.editing == coordinator.applied ? "当前设置已应用。" : "有未应用的调整，试听满意后点击应用。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(coordinator.controlsLocked || coordinator.audio == nil)
    }
}
