import SwiftUI

enum AudioRangeSelection {
    static func minimumSpan(duration: Double) -> Double { min(0.1,max(0,duration)) }
    static func start(_ value: Double, end: Double, duration: Double) -> Double {
        min(max(0,end-minimumSpan(duration:duration)),AudioPlaybackSettings.clamp(value,duration:duration))
    }
    static func end(_ value: Double, start: Double, duration: Double) -> Double {
        max(min(duration,start+minimumSpan(duration:duration)),AudioPlaybackSettings.clamp(value,duration:duration))
    }
}

struct AudioRangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeStart = false
    @State private var activeEnd = false
    var body: some View {
        GeometryReader { geometry in
            let width = max(1,Double(geometry.size.width)-44)
            let lower = 22+width*start/max(duration,0.001)
            let upper = 22+width*end/max(duration,0.001)
            ZStack(alignment:.leading) {
                Capsule().fill(PaperTheme.line).frame(height:6).padding(.horizontal,22)
                Capsule().fill(PaperTheme.accent).frame(width:max(0,upper-lower),height:6).offset(x:lower)
                thumb(isStart:true,width:width).offset(x:lower-22)
                thumb(isStart:false,width:width).offset(x:upper-22)
            }.frame(height:48).coordinateSpace(name:"audio-range-track")
        }.frame(height:48).opacity(enabled ? 1 : 0.4)
    }
    private func thumb(isStart: Bool, width: Double) -> some View {
        let active = isStart ? activeStart : activeEnd
        return Circle().fill(PaperTheme.paper)
            .overlay(Circle().stroke(PaperTheme.accent,lineWidth:active ? 4 : 2))
            .frame(width:24,height:24)
            .shadow(color:.black.opacity(0.18),radius:3,y:2)
            .scaleEffect(active && !reduceMotion ? 1.15 : 1)
            .frame(width:44,height:48).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("audio-range-track"))
                .onChanged { value in
                    guard enabled else { return }
                    let seconds=(value.location.x-22)/width*duration
                    if isStart { activeStart=true; start=AudioRangeSelection.start(seconds,end:end,duration:duration) }
                    else { activeEnd=true; end=AudioRangeSelection.end(seconds,start:start,duration:duration) }
                }.onEnded { _ in activeStart=false; activeEnd=false })
            .accessibilityElement().accessibilityLabel(isStart ? "音频开始位置" : "音频结束位置")
            .accessibilityValue(AudioPlaybackSettings.time(isStart ? start : end))
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                let delta = min(1,max(0.01,duration/100))*(direction == .increment ? 1.0 : -1.0)
                if isStart { start=AudioRangeSelection.start(start+delta,end:end,duration:duration) }
                else { end=AudioRangeSelection.end(end+delta,start:start,duration:duration) }
            }
    }
}
