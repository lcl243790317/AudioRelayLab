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
                StablePicker(title:"背景音乐",selection:$mix.musicID,
                    choices:[.init(id:nil,title:"请选择音乐")] + VoiceMixController.music(in:coordinator.library)
                        .map { .init(id:Optional($0.id),title:$0.libraryName) })
                if VoiceMixController.voices(in:coordinator.library).isEmpty {
                    PaperCaption("先录一段原声或生成配音，之后随时可以在这里混音。")
                }
                PaperCaption("保留完整人声；音乐默认音量 4%。")
                if let music = coordinator.library.first(where:{$0.id == mix.musicID}) {
                    if let voice = coordinator.library.first(where:{$0.id == mix.voiceID}) {
                        MusicMixTimingOptions(timing:$mix.timing,voiceDuration:voice.duration,
                            musicDuration:mix.settings.estimatedDuration(duration:music.duration))
                    }
                    DisclosureGroup("音乐片段与速度") {
                        MusicMixOptions(settings:$mix.settings,duration:music.duration)
                    }
                }
                DisclosureGroup("音量设置") {
                    MixVolumeControl(title:"人声",value:$volumes.voice)
                    MixVolumeControl(title:"音乐",value:$volumes.music)
                    MixVolumeControl(title:"总音量",value:$volumes.master)
                }
                Button(mix.busy ? "保存中…" : "保存混音") { KeyboardDismiss.perform(); mix.generate(coordinator:coordinator) }
                    .buttonStyle(PaperButtonStyle(primary:true))
                    .disabled(coordinator.controlsLocked || mix.voiceID == nil || mix.musicID == nil)
                    .accessibilityIdentifier("mix.save")
            }.disabled(coordinator.controlsLocked)
            if mix.busy { ProgressView(mix.status) } else { PaperCaption(mix.status) }
            if let error = mix.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            if let result = mix.result { RevoiceResultTools(coordinator:coordinator,result:result,title:"混音成品") }
        }.keyboardDone()
    }
}

struct MusicMixTimingOptions:View {
    private enum Order:String,Hashable { case together, musicFirst, voiceFirst }
    @Binding var timing:AudioMixTiming
    let voiceDuration:Double
    let musicDuration:Double
    @State private var order:Order
    @FocusState private var editing:Bool
    init(timing:Binding<AudioMixTiming>,voiceDuration:Double,musicDuration:Double) {
        _timing = timing; self.voiceDuration = voiceDuration; self.musicDuration = musicDuration
        _order = State(initialValue:timing.wrappedValue.voiceStartDelay > 0 ? .musicFirst : (timing.wrappedValue.musicStartDelay > 0 ? .voiceFirst : .together))
    }
    private var outputDuration:Double { timing.voiceStartDelay + voiceDuration + timing.musicTailDuration }
    private var latestStart:Double { order == .musicFirst ? max(0,min(60,musicDuration)) : max(0,voiceDuration+timing.musicTailDuration-0.1) }
    private var delay:Binding<Double> {
        Binding(get:{ order == .musicFirst ? timing.voiceStartDelay : timing.musicStartDelay },set:{ value in
            if order == .musicFirst { timing.voiceStartDelay = value; timing.musicStartDelay = 0 }
            else { timing.musicStartDelay = value; timing.voiceStartDelay = 0 }
        })
    }
    private func clampDelay() {
        let value = delay.wrappedValue
        delay.wrappedValue = value.isFinite ? min(latestStart,max(0,value)) : 0
    }
    private func seconds(_ value:Double) -> String { String(format:"%.1f",value) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            StablePicker(title:"起播顺序",selection:$order,choices:[
                .init(id:.together,title:"同时开始"),.init(id:.musicFirst,title:"音乐先播"),.init(id:.voiceFirst,title:"人声先播")])
            if order != .together {
                Text(order == .musicFirst ? "音乐先播放，再加入人声" : "人声先播放，再加入音乐").font(.subheadline)
                HStack {
                    Text("间隔秒数")
                    TextField("秒",value:delay,format:.number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).focused($editing).multilineTextAlignment(.trailing)
                        .frame(minHeight:44)
                        .onSubmit { clampDelay(); editing = false }
                        .accessibilityIdentifier("mix.startDelay.seconds")
                    Text("秒").foregroundStyle(PaperTheme.secondary)
                }.padding(12).background(PaperTheme.mist.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                Slider(value:Binding(get:{min(latestStart,max(0,delay.wrappedValue.isFinite ? delay.wrappedValue : 0))},set:{delay.wrappedValue = min(latestStart,$0)}),in:0...max(0.1,latestStart),step:0.1)
                    .accessibilityLabel(order == .musicFirst ? "人声加入时间" : "背景音乐加入时间")
                    .accessibilityIdentifier(order == .musicFirst ? "mix.voiceStartDelay" : "mix.musicStartDelay")
            }
            Text("人声结束后保留 \(seconds(timing.musicTailDuration)) 秒音乐尾声").font(.subheadline)
            Slider(value:$timing.musicTailDuration,in:0...AudioMixTiming.maximumTailSeconds,step:0.5)
                .onChange(of:timing.musicTailDuration) { _,_ in
                    clampDelay()
                }.accessibilityLabel("背景音乐尾声时长").accessibilityIdentifier("mix.musicTailDuration")
            PaperCaption("人声从第 \(seconds(timing.voiceStartDelay)) 秒开始，音乐从第 \(seconds(timing.musicStartDelay)) 秒开始；成品总长 \(seconds(outputDuration)) 秒。间隔按实际播放时间计算。")
            if timing.musicStartDelay + musicDuration < outputDuration {
                PaperCaption("所选音乐将在成品第 \(seconds(timing.musicStartDelay+musicDuration)) 秒播完，不自动循环；之后仅保留人声，未覆盖的尾声为静音。可延长音乐片段或缩短尾声。")
            }
        }
        .onChange(of:order) { _,_ in timing.voiceStartDelay = 0; timing.musicStartDelay = 0; editing = false }
        .onChange(of:voiceDuration) { _,_ in clampDelay() }
        .onChange(of:musicDuration) { _,_ in clampDelay() }
        .onChange(of:editing) { _,value in if !value { clampDelay() } }
        .onDisappear { editing = false }
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
            Text("片段起点 \(AudioPlaybackSettings.time(settings.startOffset))").font(.caption)
            Slider(value:$settings.startOffset,in:0...max(0,duration-0.01))
                .onChange(of:settings.startOffset) { _,start in
                    if let end = settings.endOffset,end <= start { settings.endOffset = nil }
                }.accessibilityLabel("音乐开始位置")
            Text("片段终点 \(AudioPlaybackSettings.time(settings.endPosition(duration:duration)))").font(.caption)
            Slider(value:Binding(get:{settings.endPosition(duration:duration)},set:{settings.endOffset = $0}),
                in:min(duration,settings.startOffset+0.01)...duration).accessibilityLabel("音乐结束位置")
            Button("恢复从头播放") { settings = .init() }
        }
    }
}
