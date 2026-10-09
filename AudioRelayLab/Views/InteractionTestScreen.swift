import SwiftUI
import AVFoundation
#if DEBUG
/// A real, longer local file keeps full-preview exit checks independent of AX snapshot latency.
@MainActor enum PreviewInteractionFixture {
    static func make() throws -> AudioAsset {
        let source = try AudioFileManager.loadBundledAudio()
        let input = try AVAudioFile(forReading:AudioFileManager.url(for:source))
        guard let buffer = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:AVAudioFrameCount(input.length)) else {
            throw LabError.invalidFormat
        }
        try input.read(into:buffer)
        let url = try AudioFileManager.audioDirectory().appendingPathComponent("试听退出测试.wav")
        do {
            let output = try AVAudioFile(forWriting:url,settings:input.processingFormat.settings)
            for _ in 0..<8 { try output.write(from:buffer) }
        }
        return try AudioFileManager.inspect(url:url,displayName:"试听退出测试",id:UUID(uuidString:"16300000-0000-4000-8000-000000000020") ?? UUID(),source:.voiceLabRecording)
    }
}

/// Explicit UI-test launches keep one library index for each reserved fixture ID.
@MainActor enum LibraryInteractionFixture {
    static func copy(from sourceURL:URL, directory:URL, name:String, id:UUID, source:AudioSource,
                     configure:(inout AudioAsset)->Void = { _ in }) throws -> AudioAsset {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { throw LabError.invalidFormat }
        let manager = FileManager.default
        let target = directory.appendingPathComponent(name+".wav")
        let sidecar = target.appendingPathExtension("metadata.json")
        let legacy = directory.appendingPathComponent(name+"-长回听.wav")
        let legacySidecar = legacy.appendingPathExtension("metadata.json")
        func owns(_ asset:AudioAsset, file:URL) -> Bool {
            asset.id == id && asset.fileName == name && asset.sandboxFileName == file.lastPathComponent && asset.source == source
        }
        func metadata(at file:URL) -> AudioAsset? {
            (try? Data(contentsOf:file)).flatMap { try? JSONDecoder().decode(AudioAsset.self,from:$0) }
        }
        let previous = metadata(at:sidecar)
        if manager.fileExists(atPath:target.path) || manager.fileExists(atPath:sidecar.path) {
            guard let previous, owns(previous,file:target) else {
                throw LabError.message("测试夹具路径已有其他素材，未覆盖文件")
            }
        }
        let input = try AudioFileManager.inspect(url:sourceURL)
        let current = try? AudioFileManager.inspect(url:target)
        if current?.duration != input.duration || current?.sampleRate != input.sampleRate ||
            current?.channelCount != input.channelCount || current?.byteCount != input.byteCount {
            try Data(contentsOf:sourceURL,options:.mappedIfSafe).write(to:target,
                options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        var asset = try AudioFileManager.inspect(url:target,displayName:name,id:id,source:source)
        asset.addedAt = previous?.addedAt ?? asset.addedAt
        configure(&asset)
        try JSONEncoder().encode(asset).write(to:sidecar,
            options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        if let old = metadata(at:legacySidecar), owns(old,file:legacy) {
            // Old selections can still hold this PCM path; only retire its duplicate library index.
            try manager.removeItem(at:legacySidecar)
        }
        return asset
    }
}

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
                HStack {
                    TextField("连接地址",text:$connection).focused($editing,equals:.connection).frame(minHeight:44).accessibilityIdentifier("interaction.connection")
                    SecureField("密钥",text:$key).focused($editing,equals:.key).frame(minHeight:44).accessibilityIdentifier("interaction.key")
                }
                TextField("数值",value:$number,format:.number).keyboardType(.decimalPad).focused($editing,equals:.number).frame(minHeight:44).accessibilityIdentifier("interaction.number")
                TextEditor(text:$notes).scrollDismissesKeyboard(.never).focused($editing,equals:.notes).frame(height:100).accessibilityIdentifier("interaction.notes")
                Text("点这里收起键盘").frame(minHeight:44).accessibilityIdentifier("interaction.outside")
            }.keyboardDone { editing = nil }.navigationTitle("交互验证")
                .toolbar { NavigationLink("离开输入页") { Text("输入页已离开") } }
        }.buttonStyle(PaperButtonStyle()).onReceive(timer) { _ in tick += 1; expanded = tick.isMultiple(of:2) }
    }
}
#endif
