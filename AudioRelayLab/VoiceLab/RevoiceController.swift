import AVFoundation
import Combine

@MainActor final class RevoiceController: ObservableObject {
    enum Kind:String,CaseIterable { case preset, custom }
    enum Stage { case idle, recognizing, generating, saving }
    @Published var kind:Kind = .preset
    @Published var selectedPreset = "serena-original"
    @Published var selectedSpeaker = "Serena"
    @Published var instruction = ""
    @Published var text = ""
    @Published private(set) var recognizedText:String?
    @Published private(set) var input:AudioAsset?
    @Published private(set) var result:AudioAsset?
    @Published private(set) var voices:[RevoiceVoice] = []
    @Published private(set) var speakers:[RevoiceSpeaker] = []
    @Published private(set) var stage:Stage = .idle
    @Published private(set) var connecting = false
    @Published private(set) var configured = false
    @Published private(set) var status = "导入云端连接配置后，即可重新配音"
    @Published private(set) var errorMessage:String?
    @Published private(set) var connectionWarning:String?
    var busy:Bool { stage != .idle || connecting }
    var onResult:((AudioAsset)->Void)?
    var beforeGenerate:(()->Void)?
    private let client:CloudRevoiceClient
    private let recognizer:any RevoiceTranscribing
    private let saveConnection:(CloudConnection)throws->Void
    private let logger:DiagnosticsLogger?
    private var connection:CloudConnection?
    private var task:Task<Void,Never>?
    private var generation = UUID()
    init(logger:DiagnosticsLogger? = nil, client:CloudRevoiceClient = CloudRevoiceClient(),
         recognizer:(any RevoiceTranscribing)? = nil,
         connection:CloudConnection? = CloudConnectionStore.load(),
         saveConnection:@escaping (CloudConnection)throws->Void = CloudConnectionStore.save) {
        self.logger = logger; self.client = client; self.recognizer = recognizer ?? DeviceSpeechRecognizer()
        self.connection = connection; configured = connection != nil; self.saveConnection = saveConnection
    }
    deinit { task?.cancel() }
    func configure(_ data:Data) {
        guard !busy else { return }
        do {
            let value = try CloudConnection.decode(data)
            connectionWarning = nil
            do { try saveConnection(value) }
            catch { connectionWarning = "本次连接可以使用，配置未能保存到钥匙串；重开 App 后需再次导入。" }
            connection = value; configured = true; voices = []; speakers = []; connect()
        } catch { errorMessage = RevoiceError.message(error) }
    }
    func connect() {
        guard !busy, let connection else { return }
        let token = UUID(); generation = token; connecting = true; errorMessage = nil; status = "正在检查云端连接"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.connecting = false; self.task = nil } }
            do {
                let (voices,speakers) = try await self.client.connect(connection)
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.voices = voices; self.speakers = speakers
                if !voices.contains(where:{$0.id == self.selectedPreset}) { self.selectedPreset = voices[0].id }
                self.status = speakers.isEmpty ? "云端已连接 · 此服务暂未提供自定义配音" : "云端已连接 · 录音在手机转为文字"
                self.logger?.log("重新配音连接", "云端连接成功；预设数=\(voices.count)，speaker 数=\(speakers.count)")
            } catch {
                guard self.generation == token else { return }
                self.voices = []; self.speakers = []; self.errorMessage = RevoiceError.message(error)
                self.status = "云端连接未完成，文字已保留"
            }
        }
    }
    func selectInput(_ asset:AudioAsset?) {
        cancel()
        input = asset; recognizedText = nil; text = ""; result = nil; errorMessage = nil
        status = asset == nil ? "可以录音或直接输入文字" : "录音已选择，点击识别文字或生成配音"
    }
    func recorded(_ asset:AudioAsset) {
        selectInput(asset); recognize(autoGenerate:kind == .preset)
    }
    func forgetAsset(_ id:UUID) {
        if input?.id == id { selectInput(nil) }
        if result?.id == id { result = nil }
    }
    func recognize(autoGenerate:Bool = false, start:Double = 0, limit:Double? = nil) {
        guard !busy, let input else { return }
        let token = UUID(); generation = token; stage = .recognizing; errorMessage = nil; status = "识别中 · 在手机处理录音"
        task = Task { [weak self] in
            guard let self else { return }
            var prepared:URL?
            defer {
                if let prepared { try? FileManager.default.removeItem(at:prepared) }
                if self.generation == token { self.stage = .idle; self.task = nil }
            }
            do {
                let source = try AudioFileManager.url(for:input)
                let work = Task.detached { try AIRequestAudio.make(url:source,start:start,limit:limit) }
                prepared = try await work.value
                try Task.checkCancellation(); guard self.generation == token, let prepared else { return }
                let recognized = try await self.recognizer.transcribe(url:prepared)
                try Task.checkCancellation(); guard self.generation == token, self.input?.id == input.id else { return }
                self.text = recognized; self.recognizedText = recognized
                _ = try RevoiceLimits.text(recognized)
                self.stage = .idle; self.task = nil; self.status = "识别完成，可以修改文字后重新生成"
                if autoGenerate { self.generate() }
            } catch {
                guard self.generation == token else { return }
                if !Task.isCancelled { self.errorMessage = RevoiceError.message(error); self.status = "识别未完成，原录音已保留" }
            }
        }
    }
    func generate() {
        guard !busy else { return }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, input != nil {
            recognize(autoGenerate:kind == .preset); return
        }
        do {
            guard let connection else { throw LabError.message("请先导入云端连接配置") }
            let choice:RevoiceChoice, label:String
            if kind == .custom {
                guard speakers.contains(where:{$0.id == selectedSpeaker}) else { throw LabError.message("请连接支持自定义配音的云端服务") }
                choice = .custom(speaker:selectedSpeaker,instruction:instruction); label = selectedSpeaker
            } else {
                guard let voice = voices.first(where:{$0.id == selectedPreset}) else { throw LabError.message("请先连接云端并选择声线") }
                choice = .preset(id:voice.id,variant:voice.variant); label = voice.displayName
            }
            let usedText = try RevoiceLimits.text(text); _ = try choice.body(text:usedText)
            let recognized = recognizedText, sourceID = input?.id
            beforeGenerate?()
            let token = UUID(); generation = token; stage = .generating; result = nil; errorMessage = nil
            status = "配音中 · 首次调用可能需要等待冷启动"
            task = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == token { self.stage = .idle; self.task = nil } }
                do {
                    let audio = try await self.client.synthesize(connection,choice:choice,text:usedText)
                    try Task.checkCancellation(); guard self.generation == token else { return }
                    self.stage = .saving; self.status = "保存中"
                    let id = UUID(), name = AudioNaming.generated(kind:"AI成品",label:label,fileExtension:"wav",id:id)
                    let destination = try AudioFileManager.audioDirectory().appendingPathComponent(name)
                    do {
                        try audio.data.write(to:destination,options:.atomic)
                        var asset = try AudioFileManager.inspect(url:destination,displayName:name,id:id,source:.aiConverted,presetName:label)
                        try RevoiceLimits.output(asset.duration)
                        guard abs(asset.duration-audio.duration) <= 1.0/24000 else { throw LabError.invalidFormat }
                        asset.revoice = .init(provider:"Modal Qwen3-TTS 1.7B",generationMode:choice.mode,
                            voiceID:choice.voiceID,speakerID:audio.speaker,instruction:choice.instruction,
                            recognizedText:recognized,synthesisText:usedText,sourceAudioID:sourceID,
                            modelVariant:choice.variant,modelRevision:audio.revision,sha256:audio.sha256,
                            generationSeconds:audio.generationSeconds,totalSeconds:audio.totalSeconds)
                        asset.addedAt = Date(); try AudioFileManager.register(asset)
                        self.result = asset; self.status = "已保存 · 成品 \(AudioPlaybackSettings.time(asset.duration))"
                        self.logger?.log("重新配音已保存", "方式=\(choice.mode)，时长=\(asset.duration)，sha256=\(audio.sha256)")
                        self.onResult?(asset)
                    } catch {
                        try? FileManager.default.removeItem(at:destination)
                        try? FileManager.default.removeItem(at:destination.appendingPathExtension("metadata.json")); throw error
                    }
                } catch {
                    guard self.generation == token else { return }
                    if !Task.isCancelled { self.errorMessage = RevoiceError.message(error); self.status = "配音未完成，文字已保留" }
                }
            }
        } catch { errorMessage = RevoiceError.message(error) }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; recognizer.cancel(); stage = .idle; connecting = false
        status = "已停止等待 · 已提交的云端任务可能继续完成"
    }
    func preparePreview(custom:Bool) {
        kind = custom ? .custom : .preset; configured = false
        voices = [.init(id:"serena-original",displayName:"Serena · 认可原版",variant:"custom"),
                  .init(id:"vivian-original",displayName:"Vivian · 认可原版",variant:"custom"),
                  .init(id:"ancient-dylan",displayName:"古风温润小生",variant:"custom"),
                  .init(id:"scholar-design",displayName:"清润书生",variant:"base"),
                  .init(id:"cute-design",displayName:"清脆动漫可爱声",variant:"base"),
                  .init(id:"cool-serena",displayName:"清冷淡然 · Serena",variant:"custom")]
        speakers = RevoiceSpeaker.all; text = "今天的天气不错，我们出去走走吧。"
        status = "界面预览 · 未连接云端"
    }
}
