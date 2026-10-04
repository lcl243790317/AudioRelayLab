import AVFoundation
import Combine
import UIKit

@MainActor final class RevoiceController: ObservableObject {
    enum Kind:String,CaseIterable,Hashable { case preset, custom }
    enum Stage:Equatable { case idle, recognizing, generating, saving }
    @Published var kind:Kind = .preset { didSet { if kind == .preset && oldValue != kind { resetPresetInstruction() } } }
    @Published var selectedPreset = "serena-original" { didSet { if selectedPreset != oldValue { resetPresetInstruction() } } }
    @Published var selectedSpeaker = "Serena"
    @Published var instruction = ""
    @Published var presetInstruction = ""
    @Published private(set) var supportsPresetInstruction = false
    private var instructionPresetID:String?
    var selectedVoice:RevoiceVoice? { voices.first { $0.id == selectedPreset } }
    var canEditPresetInstruction:Bool { supportsPresetInstruction && selectedVoice?.supportsInstruction == true }
    func resetPresetInstruction() {
        presetInstruction = selectedVoice?.instruction ?? ""
        instructionPresetID = selectedVoice == nil ? nil : selectedPreset
    }
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
    @Published private(set) var pendingJobID:UUID?
    var hasPendingJob:Bool { pendingJobID != nil }
    var pendingContext:RevoiceSaveContext? {
#if DEBUG
        if let previewPendingContext { return previewPendingContext }
#endif
        return transfers?.pending?.context
    }
    var canGenerateDraft:Bool {
        !connecting && stage != .recognizing && stage != .saving && (stage == .idle || hasPendingJob)
    }
    private let transfers:BackgroundRevoiceTransfers?
    private var foreground = true
    private var pendingRecognition = false
    private let client:CloudRevoiceClient
    private let recognizer:any RevoiceTranscribing
    private let saveConnection:(CloudConnection)throws->Void
    private let logger:DiagnosticsLogger?
    private var connection:CloudConnection?
    private var task:Task<Void,Never>?
    private var generation = UUID()
    private var observedJobID:UUID?
    private var connectionTask:Task<Void,Never>?
    private var connectionGeneration = UUID()
#if DEBUG
    private var previewPendingContext:RevoiceSaveContext?
#endif
    init(logger:DiagnosticsLogger? = nil, client:CloudRevoiceClient = CloudRevoiceClient(),
         recognizer:(any RevoiceTranscribing)? = nil,
         connection:CloudConnection? = CloudConnectionStore.load(),
         saveConnection:@escaping (CloudConnection)throws->Void = CloudConnectionStore.save,
         backgroundTransfers:BackgroundRevoiceTransfers? = nil) {
        self.transfers = backgroundTransfers
        self.logger = logger; self.client = client; self.recognizer = recognizer ?? DeviceSpeechRecognizer()
        self.connection = connection; configured = connection != nil; self.saveConnection = saveConnection
        transfers?.onChange = { [weak self] job,message,asset in
            guard let self else { return }
            guard self.observedJobID == job.id else { return }
            self.pendingJobID = job.isPending ? job.id : nil
            self.status = message
            self.errorMessage = [.suspended,.failed].contains(job.phase) ? job.lastError : nil
            if job.phase == .downloading || job.phase == .submitting { self.stage = message == "保存中" ? .saving : .generating }
            else { self.stage = .idle }
            if let asset {
                self.result = asset; self.onResult?(asset)
                self.logger?.log("后台配音已保存","任务=\(job.networkID)，时长=\(asset.duration)")
            }
        }
        transfers?.onNeedsSubmission = { [weak self] job in self?.resumeSubmission(job) }
        if let job = transfers?.pending {
            observedJobID = job.id; pendingJobID = job.id; restoreDraft(job)
            status = "发现未完成的配音任务，将继续取回"
        } else if let job = transfers?.store.all().first(where: { $0.isUnfinished && $0.expiresAt <= Date() }) {
            observedJobID = job.id; restoreDraft(job); status = "任务已过期，文字已保留，可以重新生成"
        }

    }
    deinit { task?.cancel(); connectionTask?.cancel() }
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
        guard !connecting, stage == .idle || hasPendingJob, let connection else { return }
        let token = UUID(); connectionGeneration = token; connecting = true
        let reportsConnectionStatus = !hasPendingJob
        if reportsConnectionStatus { errorMessage = nil; status = "正在检查云端连接" }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectionGeneration == token { self.connecting = false; self.connectionTask = nil } }
            do {
                let (voices,speakers) = try await self.client.connect(connection)
                try Task.checkCancellation(); guard self.connectionGeneration == token else { return }
                self.voices = voices; self.speakers = speakers
                self.supportsPresetInstruction = self.client.supportsPresetInstruction(for:connection)
                if !voices.contains(where:{$0.id == self.selectedPreset}) { self.selectedPreset = voices[0].id }
                if self.instructionPresetID != self.selectedPreset { self.resetPresetInstruction() }
                if reportsConnectionStatus && !self.hasPendingJob && self.stage == .idle {
                    self.status = speakers.isEmpty ? "云端已连接 · 此服务暂未提供自定义配音" : "云端已连接 · 录音在手机转为文字"
                }
                self.logger?.log("重新配音连接", "云端连接成功；预设数=\(voices.count)，speaker 数=\(speakers.count)")
            } catch {
                guard self.connectionGeneration == token else { return }
                self.voices = []; self.speakers = []; self.errorMessage = RevoiceError.message(error)
                if reportsConnectionStatus && !self.hasPendingJob && self.stage == .idle { self.status = "云端连接未完成，文字已保留" }
            }
        }
    }
    @discardableResult func selectInput(_ asset:AudioAsset?) -> Bool {
        guard cancel() else { return false }
        input = asset; recognizedText = nil; text = ""; result = nil; errorMessage = nil
        status = asset == nil ? "可以录音或直接输入文字" : "录音已选择，点击识别文字或生成配音"
        return true
    }
    func recorded(_ asset:AudioAsset) {
        guard selectInput(asset) else { return }
        if foreground { recognize(autoGenerate:kind == .preset) }
        else { pendingRecognition = true; status = "原声已保存，返回 App 后识别" }
    }
    func forgetAsset(_ id:UUID) {
        if input?.id == id { selectInput(nil) }
        if result?.id == id { result = nil }
    }
    func recognize(autoGenerate:Bool = false, start:Double = 0, limit:Double? = nil) {
        guard !busy, let input else { return }
        let textAtStart = text
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
                let draftWasEdited = self.text != textAtStart
                if !draftWasEdited { self.text = recognized }
                self.recognizedText = recognized
                _ = try RevoiceLimits.text(recognized)
                self.stage = .idle; self.task = nil; self.status = "识别完成，可以修改文字后重新生成"
                if autoGenerate && !draftWasEdited && self.kind == .preset { self.task = nil; self.generate() }
            } catch {
                guard self.generation == token else { return }
                if !Task.isCancelled { self.errorMessage = RevoiceError.message(error); self.status = "识别未完成，原录音已保留" }
            }
        }
    }
    func generate() {
        guard canGenerateDraft else { return }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, input != nil {
            if hasPendingJob, !cancel() { return }
            recognize(autoGenerate:kind == .preset); return
        }
        do {
            guard let connection else { throw LabError.message("请先导入云端连接配置") }
            let choice:RevoiceChoice, label:String, effectiveInstruction:String, reference:String?
            if kind == .custom {
                guard speakers.contains(where:{$0.id == selectedSpeaker}) else { throw LabError.message("请连接支持自定义配音的云端服务") }
                choice = .custom(speaker:selectedSpeaker,instruction:instruction)
                label = selectedSpeaker; effectiveInstruction = instruction; reference = nil
            } else {
                guard let voice = voices.first(where:{$0.id == selectedPreset}) else { throw LabError.message("请先连接云端并选择声线") }
                let override = canEditPresetInstruction ? presetInstruction : nil
                choice = .preset(id:voice.id,variant:voice.variant,instruction:override)
                label = voice.displayName; effectiveInstruction = override ?? voice.instruction ?? ""; reference = voice.fixedReferenceID
            }
            let usedText = try RevoiceLimits.text(text); _ = try choice.body(text:usedText)
            let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:choice,voiceName:label,
                instruction:effectiveInstruction,fixedReferenceID:reference,recognizedText:recognizedText,
                text:usedText,sourceAudioID:input?.id)
            // A new generation always freezes the current draft with a new ID.
            // Recovering a previous ID is only the explicit resume action.
            if hasPendingJob, !cancel() { return }
            observedJobID = nil
            beforeGenerate?()
            result = nil; errorMessage = nil
            if let transfers,client.downloadOrigin(for:connection) != nil {
                let job = PendingRevoiceJob(context:context,primaryOrigin:try connection.validate(),
                    connectionFingerprint:connection.fingerprint)
                observedJobID = job.id
                try transfers.begin(job); pendingJobID = job.id; resumeSubmission(job)
            } else {
                let token = UUID(); generation = token; stage = .generating
                status = "配音中 · 当前服务需保持 App 在前台"
                task = Task { [weak self] in
                    guard let self else { return }
                    defer { if self.generation == token { self.stage = .idle; self.task = nil } }
                    do {
                        let audio = try await self.client.synthesize(connection,choice:choice,text:usedText)
                        try Task.checkCancellation(); guard self.generation == token else { return }
                        self.stage = .saving; self.status = "保存中"
                        let asset = try RevoiceSaving.save(audio,context:context)
                        self.result = asset; self.status = "已保存 · 成品 \(AudioPlaybackSettings.time(asset.duration))"
                        self.onResult?(asset)
                    } catch {
                        guard self.generation == token else { return }
                        if !Task.isCancelled { self.errorMessage = RevoiceError.message(error); self.status = "配音未完成，文字已保留" }
                    }
                }
            }
        } catch { errorMessage = RevoiceError.message(error) }
    }
    private func restoreDraft(_ job:PendingRevoiceJob) {
        if case .custom(let speaker,let value) = job.context.choice {
            kind = .custom; selectedSpeaker = speaker; instruction = value
        } else if case .preset(let id,_,_) = job.context.choice {
            kind = .preset; selectedPreset = id
            presetInstruction = job.context.instruction; instructionPresetID = id
        }
        text = job.context.text; recognizedText = job.context.recognizedText
        if let source = job.context.sourceAudioID { input = (try? AudioFileManager.listLocalAudio())?.first { $0.id == source } }
    }
    private func resumeSubmission(_ job:PendingRevoiceJob) {
        guard task == nil,let transfers,job.isPending,transfers.store.job(job.id)?.isPending == true else { return }
        if let current = pendingJobID, current != job.id { return }
        guard let connection,connection.fingerprint == job.connectionFingerprint else {
            transfers.submissionFailed(job.id,message:"连接配置已变化，请恢复原配置后取回；也可以停止等待")
            return
        }
        observedJobID = job.id; pendingJobID = job.id; errorMessage = nil; stage = .generating
        let token = UUID(); generation = token
        let lease = RevoiceSubmissionLease { [weak self] in
            guard let self,self.generation == token else { return }
            self.task?.cancel()
            transfers.submissionFailed(job.id,message:"提交暂停，任务编号已保留；返回 App 后继续取回")
        }
        task = Task { [weak self] in
            guard let self else { lease.end(); return }
            defer {
                lease.end()
                if self.generation == token {
                    self.task = nil
                    let phase = transfers.pending?.phase
                    self.stage = phase == .downloading || phase == .submitting ? .generating : .idle
                }
            }
            do {
                if self.client.downloadOrigin(for:connection) == nil {
                    if let catalog = self.connectionTask { await catalog.value }
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    if self.client.downloadOrigin(for:connection) == nil {
                        let (voices,speakers) = try await self.client.connect(connection)
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        self.voices = voices; self.speakers = speakers
                        self.supportsPresetInstruction = self.client.supportsPresetInstruction(for:connection)
                        if self.instructionPresetID != self.selectedPreset { self.resetPresetInstruction() }
                    }
                }
                try Task.checkCancellation()
                guard self.generation == token, transfers.store.job(job.id)?.isPending == true else { return }
                guard let origin = self.client.downloadOrigin(for:connection) else { throw LabError.message("请升级云端服务以取回后台任务") }
                let reply = try await self.client.submitJob(connection,context:job.context)
                try Task.checkCancellation(); guard self.generation == token else { return }
                try transfers.attach(reply,origin:origin,id:job.id)
            } catch {
                guard self.generation == token else { return }
                if !Task.isCancelled { transfers.submissionFailed(job.id,message:"提交或连接暂停，任务编号已保留；返回后继续取回") }
            }
        }
    }
    func resumePending() {
        guard let transfers else { return }
        if let job = transfers.pending { observedJobID = job.id; pendingJobID = job.id }
        if configured && voices.isEmpty && !connecting { connect() }
        Task { await transfers.restore() }
    }
    func foregroundChanged(_ active:Bool) {
        foreground = active
        transfers?.setForeground(active)
        if !active,stage == .recognizing {
            generation = UUID(); task?.cancel(); task = nil; recognizer.cancel(); stage = .idle
            pendingRecognition = true; status = "原声已保留，返回 App 后继续识别"
        }
        if active {
            if pendingRecognition { pendingRecognition = false; recognize(autoGenerate:kind == .preset) }
            resumePending()
        }
    }
    @discardableResult func cancel() -> Bool {
        guard transfers?.cancel() != false else {
            pendingJobID = transfers?.pending?.id
            errorMessage = "停止等待标记无法保存，请保持 App 打开后重试"
            return false
        }
        pendingRecognition = false; observedJobID = nil; pendingJobID = nil
#if DEBUG
        previewPendingContext = nil
#endif
        generation = UUID(); task?.cancel(); task = nil; recognizer.cancel(); stage = .idle
        connectionGeneration = UUID(); connectionTask?.cancel(); connectionTask = nil; connecting = false
        status = "已停止等待 · 已提交的云端任务可能继续完成"
        return true
    }
    func preparePreview(custom:Bool) {
#if DEBUG
        previewPendingContext = nil
#endif
        kind = custom ? .custom : .preset; configured = false
        voices = [.init(id:"serena-original",displayName:"Serena · 认可原版",variant:"custom",instruction:"自然、放松的日常表达。",supportsInstruction:true),
                  .init(id:"vivian-original",displayName:"Vivian · 认可原版",variant:"custom",instruction:"自然明亮，轻松地说话。",supportsInstruction:true),
                  .init(id:"ancient-dylan",displayName:"古风温润小生",variant:"custom",instruction:"温润从容，古风小生的自然表达。",supportsInstruction:true),
                  .init(id:"scholar-design",displayName:"清润书生",variant:"base",supportsInstruction:false),
                  .init(id:"cute-design",displayName:"清脆动漫可爱声",variant:"base",supportsInstruction:false),
                  .init(id:"cool-serena",displayName:"清冷淡然 · Serena",variant:"custom",instruction:"清冷淡然，语气自然。",supportsInstruction:true)]
        supportsPresetInstruction = true; resetPresetInstruction()
        speakers = RevoiceSpeaker.all; text = "今天的天气不错，我们出去走走吧。"
        status = "界面预览 · 未连接云端"
    }
#if DEBUG
    func preparePreviewRecovery() {
        preparePreview(custom:true)
        let context = RevoiceSaveContext(id:UUID(uuidString:"16620000-0000-4000-8000-000000000012") ?? UUID(),
            createdAt:Date(timeIntervalSince1970:1_790_000_000),
            choice:.custom(speaker:"Serena",instruction:"轻柔、语速稍慢"),voiceName:"Serena",
            instruction:"轻柔、语速稍慢",fixedReferenceID:nil,recognizedText:nil,
            text:"这是之前已提交的配音，恢复时请继续取回这一份。",sourceAudioID:nil)
        previewPendingContext = context; pendingJobID = context.id; configured = true
        selectedSpeaker = "Vivian"; instruction = "自然明亮"; text = "这是我现在编辑的新内容。"
        stage = .idle; status = "配音仍在云端执行，可以继续取回"
        errorMessage = "下载暂存未完成，任务已保留"
    }
#endif
}
