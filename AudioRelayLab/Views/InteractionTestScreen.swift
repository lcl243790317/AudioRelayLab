import SwiftUI
#if DEBUG
/// Debug-only harness uses the same production selection and keyboard controls.
struct InteractionTestScreen: View {
    @State private var text = ""
    @State private var selected = 0
    @State private var tick = 0
    @State private var expanded = false
    private let timer = Timer.publish(every:0.25,on:.main,in:.common).autoconnect()
    var body:some View {
        NavigationStack {
            PaperScreen {
                TextEditor(text:$text).frame(height:140).accessibilityIdentifier("interaction.text")
                StablePicker(title:"背景音乐",selection:$selected,
                    choices:(0..<(expanded ? 600 : 500)).map { .init(id:$0,title:String(format:"音乐 %03d",$0)) })
                Text("已选择 \(selected)").accessibilityIdentifier("interaction.selection")
            }.keyboardDone().navigationTitle("交互验证")
        }.onReceive(timer) { _ in tick += 1; expanded = tick.isMultiple(of:2) }
    }
}
#endif
