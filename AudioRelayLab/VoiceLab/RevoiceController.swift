import AVFoundation
import Combine
import UIKit

@MainActor final class RevoiceController: ObservableObject {
    enum Kind:String,CaseIterable,Hashable { case preset, custom }
    enum Stage:Equatable { case idle, recognizing, generating, saving }
    @Published var kind:Kind = .preset { didSet { if !restoringDraft && kind == .preset && oldValue != kind { resetPresetInstruction() }; refreshAutomaticInstruction() } }
    @Published var selectedPreset = "serena-original" { didSet { if !restoringDraft && selectedPreset != oldValue { resetPresetInstruction() }; refreshAutomaticInstruction() } }
    @Published var selectedSpeaker = "Serena" { didSet { refreshAutomaticInstruction() } }
    @Published var instruction = "" { didSet { refreshAutomaticInstruction() } }
    @Published var presetInstruction = "" { didSet { refreshAutomaticInstruction() } }
    @Published var usesAutomaticInstruction = false { didSet { refreshAutomaticInstruction() } }
    @Published private(set) var automaticInstructionDraft:AutomaticInstructionDraft? { didSet { draftChanged() } }
    enum VoiceSelection:Equatable { case mode(Kind), preset(String), speaker(String) }
    @Published private(set) var pendingVoiceSelection:VoiceSelection?
    private var deferredVoiceSelection:VoiceSelection?
    private var restoringDraft = false
    @Published private(set) var supportsPresetInstruction = false
    private var instructionPresetID:String?
    var selectedVoice:RevoiceVoice? { voices.first { $0.id == selectedPreset } }
    var canEditPresetInstruction:Bool { supportsPresetInstruction && selectedVoice?.supportsInstruction == true }
    var canUseAutomaticInstruction:Bool { kind == .custom || canEditPresetInstruction }
    var baseInstruction:String { kind == .custom ? instruction : presetInstruction }
    var automaticInstructionPreview:String? {
        guard usesAutomaticInstruction, canUseAutomaticInstruction,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
        return automaticInstructionDraft?.text
    }
    private var automaticSource:AutomaticInstructionSource {
        .init(text:text.trimmingCharacters(in:.whitespacesAndNewlines),
            baseInstruction:baseInstruction.trimmingCharacters(in:.whitespacesAndNewlines),
            kind:kind.rawValue,voiceID:kind == .custom ? selectedSpeaker : selectedPreset)
    }
    var automaticInstructionIsStale:Bool {
        automaticInstructionDraft.map { $0.userEdited && $0.source != automaticSource } ?? false
    }
    private func refreshAutomaticInstruction() {
        defer { draftChanged() }
        guard !restoringDraft,usesAutomaticInstruction,canUseAutomaticInstruction,
              automaticInstructionDraft?.userEdited != true,!automaticSource.text.isEmpty else { return }
        rematchAutomaticInstruction()
    }
    func rematchAutomaticInstruction() {
        guard canUseAutomaticInstruction,!automaticSource.text.isEmpty else { return }
        automaticInstructionDraft = .init(text:RevoiceAutomaticInstruction.make(text:text,baseInstruction:baseInstruction),
            userEdited:false,source:automaticSource)
    }
    func editAutomaticInstruction(_ value:String) {
        automaticInstructionDraft = .init(text:value,userEdited:true,source:automaticInstructionDraft?.source ?? automaticSource)
    }
    func requestVoiceSelection(_ value:VoiceSelection,deferConfirmation:Bool = false) {
        switch value {
        case .mode(let value) where value == kind: return
        case .preset(let value) where value == selectedPreset: return
        case .speaker(let value) where value == selectedSpeaker: return
        default: break
        }
        if automaticInstructionDraft?.userEdited == true {
            if deferConfirmation { deferredVoiceSelection = value } else { pendingVoiceSelection = value }
        } else { applyVoiceSelection(value) }
    }
    func presentDeferredVoiceSelection() {
        if let value = deferredVoiceSelection { deferredVoiceSelection = nil; pendingVoiceSelection = value }
    }
    func cancelVoiceSelection() { pendingVoiceSelection = nil; deferredVoiceSelection = nil }
    func confirmVoiceSelection(_ selection:VoiceSelection? = nil) {
        guard let value = selection ?? pendingVoiceSelection else { return }
        cancelVoiceSelection(); applyVoiceSelection(value)
    }
    private func applyVoiceSelection(_ value:VoiceSelection) {
        restoringDraft = true; automaticInstructionDraft = nil
        switch value { case .mode(let value): kind = value; case .preset(let value): selectedPreset = value; case .speaker(let value): selectedSpeaker = value }
        restoringDraft = false
        if kind == .preset { resetPresetInstruction() }
        refreshAutomaticInstruction()
    }
    private func resolvedInstruction(_ base:String,text:String) throws -> String {
        try RevoiceLimits.instruction(base)
        if usesAutomaticInstruction && canUseAutomaticInstruction {
            let value = automaticInstructionDraft?.text ?? RevoiceAutomaticInstruction.make(text:text,baseInstruction:base)
            try RevoiceLimits.instruction(value); return value
        }
        return base
    }
    func resetPresetInstruction() {
        presetInstruction = selectedVoice?.instruction ?? ""
        instructionPresetID = selectedVoice == nil ? nil : selectedPreset
    }
    @Published var text = "" { didSet { refreshAutomaticInstruction() } }
    @Published private(set) var recognizedText:String? { didSet { draftChanged() } }
    @Published private(set) var input:AudioAsset?
    @Published private(set) var result:AudioAsset?
    @Published private(set) var voices:[RevoiceVoice] = []
    @Published private(set) var speakers:[RevoiceSpeaker] = []
    @Published private(set) var cloudStage:Stage = .idle
    @Published private(set) var recognizing = false
    var stage:Stage { recognizing ? .recognizing : cloudStage }
    @Published private(set) var connecting = false
    @Published private(set) var configured = false
    @Published private(set) var status = "导入云端连接配置后，即可重新配音"
    @Published private(set) var errorMessage:String?
    @Published private(set) var connectionWarning:String?
    var busy:Bool { stage != .idle || connecting }
    var usesAudioResources:Bool { recognizing || cloudStage == .saving }
    @Published private(set) var recognitionRange:RevoiceRecognitionRange?
    @Published var insertionMode:SpeechInsertionMode = .replace { didSet { draftChanged() } }
    @Published private(set) var draftSaveState:DraftSaveState = .unchanged
    enum DraftSaveState:Equatable { case unchanged, pending, saved, failed(String) }
    @Published private(set) var draftWarning:String?
    private let draftStore:RevoiceDraftStore?
    private var draftSaveTask:Task<Void,Never>?
    private var recognitionTask:Task<Void,Never>?
    private var recognitionGeneration = UUID()
    private var inputGeneration = UUID()
    private var undoSpeech:(before:String,after:String,instructionBefore:AutomaticInstructionDraft?,instructionAfter:AutomaticInstructionDraft?)?
    private var recognizedInputGeneration:UUID?
    var canUndoRecognition:Bool { undoSpeech?.after == text }
    var hasRecognitionProposal:Bool { recognizedText != nil && recognizedInputGeneration == inputGeneration }
    @Published private(set) var recentJobs:[PendingRevoiceJob] = []
    var blockingJob:PendingRevoiceJob? { recentJobs.first { $0.blocksNewSubmission } }
    var onResult:((AudioAsset)->Void)?
    var beforeGenerate:(()->Void)?
    @Published private(set) var pendingJobID:UUID?
    var hasPendingJob:Bool { pendingJobID != nil }
    var pendingContext:RevoiceSaveContext? {
#if DEBUG
        if let previewPendingContext { return previewPendingContext }
#endif
        return recentJobs.first { $0.id == pendingJobID }?.context
    }
    var canGenerateDraft:Bool {
        !connecting && stage == .idle && blockingJob == nil
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
         backgroundTransfers:BackgroundRevoiceTransfers? = nil,
         draftStore:RevoiceDraftStore? = .init()) {
        self.transfers = backgroundTransfers
        self.draftStore = draftStore
        self.logger = logger; self.client = client; self.recognizer = recognizer ?? DeviceSpeechRecognizer()
        self.connection = connection; configured = connection != nil; self.saveConnection = saveConnection
        transfers?.onChange = { [weak self] job,message,asset in
            guard let self else { return }
            if let current = self.transfers?.store.job(job.id),current.transferID != job.transferID { return }
            self.recentJobs = self.transfers?.store.all() ?? []
            // Include a live write failure even when its new phase could not persist.
            if let index = self.recentJobs.firstIndex(where:{$0.id == job.id}) { self.recentJobs[index] = job }
            else { self.recentJobs.insert(job,at:0) }
            guard self.observedJobID == job.id else { return }
            self.pendingJobID = job.isPending ? job.id : nil
            self.status = message
            self.errorMessage = [.suspended,.failed].contains(job.phase) ? job.lastError : nil
            if job.phase == .saving { self.cloudStage = .saving }
            else if job.phase == .downloading || job.phase == .submitting { self.cloudStage = .generating }
            else { self.cloudStage = .idle }
            if let asset {
                self.result = asset; self.onResult?(asset)
                self.logger?.log("后台配音已保存","任务=\(job.networkID)，时长=\(asset.duration)")
            }
        }
        transfers?.onNeedsSubmission = { [weak self] job in self?.resumeSubmission(job) }
        recentJobs = transfers?.store.all() ?? []
        let loaded = draftStore?.load()
        if let draft = loaded?.draft { restoreEditingDraft(draft) }
        draftWarning = loaded?.warning ?? draftWarning
        if let job = transfers?.pending {
            observedJobID = job.id; pendingJobID = job.id
            if loaded?.existed != true { restoreDraft(job); draftChanged() }
            status = "发现未完成的配音任务，将继续取回"
        } else if let job = transfers?.store.all().first(where: { $0.isUnfinished && $0.expiresAt <= Date() }) {
            observedJobID = job.id
            if loaded?.existed != true { restoreDraft(job); draftChanged() }
            status = "任务已过期，文字已保留，可以重新生成"
        }

    }
    deinit { task?.cancel(); connectionTask?.cancel(); recognitionTask?.cancel(); draftSaveTask?.cancel() }
    func configure(_ data:Data) {
        guard !connecting,!recognizing,cloudStage != .saving else { errorMessage = "请等当前连接或保存完成，再修改连接配置"; return }
        do {
            let value = try CloudConnection.decode(data)
            connectionWarning = nil
            do { try saveConnection(value) }
            catch { connectionWarning = "本次连接可以使用，配置未能保存到钥匙串；重开 App 后需再次导入。" }
            // Pause an unconfirmed submission, keeping its ID and frozen context.
            if task != nil,let id = pendingJobID {
                generation = UUID(); task?.cancel(); task = nil; cloudStage = .idle
                transfers?.submissionFailed(id,error:RevoiceServiceError(kind:.configuration))
            }
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
                if !voices.contains(where:{$0.id == self.selectedPreset}) { self.connectionWarning = "当前服务未提供草稿所选声线，请重新选择；文字与指令已保留。" }
                if self.instructionPresetID != self.selectedPreset { self.resetPresetInstruction() }
                self.refreshAutomaticInstruction()
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
        cancelRecognition()
        inputGeneration = UUID(); input = asset; recognizedText = nil; recognizedInputGeneration = nil
        recognitionRange = asset.flatMap { RevoiceRecognitionRange.fullIfShort($0.duration) }; errorMessage = nil
        draftChanged()
        if cloudStage == .idle { status = asset == nil ? "可以录音或直接输入文字，原稿已保留" : "音频已选择，原稿保留；识别成功后按替换或追加写入" }
        return true
    }
    func recorded(_ asset:AudioAsset) {
        guard selectInput(asset) else { return }
        if foreground { recognize() }
        else { pendingRecognition = true; status = "原声已保存，返回 App 后识别" }
    }
    func forgetAsset(_ id:UUID) {
        if input?.id == id { selectInput(nil); draftWarning = "草稿的输入音频已删除，文字和指令仍保留。" }
        if result?.id == id { result = nil }
    }
    func setRecognitionRange(_ range:RevoiceRecognitionRange) {
        guard let input else { return }
        do {
            try range.validate(duration:input.duration)
            cancelRecognition(); inputGeneration = UUID(); recognizedInputGeneration = nil
            recognitionRange = range; errorMessage = nil; draftChanged()
        } catch { errorMessage = RevoiceError.message(error) }
    }
    func cancelRecognition() {
        let wasRecognizing = recognizing
        pendingRecognition = false; recognitionGeneration = UUID()
        recognitionTask?.cancel(); recognitionTask = nil; recognizer.cancel(); recognizing = false
        if wasRecognizing { status = "识别已取消，原稿已保留" }
    }
    func recognize() {
        guard !recognizing, let input else { return }
        guard let range = recognitionRange else { errorMessage = "请先打开配音页的识别片段，明确选择 0.3～60 秒人声"; return }
        let textAtStart = text
        let mode = insertionMode, inputToken = inputGeneration
        let token = UUID(); recognitionGeneration = token; recognizing = true; errorMessage = nil; status = "识别中 · 在手机处理所选片段"
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            var prepared:URL?
            defer {
                if let prepared { try? FileManager.default.removeItem(at:prepared) }
                if self.recognitionGeneration == token { self.recognizing = false; self.recognitionTask = nil }
            }
            do {
                let source = try AudioFileManager.url(for:input)
                guard FileManager.default.fileExists(atPath:source.path) else { throw LabError.message("输入音频已不存在，请在配音页重新选择；原稿已保留") }
                try range.validate(duration:input.duration)
                let work = Task.detached { try AIRequestAudio.make(url:source,range:range) }
                prepared = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation(); guard self.recognitionGeneration == token, let prepared else { return }
                let recognized = try await self.recognizer.transcribe(url:prepared)
                try Task.checkCancellation(); guard self.recognitionGeneration == token, self.inputGeneration == inputToken else { return }
                _ = try RevoiceLimits.text(recognized)
                let draftWasEdited = self.text != textAtStart
                self.recognizedText = recognized
                self.recognizedInputGeneration = inputToken
                if !draftWasEdited { self.applyRecognizedText(mode:mode) }
                self.status = draftWasEdited ? "识别已完成；编辑期间的新文字已保留，可手动替换或追加识别结果" : "识别完成，可撤销本次文字修改；确认后手动生成配音"
            } catch {
                guard self.recognitionGeneration == token else { return }
                if !Task.isCancelled { self.errorMessage = RevoiceError.message(error); self.status = "识别未完成，文字与原音频已保留" }
            }
        }
    }
    func generate() {
        if blockingJob != nil { errorMessage = "旧任务可能仍在云端执行，请在最近任务中继续取回；新草稿已保留，未提交"; flushDraft(); return }
        guard canGenerateDraft else { return }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, input != nil {
            recognize(); return
        }
        do {
            guard let connection else { throw LabError.message("请先导入云端连接配置") }
            let usedText = try RevoiceLimits.text(text)
            let choice:RevoiceChoice, label:String, effectiveInstruction:String, reference:String?
            if kind == .custom {
                guard speakers.contains(where:{$0.id == selectedSpeaker}) else { throw LabError.message("请连接支持自定义配音的云端服务") }
                effectiveInstruction = try resolvedInstruction(instruction,text:usedText)
                choice = .custom(speaker:selectedSpeaker,instruction:effectiveInstruction)
                label = speakers.first(where:{$0.id == selectedSpeaker})?.displayName ?? selectedSpeaker; reference = nil
            } else {
                guard let voice = voices.first(where:{$0.id == selectedPreset}) else { throw LabError.message("请先连接云端并选择声线") }
                let override = canEditPresetInstruction ? try resolvedInstruction(presetInstruction,text:usedText) : nil
                choice = .preset(id:voice.id,variant:voice.variant,instruction:override)
                label = voice.displayName; effectiveInstruction = override ?? voice.instruction ?? ""; reference = voice.fixedReferenceID
            }
            _ = try choice.body(text:usedText)
            let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:choice,voiceName:label,
                instruction:effectiveInstruction,fixedReferenceID:reference,recognizedText:recognizedText,
                text:usedText,sourceAudioID:input?.id,
                usesAutomaticInstruction:usesAutomaticInstruction && canUseAutomaticInstruction,
                baseInstruction:baseInstruction,
                automaticInstructionDraft:usesAutomaticInstruction && canUseAutomaticInstruction ? automaticInstructionDraft : nil)
            flushDraft()
            observedJobID = nil
            beforeGenerate?()
            result = nil; errorMessage = nil
            if let transfers,client.downloadOrigin(for:connection) != nil {
                let job = PendingRevoiceJob(context:context,primaryOrigin:try connection.validate(),
                    connectionFingerprint:connection.fingerprint)
                observedJobID = job.id
                try transfers.begin(job); pendingJobID = job.id; resumeSubmission(job)
            } else {
                let token = UUID(); generation = token; cloudStage = .generating
                status = "配音中 · 当前服务需保持 App 在前台"
                task = Task { [weak self] in
                    guard let self else { return }
                    defer { if self.generation == token { self.cloudStage = .idle; self.task = nil } }
                    do {
                        let audio = try await self.client.synthesize(connection,choice:choice,text:usedText)
                        try Task.checkCancellation(); guard self.generation == token else { return }
                        self.cloudStage = .saving; self.status = "保存中"
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
    func applyRecognizedText(mode:SpeechInsertionMode) {
        guard hasRecognitionProposal,let recognizedText else { return }
        let previous = text
        let next = mode == .append && !previous.isEmpty ? previous + "\n" + recognizedText : recognizedText
        do {
            _ = try RevoiceLimits.text(next)
            let previousInstruction = automaticInstructionDraft
            text = next; undoSpeech = (previous,next,previousInstruction,automaticInstructionDraft)
            recognizedInputGeneration = nil
            errorMessage = nil; status = "识别文字已写入，可撤销本次修改；确认后手动生成配音"
        } catch { errorMessage = RevoiceError.message(error) }
    }
    func undoRecognition() {
        guard let undoSpeech,undoSpeech.after == text else { return }
        let restoreInstruction = automaticInstructionDraft == undoSpeech.instructionAfter
        restoringDraft = true; text = undoSpeech.before
        if restoreInstruction { automaticInstructionDraft = undoSpeech.instructionBefore }
        restoringDraft = false; self.undoSpeech = nil; refreshAutomaticInstruction()
        errorMessage = nil
        status = "已撤销最近一次识别修改，原稿已恢复"
    }
    private var editingDraft:RevoiceDraft {
        var draft = RevoiceDraft()
        draft.text = text; draft.kind = kind.rawValue; draft.preset = selectedPreset; draft.speaker = selectedSpeaker
        draft.customInstruction = instruction; draft.presetInstruction = presetInstruction
        draft.instructionPresetID = instructionPresetID; draft.automatic = usesAutomaticInstruction
        draft.automaticDraft = automaticInstructionDraft; draft.inputID = input?.id
        draft.recognitionRange = recognitionRange; draft.insertionMode = insertionMode; draft.recognizedText = recognizedText
        return draft
    }
    private func restoreEditingDraft(_ draft:RevoiceDraft) {
        restoringDraft = true
        defer { restoringDraft = false }
        text = draft.text; kind = Kind(rawValue:draft.kind) ?? .preset
        selectedPreset = draft.preset; selectedSpeaker = draft.speaker
        instruction = draft.customInstruction; presetInstruction = draft.presetInstruction
        // An explicit empty preset instruction is also a saved user choice.
        instructionPresetID = draft.instructionPresetID ?? (draft.version > 0 ? draft.preset : nil)
        usesAutomaticInstruction = draft.automatic; automaticInstructionDraft = draft.automaticDraft
        recognizedText = draft.recognizedText; insertionMode = draft.insertionMode
        if let id = draft.inputID {
            input = (try? AudioFileManager.listLocalAudio())?.first { $0.id == id }
            if let input,let range = draft.recognitionRange,(try? range.validate(duration:input.duration)) != nil { recognitionRange = range }
            else if let input { recognitionRange = RevoiceRecognitionRange.fullIfShort(input.duration) }
            else { draftWarning = "草稿的输入音频已不存在，文字和指令仍保留。" }
        }
        draftSaveState = .saved
    }
    private func draftChanged() {
        guard !restoringDraft,draftStore != nil else { return }
        draftSaveTask?.cancel(); draftSaveState = .pending
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(450)) } catch { return }
            self?.flushDraft()
        }
    }
    func flushDraft() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard let draftStore else { return }
        do { try draftStore.save(editingDraft); draftSaveState = .saved }
        catch { draftSaveState = .failed("草稿保存失败，当前内容仍在内存；请检查空间后重试保存。") }
    }
    private func restoreDraft(_ job:PendingRevoiceJob) {
        restoringDraft = true
        defer { restoringDraft = false }
        usesAutomaticInstruction = job.context.usesAutomaticInstruction ?? false
        if case .custom(let speaker,let value) = job.context.choice {
            kind = .custom; selectedSpeaker = speaker; instruction = job.context.baseInstruction ?? value
        } else if case .preset(let id,_,_) = job.context.choice {
            kind = .preset; selectedPreset = id
            presetInstruction = job.context.baseInstruction ?? job.context.instruction; instructionPresetID = id
        }
        text = job.context.text; recognizedText = job.context.recognizedText
        automaticInstructionDraft = job.context.automaticInstructionDraft
        if automaticInstructionDraft == nil, usesAutomaticInstruction {
            automaticInstructionDraft = .init(text:job.context.instruction,userEdited:false,source:automaticSource)
        }
        if let source = job.context.sourceAudioID { input = (try? AudioFileManager.listLocalAudio())?.first { $0.id == source } }
        recognitionRange = input.flatMap { RevoiceRecognitionRange.fullIfShort($0.duration) }
    }
    private func resumeSubmission(_ job:PendingRevoiceJob) {
        guard task == nil,let transfers,job.isPending,transfers.store.job(job.id)?.isPending == true else { return }
        if let current = pendingJobID, current != job.id { return }
        guard let connection,connection.fingerprint == job.connectionFingerprint else {
            transfers.submissionFailed(job.id,error:RevoiceServiceError(kind:.configuration))
            return
        }
        observedJobID = job.id; pendingJobID = job.id; errorMessage = nil; cloudStage = .generating
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
                    self.cloudStage = phase == .saving ? .saving : (phase == .downloading || phase == .submitting ? .generating : .idle)
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
                        self.refreshAutomaticInstruction()
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
                if !Task.isCancelled { transfers.submissionFailed(job.id,error:error) }
            }
        }
    }
    func resumePending() {
        guard let transfers else { return }
        if let job = transfers.pending { observedJobID = job.id; pendingJobID = job.id }
        if configured && voices.isEmpty && !connecting { connect() }
        Task { await transfers.restore() }
    }
    func retrieve(_ id:UUID) {
        guard task == nil,let transfers else { errorMessage = "正在提交当前任务，请稍后继续取回"; return }
        do {
            observedJobID = id; pendingJobID = id
            try transfers.resume(id)
            recentJobs = transfers.store.all()
        } catch { pendingJobID = transfers.pending?.id; errorMessage = RevoiceError.message(error) }
    }
    func foregroundChanged(_ active:Bool) {
        foreground = active
        if !active { flushDraft() }
        transfers?.setForeground(active)
        if !active,stage == .recognizing {
            cancelRecognition()
            pendingRecognition = true; status = "原声已保留，返回 App 后继续识别"
        }
        if active {
            if pendingRecognition { pendingRecognition = false; recognize() }
            resumePending()
        }
    }
    /// Stops only cloud retrieval. Device recognition belongs to the editing draft.
    @discardableResult func stopWaiting() -> Bool {
        guard transfers?.cancel() != false else {
            pendingJobID = transfers?.pending?.id
            errorMessage = "停止等待标记无法保存，请保持 App 打开后重试"
            return false
        }
        observedJobID = nil; pendingJobID = nil
#if DEBUG
        previewPendingContext = nil
#endif
        generation = UUID(); task?.cancel(); task = nil; cloudStage = .idle
        if !recognizing { status = "已停止等待 · 已提交的云端任务可能继续完成" }
        return true
    }
    @discardableResult func cancel() -> Bool {
        guard stopWaiting() else { return false }
        cancelRecognition()
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
    func preparePreviewResult(_ asset:AudioAsset) { result = asset }
    func preparePreviewRecovery() {
        preparePreview(custom:true)
        let context = RevoiceSaveContext(id:UUID(uuidString:"16620000-0000-4000-8000-000000000012") ?? UUID(),
            createdAt:Date(),
            choice:.custom(speaker:"Serena",instruction:"轻柔、语速稍慢"),voiceName:"Serena",
            instruction:"轻柔、语速稍慢",fixedReferenceID:nil,recognizedText:nil,
            text:"这是之前已提交的配音，恢复时请继续取回这一份。",sourceAudioID:nil)
        previewPendingContext = context; pendingJobID = context.id; configured = true
        var previewJob = PendingRevoiceJob(context:context,primaryOrigin:URL(string:"https://preview.modal.run") ?? URL(fileURLWithPath:"/"),connectionFingerprint:"")
        previewJob.phase = .suspended; previewJob.lastError = "下载暂存未完成，任务已保留"; previewJob.failureKind = .network; recentJobs = [previewJob]
        selectedSpeaker = "Vivian"; instruction = "自然明亮"; text = "这是我现在编辑的新内容。"
        cloudStage = .idle; status = "配音仍在云端执行，可以继续取回"
        errorMessage = "下载暂存未完成，任务已保留"
    }
#endif
}
