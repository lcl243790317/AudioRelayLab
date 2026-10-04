import SwiftUI

struct VoiceMixView:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var mix:VoiceMixController
    @ObservedObject var volumes:MixVolumeSettings
    init(coordinator:ExperimentCoordinator) {
        self.coordinator = coordinator; mix = coordinator.voiceMix; volumes = coordinator.mixVolumes
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            PaperCard("加入背景音乐") {
                StablePicker(title:"人声",selection:$mix.voiceID,
                    choices:[.init(id:nil,title:"请选择录音或配音")] + VoiceMixController.voices(in:coordinator.library)
                        .map { .init(id:Optional($0.id),title:$0.libraryName) })
                    .accessibilityIdentifier("mix.voice")
                StablePicker(title:"背景音乐",selection:$mix.musicID,
                    choices:[.init(id:nil,title:"请选择音乐")] + VoiceMixController.music(in:coordinator.library)
                        .map { .init(id:Optional($0.id),title:$0.libraryName) })
                    .accessibilityIdentifier("mix.music")
                if VoiceMixController.voices(in:coordinator.library).isEmpty {
                    PaperCaption("先录一段原声或生成配音，之后随时可以在这里混音。")
                }
                Divider()
                MixVolumeControl(title:"人声",value:$volumes.voice)
                MixVolumeControl(title:"音乐",value:$volumes.music)
                PaperCaption("保留完整人声；音乐从头播放，默认音量 4%。")
                if let music = coordinator.library.first(where:{$0.id == mix.musicID}) {
                    DisclosureGroup("音乐片段与速度") {
                        MusicMixOptions(settings:$mix.settings,duration:music.duration)
                        MixVolumeControl(title:"总音量",value:$volumes.master)
                    }
                }
                Button(mix.busy ? "保存中…" : "保存混音") { KeyboardDismiss.perform(); mix.generate(coordinator:coordinator) }
                    .buttonStyle(PaperButtonStyle(primary:true))
                    .disabled(coordinator.controlsLocked || mix.voiceID == nil || mix.musicID == nil)
                    .accessibilityIdentifier("mix.save")
            }.disabled(coordinator.controlsLocked)
            if mix.busy { ProgressView(mix.status) } else { PaperCaption(mix.status) }
            if let error = mix.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            if let result = mix.result { RevoiceResultTools(coordinator:coordinator,result:result,title:"混音成品") }
        }
    }
}

private struct MixVolumeControl:View {
    let title:String
    @Binding var value:Float
    private func bounded(_ value:Float) -> Float { value.isFinite ? min(1,max(0,value)) : 0 }
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            Text("\(title) \(Int(bounded(value)*100))%").font(.subheadline)
            Slider(value:Binding(get:{Double(bounded(value))},set:{value = bounded(Float($0))}),in:0...1)
                .accessibilityLabel(title+"音量")
        }
    }
}

private struct MusicMixOptions:View {
    @Binding var settings:AudioPlaybackSettings
    let duration:Double
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            StablePicker(title:"音乐速度",selection:$settings.playbackRate,
                choices:AudioPlaybackSettings.rates.map { .init(id:$0,title:String(format:"%.2gx",$0)) })
            Text("开始 \(AudioPlaybackSettings.time(settings.startOffset))").font(.caption)
            Slider(value:$settings.startOffset,in:0...max(0,duration-0.01))
                .onChange(of:settings.startOffset) { _,start in
                    if let end = settings.endOffset,end <= start { settings.endOffset = nil }
                }.accessibilityLabel("音乐开始位置")
            Text("结束 \(AudioPlaybackSettings.time(settings.endPosition(duration:duration)))").font(.caption)
            Slider(value:Binding(get:{settings.endPosition(duration:duration)},set:{settings.endOffset = $0}),
                in:min(duration,settings.startOffset+0.01)...duration).accessibilityLabel("音乐结束位置")
            Button("恢复从头播放") { settings = .init() }
        }
    }
}
