import SwiftUI
#if DEBUG
/// Debug-only harness uses the same production selection and keyboard controls.
struct InteractionTestScreen: View {
    @State private var text = ""
    private enum Field:Hashable { case text,connection,key,number,notes }
    @FocusState private var editing:Field?
    @State private var connection = ""
    @State private var key = ""
    @State private var number = 0.0
    @State private var notes = ""
    @State private var clicks = 0
    @State private var selected = 0
    @State private var tick = 0
    @State private var expanded = false
    private let timer = Timer.publish(every:0.25,on:.main,in:.common).autoconnect()
    var body:some View {
        NavigationStack {
            PaperScreen {
                TextEditor(text:$text).scrollDismissesKeyboard(.never).focused($editing,equals:.text).frame(height:100).accessibilityIdentifier("interaction.text")
                Button("点击一次") { clicks += 1 }.accessibilityIdentifier("interaction.once")
                Text("点击次数 \(clicks)").accessibilityIdentifier("interaction.clicks")
                StablePicker(title:"背景音乐",selection:$selected,
                    choices:(0..<(expanded ? 600 : 500)).map { .init(id:$0,title:String(format:"音乐 %03d",$0)) })
                Text("已选择 \(selected)").accessibilityIdentifier("interaction.selection")
                TextField("连接地址",text:$connection).focused($editing,equals:.connection).frame(minHeight:44).accessibilityIdentifier("interaction.connection")
                SecureField("密钥",text:$key).focused($editing,equals:.key).frame(minHeight:44).accessibilityIdentifier("interaction.key")
                TextField("数值",value:$number,format:.number).keyboardType(.decimalPad).focused($editing,equals:.number).frame(minHeight:44).accessibilityIdentifier("interaction.number")
                TextEditor(text:$notes).scrollDismissesKeyboard(.never).focused($editing,equals:.notes).frame(height:100).accessibilityIdentifier("interaction.notes")
                Text("点这里收起键盘").frame(minHeight:44).accessibilityIdentifier("interaction.outside")
            }.keyboardDone { editing = nil }.navigationTitle("交互验证")
                .toolbar { NavigationLink("离开输入页") { Text("输入页已离开") } }
        }.buttonStyle(PaperButtonStyle()).onReceive(timer) { _ in tick += 1; expanded = tick.isMultiple(of:2) }
    }
}
#endif
