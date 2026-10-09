import AVFoundation
import XCTest
@testable import AudioRelayLab

@MainActor private final class DraftSpeechRecognizer:RevoiceTranscribing {
    var calls = 0
    var failure = false
    var waits = false
    var preparedURL:URL?
    var continuation:CheckedContinuation<String,Error>?
    func transcribe(url:URL) async throws -> String {
        calls += 1; preparedURL = url
        if failure { throw LabError.message("识别夹具失败") }
        if waits { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return "新的识别文字。"
    }
    func complete() { continuation?.resume(returning:"迟到的识别文字。"); continuation = nil }
    // Deliberately ignore cancellation: the controller must reject a late result.
    func cancel() {}
}

final class RevoiceDraftTests:XCTestCase {
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("revoice-draft-\(UUID())")
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:value) }
        return value
    }
    private func input(seconds:Double = 1) throws -> AudioAsset {
        let source = try folder().appendingPathComponent("source.wav")
        var data = RevoiceTestAudio.wav(seconds:seconds)
        // Distinct beginning, middle and tail verify that complete input was decoded.
        for frame in 0..<Int(seconds*24000) {
            let sample:Int16 = frame < Int(seconds*24000/3) ? -6554 : (frame < Int(seconds*24000*2/3) ? 9830 : 19661)
            let value = UInt16(bitPattern:sample),offset = 44+frame*2
            data[offset] = UInt8(truncatingIfNeeded:value); data[offset+1] = UInt8(truncatingIfNeeded:value >> 8)
        }
        try data.write(to:source)
        let asset = try AudioFileManager.importFile(from:source)
        addTeardownBlock { try? AudioFileManager.removeAudio(asset) }
        return asset
    }
    @MainActor private func settle(_ ai:RevoiceController) async throws {
        for _ in 0..<300 where ai.recognizing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(ai.recognizing)
    }
    private func mean(_ url:URL,start:Double = 0,end:Double? = nil) throws -> Double {
        let file = try AVAudioFile(forReading:url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)))
        try file.read(into:buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let rate = file.processingFormat.sampleRate
        let first = max(Int(start*rate),min(Int(buffer.frameLength)/10,220))
        let last = min(Int((end ?? (Double(buffer.frameLength)/rate))*rate),Int(buffer.frameLength)-min(Int(buffer.frameLength)/10,220))
        XCTAssertGreaterThan(last,first)
        return (first..<last).reduce(0.0) { $0+Double(samples[$1]) }/Double(last-first)
    }
    @MainActor func testUnsubmittedTextBothInstructionsAndHandEditedAutomaticDraftRestoreWithoutRecognition() throws {
        let store = RevoiceDraftStore(directory:try folder()),asset = try input()
        let ai = RevoiceController(connection:nil,draftStore:store)
        ai.selectInput(asset); ai.kind = .custom; ai.selectedSpeaker = "Dylan"
        ai.text = "尚未提交的文字🙂。"; ai.instruction = "自然从容"; ai.presetInstruction = "保留预设基础风格"
        ai.usesAutomaticInstruction = true; ai.editAutomaticInstruction("手改指令，保留停顿"); ai.insertionMode = .append
        ai.flushDraft()
        let recognizer = DraftSpeechRecognizer()
        let restarted = RevoiceController(recognizer:recognizer,connection:nil,draftStore:store)
        XCTAssertEqual(restarted.text,ai.text); XCTAssertEqual(restarted.kind,.custom); XCTAssertEqual(restarted.selectedSpeaker,"Dylan")
        XCTAssertEqual(restarted.instruction,"自然从容"); XCTAssertEqual(restarted.presetInstruction,"保留预设基础风格")
        XCTAssertEqual(restarted.automaticInstructionDraft,ai.automaticInstructionDraft)
        XCTAssertEqual(restarted.automaticInstructionDraft?.userEdited,true); XCTAssertTrue(restarted.usesAutomaticInstruction)
        XCTAssertEqual(restarted.input?.id,asset.id)
        XCTAssertEqual(restarted.insertionMode,.append); XCTAssertEqual(recognizer.calls,0); XCTAssertFalse(restarted.busy)
        XCTAssertNil(restarted.pendingJobID); XCTAssertNil(restarted.result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:store.file)) as? [String:Any])
        XCTAssertNil(object["connection"]); XCTAssertNil(object["apiKey"]); XCTAssertNil(object["downloadToken"])
        XCTAssertNil(object["recognitionRange"]); XCTAssertEqual(object["version"] as? Int,2)
    }
    @MainActor func testDebouncedLatestEditAndImmediateBackgroundSaveAreDurable() async throws {
        let store = RevoiceDraftStore(directory:try folder()),ai = RevoiceController(connection:nil,draftStore:RevoiceDraftStore(directory:try folder()))
        let draft = RevoiceController(connection:nil,draftStore:store)
        for number in 0..<30 { draft.text = "最新编辑 \(number)" }
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(store.load().draft?.text,"最新编辑 29"); XCTAssertEqual(draft.draftSaveState,.saved)
        draft.text = "来不及等待合并写入的编辑"; draft.foregroundChanged(false)
        XCTAssertEqual(RevoiceController(connection:nil,draftStore:store).text,draft.text)
        ai.text = "无关草稿"; ai.flushDraft()
        XCTAssertEqual(store.load().draft?.text,draft.text)
    }
    @MainActor func testLegacyDamagedFieldsCorruptFileAndRecoveryCopyKeepReadableText() throws {
        let store = RevoiceDraftStore(directory:try folder())
        try Data(#"{"text":"旧版可读文字","inputID":"坏的标识","automaticDraft":7}"#.utf8).write(to:store.file)
        let legacy = RevoiceController(connection:nil,draftStore:store)
        XCTAssertEqual(legacy.text,"旧版可读文字"); XCTAssertNil(legacy.input); XCTAssertFalse(legacy.busy)
        try Data(#"{"text":"损坏文件里仍可读取的文字", BROKEN"#.utf8).write(to:store.file)
        let partial = RevoiceController(connection:nil,draftStore:store)
        XCTAssertEqual(partial.text,"损坏文件里仍可读取的文字"); XCTAssertNotNil(partial.draftWarning)
        partial.text = "原子保存的最近内容"; partial.flushDraft()
        try Data("not JSON".utf8).write(to:store.file)
        let recovered = RevoiceController(connection:nil,draftStore:store)
        XCTAssertEqual(recovered.text,"原子保存的最近内容"); XCTAssertNotNil(recovered.draftWarning)
        try FileManager.default.removeItem(at:store.file)
        try Data(#"{"text":"仅剩的损坏副本里可读文字", BROKEN"#.utf8).write(to:store.backup)
        let backupText = RevoiceController(connection:nil,draftStore:store)
        XCTAssertEqual(backupText.text,"仅剩的损坏副本里可读文字"); XCTAssertNotNil(backupText.draftWarning)
        XCTAssertTrue(store.load().existed)
    }
    @MainActor func testAutomaticMatchingDefaultsOnAndManualOffRemainsOffAfterRestart() throws {
        XCTAssertTrue(RevoiceDraft().automatic)
        let store = RevoiceDraftStore(directory:try folder()),ai = RevoiceController(connection:nil,draftStore:store)
        XCTAssertTrue(ai.usesAutomaticInstruction)
        ai.kind = .custom; ai.text = "太开心了，我们成功了！"
        XCTAssertNotNil(ai.automaticInstructionPreview)
        ai.usesAutomaticInstruction = false; ai.flushDraft()
        let restarted = RevoiceController(connection:nil,draftStore:store)
        XCTAssertFalse(restarted.usesAutomaticInstruction); XCTAssertNil(restarted.automaticInstructionPreview)
        XCTAssertEqual(restarted.text,ai.text); XCTAssertEqual(store.load().draft?.version,2)
        restarted.text += " 后来继续编辑。"; restarted.flushDraft()
        XCTAssertFalse(RevoiceController(connection:nil,draftStore:store).usesAutomaticInstruction)
    }
    @MainActor func testLegacyDraftEnablesMatchingOnceIgnoresOldRangeAndRetainsTextAndInput() throws {
        let asset = try input()
        for version in [0,1] {
            let store = RevoiceDraftStore(directory:try folder())
            let object:[String:Any] = ["version":version,"text":"升级前保存的文字","kind":"custom",
                "speaker":"Vivian","customInstruction":"原来的基础风格","automatic":false,
                "inputID":asset.id.uuidString,"recognitionRange":["start":0.2,"end":0.8],"insertionMode":"append"]
            try JSONSerialization.data(withJSONObject:object).write(to:store.file)
            let recognizer = DraftSpeechRecognizer(),migrated = RevoiceController(recognizer:recognizer,connection:nil,draftStore:store)
            XCTAssertTrue(migrated.usesAutomaticInstruction); XCTAssertEqual(migrated.text,"升级前保存的文字")
            XCTAssertNotNil(migrated.automaticInstructionPreview)
            XCTAssertEqual(migrated.instruction,"原来的基础风格"); XCTAssertEqual(migrated.input?.id,asset.id)
            XCTAssertEqual(migrated.selectedSpeaker,"Vivian"); XCTAssertEqual(migrated.insertionMode,.append)
            XCTAssertEqual(recognizer.calls,0); XCTAssertFalse(migrated.busy)
            let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:store.file)) as? [String:Any])
            XCTAssertEqual(saved["version"] as? Int,2); XCTAssertEqual(saved["automatic"] as? Bool,true)
            XCTAssertNil(saved["recognitionRange"])
            migrated.usesAutomaticInstruction = false; migrated.flushDraft()
            let restarted = RevoiceController(connection:nil,draftStore:store)
            XCTAssertFalse(restarted.usesAutomaticInstruction); XCTAssertEqual(restarted.text,migrated.text)
            XCTAssertEqual(restarted.input?.id,asset.id)
        }
    }
    @MainActor func testFrozenLegacyJobKeepsManualInstructionModeDespiteNewEditingDefault() throws {
        for automatic in [Bool?.none,.some(false)] {
            let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:.custom(speaker:"Serena",instruction:"旧任务手动表达"),
                voiceName:"Serena",instruction:"旧任务手动表达",fixedReferenceID:nil,recognizedText:nil,text:"旧任务固定原稿",
                sourceAudioID:nil,usesAutomaticInstruction:automatic)
            let store = PendingRevoiceStore(directory:try folder())
            let job = PendingRevoiceJob(context:context,primaryOrigin:try XCTUnwrap(URL(string:"https://unit-tests.modal.run")),connectionFingerprint:"test-only")
            try store.save(job)
            let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
            defer { manager.invalidateForTesting() }
            let ai = RevoiceController(connection:nil,backgroundTransfers:manager,draftStore:nil)
            XCTAssertFalse(ai.usesAutomaticInstruction); XCTAssertEqual(ai.instruction,"旧任务手动表达")
            XCTAssertEqual(ai.pendingContext?.usesAutomaticInstruction,automatic)
            XCTAssertEqual(store.job(job.id)?.context.instruction,"旧任务手动表达"); XCTAssertEqual(ai.text,"旧任务固定原稿")
            XCTAssertNil(ai.automaticInstructionDraft)
        }
    }
    @MainActor func testMissingInputKeepsTextAndInstructionsAndDoesNotRecognize() throws {
        let store = RevoiceDraftStore(directory:try folder()),asset = try input()
        let ai = RevoiceController(connection:nil,draftStore:store)
        ai.selectInput(asset); ai.kind = .custom; ai.text = "删除音频后仍保留"; ai.instruction = "手改风格"; ai.flushDraft()
        try AudioFileManager.removeAudio(asset)
        let restarted = RevoiceController(connection:nil,draftStore:store)
        XCTAssertNil(restarted.input); XCTAssertEqual(restarted.text,ai.text); XCTAssertEqual(restarted.instruction,ai.instruction)
        XCTAssertNotNil(restarted.draftWarning); XCTAssertFalse(restarted.busy)
    }
    @MainActor func testSaveFailureNeverReportsSavedAndCanRetry() throws {
        let root = try folder(),blocked = root.appendingPathComponent("blocked")
        try Data("file instead of directory".utf8).write(to:blocked)
        let store = RevoiceDraftStore(directory:blocked),ai = RevoiceController(connection:nil,draftStore:store)
        ai.text = "保存失败也不丢失内存内容"; ai.flushDraft()
        guard case .failed = ai.draftSaveState else { return XCTFail("An unsuccessful write must remain visibly failed") }
        XCTAssertEqual(ai.text,"保存失败也不丢失内存内容")
        try FileManager.default.removeItem(at:blocked); ai.flushDraft()
        XCTAssertEqual(ai.draftSaveState,.saved); XCTAssertEqual(store.load().draft?.text,ai.text)
    }
    @MainActor func testRecognitionFailureSelectionReplacementAppendAndUndoProtectOriginal() async throws {
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:nil)
        let asset = try input(); ai.kind = .custom; ai.text = "原稿"; ai.usesAutomaticInstruction = true
        ai.editAutomaticInstruction("手改表达"); let instruction = ai.automaticInstructionDraft
        ai.selectInput(asset); XCTAssertEqual(ai.text,"原稿")
        recognizer.failure = true; ai.recognize(); try await settle(ai)
        XCTAssertEqual(ai.text,"原稿"); XCTAssertEqual(ai.automaticInstructionDraft,instruction); XCTAssertNotNil(ai.errorMessage)
        recognizer.failure = false; ai.insertionMode = .replace; ai.recognize(); try await settle(ai)
        XCTAssertEqual(ai.text,"新的识别文字。"); XCTAssertTrue(ai.canUndoRecognition)
        ai.undoRecognition(); XCTAssertEqual(ai.text,"原稿"); XCTAssertEqual(ai.automaticInstructionDraft,instruction)
        ai.insertionMode = .append; ai.recognize(); try await settle(ai)
        XCTAssertEqual(ai.text,"原稿\n新的识别文字。"); ai.undoRecognition(); XCTAssertEqual(ai.text,"原稿")
        ai.text = String(repeating:"字",count:999); ai.recognize(); try await settle(ai)
        XCTAssertEqual(ai.text.unicodeScalars.count,999); XCTAssertNotNil(ai.errorMessage)
        XCTAssertTrue(ai.hasRecognitionProposal); ai.applyRecognizedText(mode:.replace)
        XCTAssertEqual(ai.text,"新的识别文字。")
    }
    @MainActor func testNewerManualEditRequiresExplicitInsertionAndUndoCannotEraseLaterTyping() async throws {
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:nil)
        ai.selectInput(try input()); ai.text = "旧稿"; recognizer.waits = true; ai.recognize()
        for _ in 0..<100 where recognizer.calls == 0 { try await Task.sleep(for:.milliseconds(10)) }
        ai.text = "识别期间的新稿"; recognizer.complete(); try await settle(ai)
        XCTAssertEqual(ai.text,"识别期间的新稿"); XCTAssertTrue(ai.hasRecognitionProposal)
        ai.applyRecognizedText(mode:.append); XCTAssertEqual(ai.text,"识别期间的新稿\n迟到的识别文字。")
        ai.text += "后来手打"; XCTAssertFalse(ai.canUndoRecognition); ai.undoRecognition()
        XCTAssertTrue(ai.text.hasSuffix("后来手打"))
    }
    @MainActor func testUndoRestoresTextWithoutDiscardingInstructionEditedAfterRecognition() async throws {
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:nil)
        ai.kind = .custom; ai.text = "识别前的原稿"; ai.usesAutomaticInstruction = true
        ai.selectInput(try input()); ai.recognize(); try await settle(ai)
        XCTAssertTrue(ai.canUndoRecognition)
        ai.editAutomaticInstruction("识别后新写的手改指令")
        ai.undoRecognition()
        XCTAssertEqual(ai.text,"识别前的原稿")
        XCTAssertEqual(ai.automaticInstructionDraft?.text,"识别后新写的手改指令")
        XCTAssertEqual(ai.automaticInstructionDraft?.userEdited,true)
        XCTAssertTrue(ai.automaticInstructionIsStale)
    }
    @MainActor func testStoppingCloudWaitLeavesConcurrentDeviceRecognitionAndDraftIntact() async throws {
        let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:.custom(speaker:"Serena",instruction:"旧表达"),
            voiceName:"Serena",instruction:"旧表达",fixedReferenceID:nil,recognizedText:nil,text:"旧任务原文",sourceAudioID:nil)
        let store = PendingRevoiceStore(directory:try folder())
        let job = PendingRevoiceJob(context:context,primaryOrigin:try XCTUnwrap(URL(string:"https://unit-tests.modal.run")),connectionFingerprint:"test-only")
        try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,backgroundTransfers:manager,draftStore:nil)
        ai.text = ""; ai.selectInput(try input()); ai.recognize(); try await settle(ai)
        XCTAssertEqual(ai.text,"新的识别文字。"); XCTAssertEqual(recognizer.calls,1)
        XCTAssertEqual(ai.pendingJobID,job.id); XCTAssertEqual(store.job(job.id)?.phase,.submitting)
        XCTAssertEqual(store.job(job.id)?.context.text,"旧任务原文"); XCTAssertEqual(store.all().count,1)
        ai.undoRecognition(); XCTAssertEqual(ai.text,"")
        ai.text = "新草稿"; recognizer.waits = true; ai.recognize()
        for _ in 0..<200 where recognizer.calls == 1 { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(recognizer.calls,2); XCTAssertTrue(ai.recognizing)
        XCTAssertTrue(ai.stopWaiting())
        XCTAssertEqual(store.job(job.id)?.phase,.abandoned); XCTAssertNil(ai.pendingJobID)
        XCTAssertTrue(ai.recognizing); XCTAssertEqual(ai.text,"新草稿")
        recognizer.complete(); try await settle(ai)
        XCTAssertEqual(ai.text,"迟到的识别文字。"); XCTAssertTrue(ai.canUndoRecognition)
        ai.undoRecognition(); XCTAssertEqual(ai.text,"新草稿")
        XCTAssertEqual(store.job(job.id)?.context.text,"旧任务原文"); XCTAssertNil(ai.result)
    }
    @MainActor func testWholeShortAudioRecognitionIncludesBeginningMiddleAndTailAndPreservesSource() async throws {
        let asset = try input(seconds:1.5),source = try AudioFileManager.url(for:asset)
        let original = try Data(contentsOf:source)
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:nil)
        recognizer.waits = true; ai.text = "完整音频识别前的原稿"; ai.selectInput(asset); ai.recognize()
        for _ in 0..<200 where recognizer.calls == 0 { try await Task.sleep(for:.milliseconds(10)) }
        let prepared = try XCTUnwrap(recognizer.preparedURL)
        let file = try AVAudioFile(forReading:prepared)
        XCTAssertEqual(Double(file.length)/file.processingFormat.sampleRate,1.5,accuracy:2.0/22050)
        XCTAssertEqual(try mean(prepared,start:0.1,end:0.4),-0.2,accuracy:0.02)
        XCTAssertEqual(try mean(prepared,start:0.6,end:0.9),0.3,accuracy:0.02)
        XCTAssertEqual(try mean(prepared,start:1.1,end:1.4),0.6,accuracy:0.02)
        recognizer.complete(); try await settle(ai)
        XCTAssertEqual(ai.text,"迟到的识别文字。"); XCTAssertEqual(recognizer.calls,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:prepared.path))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    func testFullAudioMinimumMaximumAndOverlongInputAreEnforcedWithoutClipping() throws {
        for seconds in [0.3,60.0] {
            let asset = try input(seconds:seconds),source = try AudioFileManager.url(for:asset)
            let prepared = try AIRequestAudio.make(url:source)
            defer { try? FileManager.default.removeItem(at:prepared) }
            let file = try AVAudioFile(forReading:prepared),duration = Double(file.length)/file.processingFormat.sampleRate
            XCTAssertEqual(duration,seconds,accuracy:2.0/22050); XCTAssertLessThanOrEqual(duration,60)
            XCTAssertEqual(try mean(prepared,start:seconds*0.75,end:seconds*0.9),0.6,accuracy:0.02)
        }
        for seconds in [0.299,60.001,90.0] {
            let source = try AudioFileManager.url(for:input(seconds:seconds))
            XCTAssertThrowsError(try AIRequestAudio.make(url:source))
        }
    }
    @MainActor func testLongInputRecognitionRejectsWithoutTruncatingAndKeepsDraftAndOriginalAudio() async throws {
        let recognizer = DraftSpeechRecognizer(),store = RevoiceDraftStore(directory:try folder())
        let ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:store)
        let asset = try input(seconds:90),source = try AudioFileManager.url(for:asset),original = try Data(contentsOf:source)
        // Recognition must validate the file itself, even when stale library metadata looks short.
        var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(asset)) as? [String:Any])
        metadata["duration"] = 1
        let stale = try JSONDecoder().decode(AudioAsset.self,from:JSONSerialization.data(withJSONObject:metadata))
        ai.kind = .custom; ai.text = "超长识别不能截断或覆盖的原稿"; ai.editAutomaticInstruction("保留手改表达")
        let instruction = ai.automaticInstructionDraft
        ai.selectInput(stale); ai.recognize(); try await settle(ai); ai.flushDraft()
        XCTAssertEqual(recognizer.calls,0); XCTAssertNil(recognizer.preparedURL); XCTAssertNotNil(ai.errorMessage)
        XCTAssertTrue(ai.errorMessage?.contains("0.3～60 秒") == true)
        XCTAssertEqual(ai.text,"超长识别不能截断或覆盖的原稿"); XCTAssertEqual(ai.automaticInstructionDraft,instruction)
        XCTAssertEqual(ai.input?.id,asset.id); XCTAssertNil(ai.recognizedText); XCTAssertFalse(ai.busy)
        XCTAssertEqual(store.load().draft?.text,ai.text); XCTAssertEqual(try Data(contentsOf:source),original)
    }
    @MainActor func testInputGenerationRejectsLateFullRecognitionAndCleansTemporary() async throws {
        let recognizer = DraftSpeechRecognizer(),ai = RevoiceController(recognizer:recognizer,connection:nil,draftStore:nil)
        let previous = try input(seconds:1.5),next = try input()
        ai.text = "不允许迟到识别覆盖"; ai.selectInput(previous)
        recognizer.waits = true; ai.recognize()
        for _ in 0..<200 where recognizer.calls == 0 { try await Task.sleep(for:.milliseconds(10)) }
        let temporary = try XCTUnwrap(recognizer.preparedURL)
        XCTAssertEqual(try mean(temporary,start:1.1,end:1.4),0.6,accuracy:0.02)
        ai.selectInput(next); recognizer.complete()
        for _ in 0..<100 where FileManager.default.fileExists(atPath:temporary.path) { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(ai.text,"不允许迟到识别覆盖"); XCTAssertEqual(ai.input?.id,next.id); XCTAssertNil(ai.recognizedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath:temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:previous).path))
    }
    @MainActor func testPlaybackAndMixChangesCannotChangeWholeRecognitionInput() throws {
        let coordinator = ExperimentCoordinator(draftStore:nil),asset = try input(seconds:1.5)
        let originalSelection = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(originalSelection,forKey:"selectedAudio") }
        try coordinator.selectAudio(asset); coordinator.revoice.selectInput(asset)
        coordinator.editing = .init(startOffset:0.5,playbackRate:2,volume:0.1,endOffset:1); coordinator.applyPlaybackSettings()
        coordinator.voiceMix.settings = .init(startOffset:0.3,playbackRate:0.5,endOffset:1)
        let selected = try XCTUnwrap(coordinator.revoice.input),source = try AudioFileManager.url(for:selected)
        let prepared = try AIRequestAudio.make(url:source)
        defer { try? FileManager.default.removeItem(at:prepared) }
        let file = try AVAudioFile(forReading:prepared)
        XCTAssertEqual(Double(file.length)/file.processingFormat.sampleRate,1.5,accuracy:2.0/22050)
        XCTAssertEqual(try mean(prepared,start:0.1,end:0.4),-0.2,accuracy:0.02)
        XCTAssertEqual(try mean(prepared,start:1.1,end:1.4),0.6,accuracy:0.02)
        XCTAssertEqual(selected.id,asset.id)
    }
    @MainActor func testRecordingPermissionDenialAndPreparationFailureKeepDraftAndInput() async throws {
        for granted in [false,true] {
            let logger = DiagnosticsLogger(),session = AudioSessionManager(logger:logger)
            let recorder = RawVoiceRecorder(session:session,logger:logger,requestPermission:{granted},recorderFactory:{ _,_ in throw LabError.message("录音准备夹具失败") })
            let ai = RevoiceController(connection:nil,draftStore:nil),asset = try input()
            ai.selectInput(asset); ai.text = "录音失败之前的原稿"; ai.kind = .custom; ai.instruction = "原表达"
            recorder.onSaved = { asset,_ in ai.recorded(asset) }
            recorder.start(.revoice)
            for _ in 0..<200 where recorder.isActive { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertEqual(recorder.state,.failed); XCTAssertNotNil(recorder.errorMessage)
            XCTAssertEqual(ai.text,"录音失败之前的原稿"); XCTAssertEqual(ai.instruction,"原表达"); XCTAssertEqual(ai.input?.id,asset.id)
        }
    }
    @MainActor func testCancelWhilePermissionIsPendingDoesNotChangeDraftOrResumeRecording() async throws {
        let logger = DiagnosticsLogger(),session = AudioSessionManager(logger:logger)
        var permission:CheckedContinuation<Bool,Never>?
        let recorder = RawVoiceRecorder(session:session,logger:logger,requestPermission:{ await withCheckedContinuation { permission = $0 } })
        let ai = RevoiceController(connection:nil,draftStore:nil); ai.text = "取消录音时保留"
        recorder.onSaved = { asset,_ in ai.recorded(asset) }; recorder.start(.revoice)
        for _ in 0..<100 where permission == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(permission); recorder.stop(saveRecording:false); permission?.resume(returning:true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(recorder.state,.idle); XCTAssertFalse(recorder.isActive); XCTAssertEqual(ai.text,"取消录音时保留"); XCTAssertNil(ai.input)
    }
}
