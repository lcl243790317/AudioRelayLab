import SwiftUI
import UniformTypeIdentifiers

private enum RevoiceInputField:Hashable { case text, instruction, automaticInstruction }
private enum RevoiceSheet:String,Identifiable {
    case connection, library
    var id:String { rawValue }
}

struct VoiceRevoiceView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var ai:RevoiceController
    @ObservedObject var voice:RawVoiceRecorder
    let onMix:(AudioAsset)->Void
    @State private var sheet:RevoiceSheet?
    @FocusState private var focusedInput:RevoiceInputField?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var draftLocked:Bool { ai.stage == .recognizing || voice.isActive }
    private var generationLocked:Bool {
        !ai.canGenerateDraft || voice.isActive || coordinator.isImporting || coordinator.isMixing || coordinator.isRunning || coordinator.aiVoice.busy
    }
    private var emptyDraft:Bool { ai.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var generateTitle:String {
        if emptyDraft && ai.input != nil { return "识别文字" }
        return ai.hasPendingJob ? "按当前内容生成新的配音" : "生成配音"
    }

    init(coordinator:ExperimentCoordinator,onMix:@escaping (AudioAsset)->Void) {
        self.coordinator = coordinator; ai = coordinator.revoice; voice = coordinator.rawRecorder
        self.onMix = onMix
    }

    var body:some View {
        PaperScreen {
            PaperCard {
                RevoiceTextComposer(text:$ai.text,focus:$focusedInput,disabled:draftLocked)
                RevoiceInputControls(voice:voice,inputName:ai.input?.libraryName,
                    canRecognizeAgain:!emptyDraft,
                    disabled:coordinator.controlsLocked,libraryEmpty:coordinator.library.isEmpty,
                    record:record,chooseAudio:chooseAudio,recognize:recognize)
            }
            PaperCard("声线与表达") {
                RevoiceModeControl(kind:Binding(get:{ai.kind},set:{ai.requestVoiceSelection(.mode($0),deferConfirmation:typeSize.isAccessibilitySize)}),
                    disabled:draftLocked,onDismiss:ai.presentDeferredVoiceSelection)
                RevoiceVoiceSettings(kind:ai.kind,voices:ai.voices,speakers:ai.speakers,
                    preset:Binding(get:{ai.selectedPreset},set:{ai.requestVoiceSelection(.preset($0),deferConfirmation:true)}),
                    speaker:Binding(get:{ai.selectedSpeaker},set:{ai.requestVoiceSelection(.speaker($0),deferConfirmation:true)}),
                    instruction:ai.kind == .preset ? $ai.presetInstruction : $ai.instruction,
                    editablePreset:ai.canEditPresetInstruction,serviceSupportsPreset:ai.supportsPresetInstruction,
                    automatic:ai.usesAutomaticInstruction && ai.canUseAutomaticInstruction,
                    resetInstruction:ai.resetPresetInstruction,onSelectionDismissed:ai.presentDeferredVoiceSelection,
                    focus:$focusedInput,disabled:draftLocked)
                RevoiceAutomaticInstructionControl(ai:ai,disabled:draftLocked,focus:$focusedInput)
            }
            if let context = ai.pendingContext {
                RevoicePendingCard(context:context,status:ai.status,error:ai.errorMessage,busy:ai.busy,
                    resume:resume,stop:stop)
            } else if ai.configured || ai.busy || ai.errorMessage != nil {
                RevoiceStatusNotice(status:ai.status,error:ai.errorMessage,busy:ai.busy,stop:stop)
            }
            if !ai.configured {
                PaperCard {
                    RevoiceConnectionControl(configured:ai.configured,connecting:ai.connecting,
                        importDisabled:ai.busy || ai.hasPendingJob || voice.isActive,
                        reconnectDisabled:ai.connecting || voice.isActive || (ai.busy && !ai.hasPendingJob),
                        open:openConnection,reconnect:ai.connect)
                    PaperCaption("录音在手机识别，生成配音需要连接云端。")
                }
            }
            if let result = ai.result { RevoiceResultTools(coordinator:coordinator,result:result,onMix:onMix) }
        }
        .safeAreaInset(edge:.bottom,spacing:0) {
            if !voice.isActive {
                Button(generateTitle,action:generate).buttonStyle(PaperButtonStyle(primary:true))
                    .disabled(generationLocked || (emptyDraft && ai.input == nil) || (!emptyDraft && !ai.configured))
                    .accessibilityIdentifier("revoice.generate")
                    .padding(.horizontal,20).padding(.vertical,12).frame(maxWidth:.infinity)
                    .background(PaperTheme.paper)
            }
        }
        .keyboardDone { focusedInput = nil }
        .alert("放弃手动调整的指令？",isPresented:Binding(get:{ai.pendingVoiceSelection != nil},set:{if !$0 { ai.cancelVoiceSelection() }}),presenting:ai.pendingVoiceSelection) { selection in
            Button("取消",role:.cancel) { ai.cancelVoiceSelection() }
            Button("放弃并切换",role:.destructive) { ai.confirmVoiceSelection(selection) }
        } message: { _ in Text("切换后将按新声线重新匹配表达指令。取消会保留当前声线和草稿。") }
        .sheet(item:$sheet) { destination in
            switch destination {
            case .connection: CloudConnectionView(ai:ai)
            case .library: NavigationStack { AudioLibraryPickerView(coordinator:coordinator,onSelect:selectAudio) }
            }
        }
        .task { connectIfNeeded() }
    }

    private func dismissKeyboard() { focusedInput = nil; KeyboardDismiss.perform() }
    private func record() {
        dismissKeyboard()
        guard ai.selectInput(nil) else { return }
        voice.start(.revoice)
    }
    private func chooseAudio() { dismissKeyboard(); sheet = .library }
    private func selectAudio(_ asset:AudioAsset) { ai.selectInput(asset); sheet = nil }
    private func recognize() { dismissKeyboard(); ai.recognize() }
    private func generate() { dismissKeyboard(); ai.generate() }
    private func resume() { dismissKeyboard(); ai.resumePending() }
    private func stop() { dismissKeyboard(); ai.cancel() }
    private func openConnection() { dismissKeyboard(); sheet = .connection }
    private func connectIfNeeded() { if ai.configured && ai.voices.isEmpty && !ai.connecting { ai.connect() } }
}

private struct RevoiceModeControl:View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var kind:RevoiceController.Kind
    let disabled:Bool
    var onDismiss:()->Void = {}
    var body:some View {
        Group {
            if typeSize.isAccessibilitySize {
                StablePicker(title:"配音方式",selection:$kind,choices:[
                    .init(id:.preset,title:"预设声线"),.init(id:.custom,title:"自定义配音")],onDismiss:onDismiss)
            } else {
                Picker("配音方式",selection:$kind) {
                    Text("预设声线").tag(RevoiceController.Kind.preset)
                    Text("自定义配音").tag(RevoiceController.Kind.custom)
                }.pickerStyle(.segmented)
            }
        }.disabled(disabled).accessibilityIdentifier("revoice.mode")
    }
}

private struct RevoiceVoiceSettings:View {
    let kind:RevoiceController.Kind
    let voices:[RevoiceVoice]
    let speakers:[RevoiceSpeaker]
    @Binding var preset:String
    @Binding var speaker:String
    @Binding var instruction:String
    var editablePreset = false
    var serviceSupportsPreset = false
    var automatic = false
    var resetInstruction:()->Void = {}
    var onSelectionDismissed:()->Void = {}
    let focus:FocusState<RevoiceInputField?>.Binding
    let disabled:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if kind == .preset {
                if !voices.isEmpty {
                    StablePicker(title:"声线",selection:$preset,
                        choices:voices.map { .init(id:$0.id,title:$0.displayName) },onDismiss:onSelectionDismissed)
                } else { Text("选择声线").font(.headline) }
                PaperCaption("录完识别文字，确认内容后手动生成")
            } else {
                StablePicker(title:"Speaker",selection:$speaker,
                    choices:(speakers.isEmpty ? RevoiceSpeaker.all : speakers).map { .init(id:$0.id,title:$0.displayName) },onDismiss:onSelectionDismissed)
            }
            if kind == .custom || editablePreset {
                if automatic {
                    DisclosureGroup("角色基础风格 · 可选") { baselineEditor }
                } else { baselineEditor }
            } else if voices.first(where:{$0.id == preset})?.variant == "base" {
                PaperCaption("固定参考声线沿用已认可的表达，暂不支持修改指令。")
            } else if !voices.isEmpty && !serviceSupportsPreset {
                PaperCaption("当前云端需升级后才能编辑预设指令。")
            }
        }.disabled(disabled)
    }
    private var baselineEditor:some View {
        VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text(automatic ? "基础角色风格 · 可选" : "表达指令 · 可选").font(.subheadline)
                    Spacer()
                    if kind == .preset {
                        Button("恢复默认",action:resetInstruction).font(.caption)
                            .accessibilityIdentifier("revoice.instruction.reset")
                    }
                }
                TextField("",text:$instruction,axis:.vertical)
                    .focused(focus,equals:.instruction).lineLimit(1...3)
                    .textFieldStyle(.plain).padding(10).frame(minHeight:44)
                    .background(PaperTheme.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
                    .overlay(RoundedRectangle(cornerRadius:16).stroke(PaperTheme.line,lineWidth:1).allowsHitTesting(false))
                    .overlay(alignment:.leading) {
                        if instruction.isEmpty {
                            Text("例如：自然放松，语速稍慢").foregroundStyle(PaperTheme.secondary)
                                .padding(10).lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("表达指令").accessibilityIdentifier("revoice.instruction")
                PaperCaption(automatic
                    ? "\(instruction.unicodeScalars.count)/500 · 保留角色风格，本段表达按内容自动匹配"
                    : "\(instruction.unicodeScalars.count)/500 · 留空使用自然表达")
        }
    }

}

private struct RevoiceAutomaticInstructionControl:View {
    @ObservedObject var ai:RevoiceController
    let disabled:Bool
    let focus:FocusState<RevoiceInputField?>.Binding
    @ScaledMetric(relativeTo:.body) private var editorHeight:CGFloat = 150
    private var automatic:Bool { ai.usesAutomaticInstruction && ai.canUseAutomaticInstruction }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Button { ai.usesAutomaticInstruction.toggle() } label: {
                HStack(spacing:12) {
                    Text("按内容自动匹配表达指令").fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:0)
                    Image(systemName:automatic ? "checkmark.circle.fill" : "circle")
                    Text(automatic ? "已开启" : "已关闭").fixedSize()
                }.frame(maxWidth:.infinity)
            }.buttonStyle(PaperButtonStyle(primary:automatic))
                .disabled(disabled || !ai.canUseAutomaticInstruction)
                .accessibilityLabel("按内容自动匹配表达指令")
                .accessibilityValue(automatic ? "已开启" : "已关闭")
                .accessibilityIdentifier("revoice.instruction.automatic")
            if !ai.canUseAutomaticInstruction {
                PaperCaption(ai.selectedVoice?.variant == "base" ? "固定参考声线不支持自动表达指令。" : "连接支持预设表达指令的云端后，可开启自动匹配。")
            } else if automatic {
                HStack {
                    Text("本次表达指令 · 可编辑").font(.subheadline)
                    Spacer(minLength:4)
                    PaperCaption("\(ai.automaticInstructionDraft?.text.unicodeScalars.count ?? 0)/500")
                }
                TextEditor(text:Binding(get:{ai.automaticInstructionDraft?.text ?? ""},set:ai.editAutomaticInstruction))
                    .scrollDismissesKeyboard(.never)
                    .focused(focus,equals:.automaticInstruction).frame(height:editorHeight)
                    .scrollContentBackground(.hidden).padding(10)
                    .background(PaperTheme.mist.opacity(0.35),in:RoundedRectangle(cornerRadius:16))
                    .accessibilityLabel("本次表达指令").accessibilityIdentifier("revoice.instruction.preview")
                    .disabled(disabled)
                if ai.automaticInstructionIsStale {
                    PaperCaption("内容或基础风格已变化，将使用你保留的手改指令；可重新匹配。")
                        .accessibilityIdentifier("revoice.instruction.stale")
                }
                PaperCaption(ai.automaticInstructionDraft?.userEdited == true ? "已手动调整 · 生成时使用框内指令" : RevoiceAutomaticInstruction.profile(text:ai.text).summary)
                    .accessibilityIdentifier("revoice.instruction.summary")
                Button("重新匹配") { ai.rematchAutomaticInstruction() }
                    .disabled(disabled || ai.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("revoice.instruction.rematch")
                PaperCaption("仅在手机匹配文字线索；开启与修改不会提交配音。清空指令使用自然表达。")
            }
        }
    }
}

private struct RevoiceTextComposer:View {
    @ScaledMetric(relativeTo:.body) private var editorHeight:CGFloat = 96
    @Binding var text:String
    let focus:FocusState<RevoiceInputField?>.Binding
    let disabled:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            ViewThatFits(in:.horizontal) {
                HStack { Text("要说的话").font(.headline); Spacer(); PaperCaption("\(text.unicodeScalars.count)/1,000") }
                VStack(alignment:.leading,spacing:4) { Text("要说的话").font(.headline); PaperCaption("\(text.unicodeScalars.count)/1,000 字符") }
            }
            TextEditor(text:$text).frame(height:editorHeight).accessibilityIdentifier("revoice.text")
                .scrollDismissesKeyboard(.never)
                .accessibilityLabel("要说的话").focused(focus,equals:.text)
                .scrollContentBackground(.hidden).padding(8)
                .background(PaperTheme.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
                .overlay(RoundedRectangle(cornerRadius:16).stroke(PaperTheme.line,lineWidth:1).allowsHitTesting(false))
                .overlay(alignment:.topLeading) {
                    if text.isEmpty {
                        Text("输入要说的话，或使用下方语音输入")
                            .foregroundStyle(PaperTheme.secondary).padding(12)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .disabled(disabled)
            PaperCaption("保留原话，不自动润色；语音输入后可以校对。")
        }
    }
}

private struct RevoiceInputControls:View {
    @ObservedObject var voice:RawVoiceRecorder
    let inputName:String?
    let canRecognizeAgain:Bool
    let disabled:Bool
    let libraryEmpty:Bool
    let record:()->Void
    let chooseAudio:()->Void
    let recognize:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if let inputName {
                Text("录音：\(inputName)").font(.caption).lineLimit(2)
                if canRecognizeAgain { Button("重新识别这段录音",action:recognize).disabled(disabled) }
            }
            if voice.isActive {
                ProgressView(voice.status,value:Double(min(1,max(0,voice.inputLevel))))
                Button("停止录音") { voice.stop() }.disabled(voice.state == .saving).buttonStyle(PaperButtonStyle(primary:true))
            } else {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:12) {
                        Button("语音输入",action:record).disabled(disabled)
                        Button("从库选择录音",action:chooseAudio).disabled(disabled || libraryEmpty)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Button("语音输入",action:record).disabled(disabled)
                        Button("从库选择录音",action:chooseAudio).disabled(disabled || libraryEmpty)
                    }
                }
            }
            PaperCaption("录音最长 60 秒 · 配音最长 180 秒")
            if let error = voice.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}

private struct RevoicePendingCard:View {
    let context:RevoiceSaveContext
    let status:String
    let error:String?
    let busy:Bool
    let resume:()->Void
    let stop:()->Void
    var body:some View {
        PaperCard("已提交的配音") {
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Image(systemName:"person.wave.2").accessibilityHidden(true)
                    Text(context.voiceName).accessibilityIdentifier("revoice.pending.voice")
                }.font(.subheadline)
                Text(context.text).font(.subheadline).lineLimit(3)
                    .accessibilityIdentifier("revoice.pending.text")
                Text("表达：\(context.instruction.isEmpty ? "自然表达" : context.instruction)")
                    .font(.caption).foregroundStyle(PaperTheme.secondary).lineLimit(3)
                    .accessibilityIdentifier("revoice.pending.instruction")
                PaperCaption("以上是这份任务的固定内容。上面的草稿可以继续编辑。")
            }
            if busy { ProgressView(status) } else { PaperCaption(status) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("revoice.error") }
            if !busy {
                Button("继续取回这份配音",action:resume).buttonStyle(PaperButtonStyle(primary:true))
                    .accessibilityIdentifier("revoice.pending.resume")
            }
            Button("停止等待这份配音",action:stop).accessibilityIdentifier("revoice.pending.stop")
            PaperCaption("切到其他 App 后可继续取回。停止等待后，迟到成品不会自动保存。")
        }
    }
}

private struct RevoiceStatusNotice:View {
    let status:String
    let error:String?
    let busy:Bool
    let stop:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if busy { ProgressView(status); Button("停止等待",action:stop) }
            else { PaperCaption(status) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("revoice.error") }
        }.accessibilityIdentifier("revoice.status")
    }
}

private struct RevoiceConnectionControl:View {
    let configured:Bool
    let connecting:Bool
    let importDisabled:Bool
    let reconnectDisabled:Bool
    let open:()->Void
    let reconnect:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button(action:open) { Label(configured ? "云端连接设置" : "设置云端连接",systemImage:"cloud") }
                .accessibilityIdentifier("revoice.connection").disabled(importDisabled)
            if configured {
                DisclosureGroup("连接与隐私") {
                    Button("重新连接",action:reconnect).disabled(reconnectDisabled)
                    PaperCaption("录音在手机识别；云端只接收文字与声线参数。连接配置保存在钥匙串。")
                }
            }
            if connecting { PaperCaption("正在检查连接…") }
        }
    }
}

#if DEBUG
private struct RevoiceDraftPreview:View {
    @State private var speaker = "Serena"
    @State private var preset = "serena-original"
    @State private var instruction = ""
    @State private var text = "今天的天气不错，我们出去走走吧。"
    @FocusState private var focus:RevoiceInputField?
    var body:some View {
        NavigationStack {
            PaperScreen {
                PaperCard {
                    RevoiceVoiceSettings(kind:.custom,voices:[],speakers:RevoiceSpeaker.all,
                        preset:$preset,speaker:$speaker,instruction:$instruction,focus:$focus,disabled:false)
                    Divider()
                    RevoiceTextComposer(text:$text,focus:$focus,disabled:false)
                }
            }.keyboardDone { focus = nil }.navigationTitle("AI 重新配音")
        }.tint(PaperTheme.accent)
    }
}

#Preview("配音草稿 · 浅色") { RevoiceDraftPreview().preferredColorScheme(.light) }
#Preview("配音草稿 · 深色大字体") { RevoiceDraftPreview().preferredColorScheme(.dark).dynamicTypeSize(.accessibility3) }
#endif

struct CloudConnectionView:View {
    @ObservedObject var ai:RevoiceController
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ""
    @FocusState private var editingConfiguration: Bool
    @State private var importFile = false
    @State private var fileError:String?
    var body:some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"连接云端",subtitle:"一次设置，随时重新配音。",symbol:"cloud")
                PaperCard("导入连接配置") {
                    PaperCaption("导入电脑上的 modal-client.json，或复制其中的完整 JSON。配置包含你的私有密钥，请只保存在自己的设备上。")
                    Button("从文件导入") { editingConfiguration = false; KeyboardDismiss.perform(); importFile = true }.disabled(ai.busy)
                    SecureField("粘贴完整连接 JSON",text:$configuration).focused($editingConfiguration)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).disabled(ai.busy)
                        .submitLabel(.done).onSubmit { editingConfiguration = false; KeyboardDismiss.perform() }
                    Button("保存并连接") {
                        editingConfiguration = false; KeyboardDismiss.perform(); ai.configure(Data(configuration.utf8)); configuration = ""; fileError = nil
                    }.buttonStyle(PaperButtonStyle(primary:true)).disabled(ai.busy || configuration.isEmpty)
                    if ai.connecting { ProgressView("正在连接云端…") }
                    PaperCaption(ai.status)
                    if let warning = ai.connectionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    if let error = ai.errorMessage ?? fileError { Text(error).font(.callout).foregroundStyle(.orange) }
                    PaperCaption("连接配置保存在本机钥匙串。重新签名、重装或更换密钥后，可以再次导入。")
                }
            }.keyboardDone { editingConfiguration = false }.navigationTitle("云端连接").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { configuration = ""; dismiss() } }
        }
        .sheet(isPresented:$importFile) {
            JSONDocumentPicker(onSelection: { url in
                defer { JSONImportFile.removePickerCopy(url); importFile = false }
                do { ai.configure(try JSONImportFile.read(url,maximumBytes:8192)); fileError = nil }
                catch { fileError = "无法读取有效的连接 JSON（最大 8 KiB），请下载到手机后重新导入" }
            }, onCancel: { importFile = false })
        }
        .onDisappear { configuration = "" }
    }
}

struct RevoiceResultTools:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    let result:AudioAsset
    var title = "配音成品"
    var onMix:((AudioAsset)->Void)? = nil
    @State private var share:ShareItem?
    var body:some View {
        PaperCard(title) {
            Text(result.libraryName).font(.headline)
            if let metadata = result.revoice { PaperCaption("配音计算 \(String(format:"%.1f",metadata.generationSeconds)) 秒 · 成品 \(AudioPlaybackSettings.time(result.duration))") }
            HStack {
                Button("回听") { coordinator.audition(result) }
                Button("用于延迟播放") { coordinator.selectLocal(result) }
            }.disabled(coordinator.controlsLocked)
            HStack {
                Button("分享成品") { if let url = try? AudioFileManager.url(for:result) { share = ShareItem(url:url) } }
                    .disabled(coordinator.controlsLocked)
                Button("停止回听") { coordinator.preview.stop() }
            }
            if let onMix { Button("去混音") { KeyboardDismiss.perform(); onMix(result) } }
        }.sheet(item:$share) { ShareSheet(url:$0.url) }
    }
}
