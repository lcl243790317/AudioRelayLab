import AVFoundation
import CryptoKit
import XCTest
@testable import AudioRelayLab

enum RevoiceTestAudio {
    static func wav(seconds:Double) -> Data {
        var data = Data()
        func append(_ value:UInt32, bytes:Int) { for n in 0..<bytes { data.append(UInt8(truncatingIfNeeded:value >> (n*8))) } }
        let count = UInt32(seconds*48000)
        data.append(Data("RIFF".utf8)); append(count+36,bytes:4); data.append(Data("WAVEfmt ".utf8))
        append(16,bytes:4);append(1,bytes:2);append(1,bytes:2);append(24000,bytes:4)
        append(48000,bytes:4);append(2,bytes:2);append(16,bytes:2);data.append(Data("data".utf8));append(count,bytes:4)
        var samples = Data(repeating:0,count:Int(count))
        for i in stride(from:0,to:min(48000,samples.count),by:2) { samples[i] = 0x00; samples[i+1] = 0x20 }
        data.append(samples); return data
    }
    static func response(_ data:Data,choice:RevoiceChoice = .preset(id:"serena-original",variant:"custom"),duration:Double) throws -> HTTPURLResponse {
        var headers = ["Content-Type":"audio/wav","X-Audio-SHA256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),
            "X-Audio-Duration":String(duration),"X-Audio-Sample-Rate":"24000","X-Model-Variant":choice.variant,
            "X-Voice-ID":choice.voiceID,"X-Generation-Mode":choice.mode,"X-Model-Revision":String(repeating:"a",count:40),
            "X-Generation-Seconds":"0.1"]
        headers["X-Speaker-ID"] = choice.speakerID ?? "Serena"
        return try XCTUnwrap(HTTPURLResponse(url:URL(string:"https://unit-tests.modal.run/v1/tts") ?? URL(fileURLWithPath:"/"),statusCode:200,httpVersion:nil,headerFields:headers))
    }
}

private final class RevoiceHTTPState: @unchecked Sendable {
    let lock = NSLock()
    var data = RevoiceTestAudio.wav(seconds:1)
    var submissions:[[String:String]] = []
    var failNext = false
    var redirect:String?
    var customSupported = true
    var presetInstructionSupported = false
    var asyncJobs = false
    var failAfterSubmission = false
    var methods:[String] = []
    var responseStatus = 200
    var responseDelay = 0.0
    var invalidVoices = false
    func reset() { lock.lock();defer{lock.unlock()};data = RevoiceTestAudio.wav(seconds:1);submissions=[];failNext=false;redirect=nil;customSupported=true;presetInstructionSupported=false;methods=[];responseStatus=200;responseDelay=0;asyncJobs=false;failAfterSubmission=false;invalidVoices=false }
    func respond(_ request:URLRequest) throws -> (Data,Int,[String:String]) {
        lock.lock();defer{lock.unlock()}
        let path = request.url?.path ?? ""
        if path == "/v1/health" {
            return (try JSONSerialization.data(withJSONObject:["status":"ok","capabilities":["customTTS":customSupported,"textOnly":true,"asyncJobs":asyncJobs,"presetInstruction":presetInstructionSupported],"jobDownloadOrigin":"https://unit-download.modal.run"]),200,[:])
        }
        if path == "/v1/voices" {
            if invalidVoices { return (Data("{\"voices\":[]}".utf8),200,[:]) }
            return (try JSONEncoder().encode(CloudRevoiceClient.VoicesForTests()),200,[:])
        }
        if path == "/v1/speakers" {
            return (try JSONSerialization.data(withJSONObject:["speakers":RevoiceSpeaker.all.map{["id":$0.id,"displayName":$0.displayName]}]),200,[:])
        }
        methods.append(request.httpMethod ?? "")
        if path.hasSuffix("/audio") { throw URLError(.networkConnectionLost) }
        if request.httpMethod == "POST" {
            if failNext { failNext=false;throw URLError(.networkConnectionLost) }
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open();defer{stream.close()}
                var buffer = [UInt8](repeating:0,count:8192)
                let count = stream.read(&buffer,maxLength:buffer.count)
                if count>0 { body.append(contentsOf:buffer.prefix(count)) }
            }
            let values = try XCTUnwrap(try JSONSerialization.jsonObject(with:body) as? [String:String])
            submissions.append(values)
            if path == "/v1/jobs",responseStatus != 200 { return (Data(),responseStatus,[:]) }
            if failAfterSubmission { failAfterSubmission=false; throw URLError(.networkConnectionLost) }
            if let redirect { return (Data(),303,["Location":redirect]) }
        }
        if path.hasPrefix("/v1/jobs"),let value = submissions.last?["requestID"],let id = UUID(uuidString:value) {
            let networkID = id.uuidString.replacingOccurrences(of:"-",with:"").lowercased(), now = Date().timeIntervalSince1970
            let reply = CloudJobReply(id:networkID,state:"queued",createdAt:now,expiresAt:now+86400,
                downloadURL:try XCTUnwrap(URL(string:"https://unit-download.modal.run/v1/jobs/"+networkID+"/audio")),
                downloadToken:String(repeating:"a",count:64),error:nil)
            return (try JSONEncoder().encode(reply),request.httpMethod == "POST" ? 202 : 200,[:])
        }
        if responseStatus != 200 { return (Data(),responseStatus,[:]) }
        let values = submissions.last ?? [:]
        let choice:RevoiceChoice = values["speaker"].map{.custom(speaker:$0,instruction:values["instruction"] ?? "")} ??
            .preset(id:values["voice"] ?? "serena-original",variant:values["voice"] == "scholar-design" ? "base" : "custom")
        let response = try RevoiceTestAudio.response(data,choice:choice,duration:Double(data.count-44)/48000)
        return (data,200,response.allHeaderFields.reduce(into:[String:String]()){ if let name = $1.key as? String { $0[name] = String(describing:$1.value) } })
    }
}

private extension CloudRevoiceClient {
    struct VoicesForTests:Encodable {
        let voices:[RevoiceVoice] = [.init(id:"serena-original",displayName:"Serena",variant:"custom",instruction:"默认自然表达",supportsInstruction:true),.init(id:"scholar-design",displayName:"书生",variant:"base",supportsInstruction:false)]
    }
}

private final class RevoiceHTTPProtocol:URLProtocol,@unchecked Sendable {
    static let state = RevoiceHTTPState()
    private var completion:DispatchWorkItem?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (data,status,headers) = try Self.state.respond(request)
            let response = try XCTUnwrap(HTTPURLResponse(url:try XCTUnwrap(request.url),statusCode:status,httpVersion:nil,headerFields:headers))
            let delivery = DispatchWorkItem { [weak self] in
                guard let self, self.completion?.isCancelled != true else { return }
                self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:data);self.client?.urlProtocolDidFinishLoading(self)
            }
            completion = delivery
            if Self.state.responseDelay > 0 { DispatchQueue.global().asyncAfter(deadline:.now()+Self.state.responseDelay,execute:delivery) }
            else { delivery.perform() }
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { completion?.cancel() }
}

@MainActor private final class RevoiceTestRecognizer:RevoiceTranscribing {
    var calls = 0
    var delay = false
    var failure = false
    func transcribe(url:URL) async throws -> String {
        calls += 1
        if delay { try await Task.sleep(for:.seconds(2)) }
        if failure { throw LabError.message("设备端识别暂不可用，请手动输入文字") }
        return "嗯，我，我想明天再去。"
    }
    func cancel() {}
}

final class RevoiceTests:XCTestCase {
    @MainActor func testBusyRejectionIsNotAcceptedAndManualRetryKeepsFrozenID() async throws {
        try await exerciseAsync { ai,_,_,store in
            ai.kind = .custom; ai.text = "请求中的固定文字"; ai.instruction = "固定表达"
            RevoiceHTTPProtocol.state.responseStatus = 429; ai.generate(); try await self.settle(ai)
            let first = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.first)
            let id = try XCTUnwrap(first["requestID"].flatMap(UUID.init(uuidString:)))
            let rejected = try XCTUnwrap(store.job(id))
            XCTAssertEqual(rejected.phase,.failed); XCTAssertEqual(rejected.failureKind,.busy)
            XCTAssertEqual(rejected.submissionRejected,true); XCTAssertNil(rejected.reply); XCTAssertNil(ai.pendingJobID)
            XCTAssertTrue(ai.errorMessage?.contains("未被接受") == true); XCTAssertTrue(ai.canGenerateDraft)
            ai.text = "以后编辑的新文字"; ai.selectedSpeaker = "Vivian"; ai.instruction = "新表达"
            RevoiceHTTPProtocol.state.responseStatus = 200; RevoiceHTTPProtocol.state.failAfterSubmission = true
            ai.retrieve(id); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last,first); XCTAssertEqual(ai.pendingJobID,id)
            XCTAssertEqual(ai.text,"以后编辑的新文字"); XCTAssertEqual(ai.selectedSpeaker,"Vivian")
        }
    }
    @MainActor func testConfigurationCanBeRepairedWhileFrozenTaskIsRetained() async throws {
        try await exerciseAsync { ai,_,_,store in
            ai.kind = .custom; ai.text = "旧服务中的固定文字"; RevoiceHTTPProtocol.state.failAfterSubmission = true
            ai.generate(); try await self.settle(ai)
            let id = try XCTUnwrap(ai.pendingJobID),body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.first)
            ai.text = "新的编辑草稿"
            let changed = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"z",count:48))
            ai.configure(try JSONEncoder().encode(changed)); try await self.settle(ai)
            ai.retrieve(id); try await self.settle(ai)
            XCTAssertEqual(store.job(id)?.failureKind,.configuration); XCTAssertEqual(ai.text,"新的编辑草稿")
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            let original = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
            ai.configure(try JSONEncoder().encode(original)); try await self.settle(ai)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.retrieve(id); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last,body); XCTAssertEqual(ai.pendingJobID,id)
            XCTAssertEqual(ai.text,"新的编辑草稿")
        }
    }
    @MainActor func testForgettingDeletedSourcePreservesFrozenJobAndCurrentTextDraft() async throws {
        try await exerciseAsync { ai,_,_,store in
            let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
            let source = try AudioFileManager.importFile(from:fixture)
            defer { try? AudioFileManager.removeAudio(source) }
            ai.selectInput(source); ai.kind = .custom; ai.text = "已提交的话。"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let id = try XCTUnwrap(ai.pendingJobID), context = try XCTUnwrap(store.job(id)?.context)
            ai.text = "之后手改的草稿。"; ai.forgetAsset(source.id)
            XCTAssertNil(ai.input); XCTAssertEqual(ai.text,"之后手改的草稿。")
            XCTAssertEqual(ai.pendingJobID,id); XCTAssertEqual(store.job(id)?.context.id,context.id)
            XCTAssertEqual(store.job(id)?.context.text,context.text); XCTAssertEqual(store.job(id)?.context.choice,context.choice)
            XCTAssertEqual(context.sourceAudioID,source.id); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
        }
    }
    @MainActor func testSwitchesTextEditsAndForegroundNeverSubmitNewSpeech() async throws {
        try await exercise { ai,_,_ in
            ai.kind = .custom; ai.text = "太开心了！"; ai.usesAutomaticInstruction = true
            ai.text = "现在放慢一点。"; ai.usesAutomaticInstruction = false; ai.usesAutomaticInstruction = true
            ai.foregroundChanged(false); ai.foregroundChanged(true); try await self.settle(ai)
            XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty); XCTAssertNil(ai.pendingJobID)
            ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
        }
    }
    @MainActor func testEditedAutomaticDraftPersistsAcrossContentChangesAndOffOn() async throws {
        try await exercise { ai,_,_ in
            ai.kind = .custom; ai.instruction = "基础角色风格"; ai.text = "很开心！"; ai.usesAutomaticInstruction = true
            ai.editAutomaticInstruction("  慢一点。\n句间留白  ")
            let edited = try XCTUnwrap(ai.automaticInstructionDraft)
            ai.text = "请认真听。"; ai.instruction = "新的基础风格"
            XCTAssertEqual(ai.automaticInstructionDraft,edited); XCTAssertTrue(ai.automaticInstructionIsStale)
            ai.usesAutomaticInstruction = false; ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],"新的基础风格")
            ai.usesAutomaticInstruction = true
            XCTAssertEqual(ai.automaticInstructionDraft,edited)
            ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],edited.text)
            XCTAssertEqual(ai.result?.revoice?.instruction,edited.text)
            ai.rematchAutomaticInstruction()
            XCTAssertFalse(ai.automaticInstructionDraft?.userEdited ?? true); XCTAssertFalse(ai.automaticInstructionIsStale)
            XCTAssertNotEqual(ai.automaticInstructionDraft?.text,edited.text)
        }
    }
    @MainActor func testClearedAutomaticInstructionMeansNaturalExpressionAndOverlongDraftRejects() async throws {
        try await exercise { ai,_,_ in
            ai.kind = .custom; ai.instruction = "温润"; ai.text = "你好。"; ai.usesAutomaticInstruction = true
            ai.editAutomaticInstruction(""); ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],"")
            ai.editAutomaticInstruction(String(repeating:"字",count:501)); ai.generate()
            XCTAssertNotNil(ai.errorMessage); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
        }
    }
    @MainActor func testEditedDraftRequiresConfirmationForAllVoiceSelectionTypes() async throws {
        try await exercise { ai,_,_ in
            ai.kind = .custom; ai.text = "你好。"; ai.usesAutomaticInstruction = true; ai.editAutomaticInstruction("我的指令")
            ai.requestVoiceSelection(.speaker("Vivian"),deferConfirmation:true)
            XCTAssertNil(ai.pendingVoiceSelection); XCTAssertEqual(ai.selectedSpeaker,"Serena")
            ai.presentDeferredVoiceSelection(); XCTAssertEqual(ai.pendingVoiceSelection,.speaker("Vivian"))
            ai.cancelVoiceSelection(); XCTAssertEqual(ai.selectedSpeaker,"Serena"); XCTAssertEqual(ai.automaticInstructionPreview,"我的指令")
            ai.requestVoiceSelection(.speaker("Vivian")); ai.confirmVoiceSelection()
            XCTAssertEqual(ai.selectedSpeaker,"Vivian"); XCTAssertEqual(ai.automaticInstructionDraft?.source.voiceID,"Vivian")
            XCTAssertFalse(ai.automaticInstructionDraft?.userEdited ?? true)
            ai.editAutomaticInstruction("保留这段"); ai.requestVoiceSelection(.mode(.preset)); ai.cancelVoiceSelection()
            XCTAssertEqual(ai.kind,.custom); XCTAssertEqual(ai.automaticInstructionPreview,"保留这段")
            ai.requestVoiceSelection(.mode(.preset)); ai.confirmVoiceSelection(); XCTAssertEqual(ai.kind,.preset)
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            ai.editAutomaticInstruction("预设手改"); ai.requestVoiceSelection(.preset("scholar-design")); ai.cancelVoiceSelection()
            XCTAssertEqual(ai.selectedPreset,"serena-original"); XCTAssertEqual(ai.automaticInstructionPreview,"预设手改")
            ai.requestVoiceSelection(.preset("scholar-design")); ai.confirmVoiceSelection()
            XCTAssertEqual(ai.selectedPreset,"scholar-design"); XCTAssertNil(ai.automaticInstructionDraft)
            XCTAssertFalse(ai.canUseAutomaticInstruction); XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
        }
    }
    @MainActor func testBackgroundRecordingRecognizesOnForegroundWithoutSynthesis() async throws {
        try await exercise { ai,recognizer,input in
            ai.foregroundChanged(false); ai.recorded(input)
            XCTAssertEqual(recognizer.calls,0); XCTAssertTrue(ai.text.isEmpty)
            ai.foregroundChanged(true); try await self.settle(ai)
            XCTAssertEqual(recognizer.calls,1); XCTAssertFalse(ai.text.isEmpty)
            XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty); XCTAssertNil(ai.result)
        }
    }
    @MainActor func testEditedAutomaticDraftIsFrozenRestoredAndRecoveryDoesNotUseNewEdits() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.text = "提交前的文字。"; ai.usesAutomaticInstruction = true
            ai.editAutomaticInstruction("  保留停顿。\n自然咬字  ")
            let draft = try XCTUnwrap(ai.automaticInstructionDraft)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let id = try XCTUnwrap(ai.pendingJobID), body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(store.job(id)?.context.automaticInstructionDraft,draft)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
            let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
            let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",
                proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
            let restarted = RevoiceController(client:CloudRevoiceClient(session:session),recognizer:RevoiceTestRecognizer(),
                connection:connection,saveConnection:{_ in},backgroundTransfers:manager,draftStore:nil)
            defer { restarted.cancel() }
            XCTAssertEqual(restarted.automaticInstructionDraft,draft)
            restarted.text = "后来修改的正文。"; restarted.editAutomaticInstruction("新的表达")
            RevoiceHTTPProtocol.state.failAfterSubmission = true; restarted.resumePending()
            try await self.waitForSubmissions(2); try await self.settle(restarted)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last,body)
            XCTAssertEqual(restarted.automaticInstructionDraft?.text,"新的表达"); XCTAssertEqual(restarted.pendingJobID,id)
            XCTAssertEqual(store.job(id)?.context.automaticInstructionDraft,draft)
        }
    }
    @MainActor func testAutomaticCustomInstructionUsesLatestTextWithoutChangingManualDraft() async throws {
        try await exercise { ai,recognizer,_ in
            XCTAssertTrue(ai.usesAutomaticInstruction)
            ai.kind = .custom; ai.selectedSpeaker = "Vivian"; ai.instruction = "保留明亮的角色声线"
            ai.text = "终于成功了，太开心了！"
            let expected = try XCTUnwrap(ai.automaticInstructionPreview)
            ai.generate(); try await self.settle(ai)
            let first = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(first["instruction"],expected); XCTAssertEqual(first["text"],ai.text)
            XCTAssertEqual(first["speaker"],"Vivian"); XCTAssertEqual(ai.instruction,"保留明亮的角色声线")
            XCTAssertEqual(ai.result?.revoice?.instruction,expected)
            XCTAssertEqual(ai.result?.revoice?.usesAutomaticInstruction,true)
            ai.text = "我很难过，真的舍不得你。"
            let changed = try XCTUnwrap(ai.automaticInstructionPreview); XCTAssertNotEqual(changed,expected)
            ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],changed)
            ai.usesAutomaticInstruction = false; ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],"保留明亮的角色声线")
            XCTAssertEqual(ai.result?.revoice?.usesAutomaticInstruction,false); XCTAssertEqual(recognizer.calls,0)
        }
    }
    @MainActor func testAutomaticPresetNeverOverridesFixedReferenceOrLegacyServer() async throws {
        try await exercise { ai,_,_ in
            XCTAssertTrue(ai.usesAutomaticInstruction); ai.text = "太开心了！"
            XCTAssertFalse(ai.canUseAutomaticInstruction); XCTAssertNil(ai.automaticInstructionPreview)
            ai.generate(); try await self.settle(ai)
            XCTAssertNil(RevoiceHTTPProtocol.state.submissions.last?["instruction"])
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            XCTAssertTrue(ai.canUseAutomaticInstruction)
            let expected = try XCTUnwrap(ai.automaticInstructionPreview)
            ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],expected)
            ai.selectedPreset = "scholar-design"
            XCTAssertFalse(ai.canUseAutomaticInstruction); XCTAssertNil(ai.automaticInstructionPreview)
            ai.generate(); try await self.settle(ai)
            XCTAssertNil(RevoiceHTTPProtocol.state.submissions.last?["instruction"])
            XCTAssertEqual(ai.result?.revoice?.usesAutomaticInstruction,false)
        }
    }
    @MainActor func testAutomaticInstructionUsesDeviceRecognizedText() async throws {
        try await exercise { ai,recognizer,input in
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            XCTAssertTrue(ai.usesAutomaticInstruction); ai.selectInput(input); ai.recognize()
            try await self.settle(ai)
            XCTAssertEqual(recognizer.calls,1); XCTAssertEqual(ai.text,"嗯，我，我想明天再去。")
            let expected = RevoiceAutomaticInstruction.make(text:ai.text,baseInstruction:ai.presetInstruction)
            XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty); XCTAssertNil(ai.result)
            ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],expected)
            XCTAssertEqual(ai.result?.revoice?.recognizedText,ai.text)
        }
    }
    @MainActor func testAutomaticPendingInstructionStaysFrozenAndRestartRestoresBaseDraft() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.usesAutomaticInstruction = true; ai.instruction = "温润的角色风格"
            ai.text = "太开心了，我们成功了！"; let expected = try XCTUnwrap(ai.automaticInstructionPreview)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let previous = try XCTUnwrap(ai.pendingJobID), frozen = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(store.job(previous)?.context.instruction,expected)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
            let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
            let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",
                proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
            let restarted = RevoiceController(client:CloudRevoiceClient(session:session),recognizer:RevoiceTestRecognizer(),
                connection:connection,saveConnection:{_ in},backgroundTransfers:manager,draftStore:nil)
            defer { restarted.cancel() }
            XCTAssertTrue(restarted.usesAutomaticInstruction); XCTAssertEqual(restarted.instruction,"温润的角色风格")
            XCTAssertEqual(restarted.automaticInstructionPreview,expected)
            restarted.text = "我很难过。"; restarted.instruction = "新的角色风格"; restarted.usesAutomaticInstruction = false
            RevoiceHTTPProtocol.state.failAfterSubmission = true; restarted.resumePending()
            try await self.waitForSubmissions(2); try await self.settle(restarted)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last,frozen)
            XCTAssertEqual(restarted.text,"我很难过。"); XCTAssertEqual(restarted.instruction,"新的角色风格")
            restarted.usesAutomaticInstruction = true; restarted.instruction = String(repeating:"字",count:501)
            restarted.generate(); XCTAssertEqual(restarted.pendingJobID,previous)
            XCTAssertNotNil(restarted.errorMessage); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,2)
        }
    }
    func testLegacySaveContextDecodesWithManualInstructionMode() throws {
        let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:.custom(speaker:"Serena",instruction:"旧指令"),
            voiceName:"Serena",instruction:"旧指令",fixedReferenceID:nil,recognizedText:nil,text:"旧文字。",sourceAudioID:nil)
        let decoded = try JSONDecoder().decode(RevoiceSaveContext.self,from:JSONEncoder().encode(context))
        XCTAssertNil(decoded.usesAutomaticInstruction); XCTAssertNil(decoded.baseInstruction)
        XCTAssertEqual(decoded.instruction,"旧指令")
    }
    func testLegacyPresetChoiceDecodesWithoutInstructionAndNewOverrideRoundTrips() throws {
        let old = Data("{\"preset\":{\"id\":\"serena-original\",\"variant\":\"custom\"}}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(RevoiceChoice.self,from:old),.preset(id:"serena-original",variant:"custom"))
        for value in ["","  原样指令。\n放松  "] {
            let choice = RevoiceChoice.preset(id:"serena-original",variant:"custom",instruction:value)
            XCTAssertEqual(try JSONDecoder().decode(RevoiceChoice.self,from:JSONEncoder().encode(choice)),choice)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with:choice.body(text:"你好。")) as? [String:String])
            XCTAssertEqual(body["instruction"],value); XCTAssertEqual(body["voice"],"serena-original")
        }
        XCTAssertThrowsError(try RevoiceChoice.preset(id:"scholar-design",variant:"base",instruction:"").body(text:"你好。"))
    }
    @MainActor func testPresetInstructionResetsOnSwitchButConnectionRefreshKeepsDraft() async throws {
        try await exercise { ai,_,_ in
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            XCTAssertTrue(ai.canEditPresetInstruction); XCTAssertEqual(ai.presetInstruction,"默认自然表达")
            ai.presetInstruction = "  新表达。  "; ai.instruction = "独立自定义指令"
            ai.connect(); try await self.settle(ai); XCTAssertEqual(ai.presetInstruction,"  新表达。  ")
            ai.selectedPreset = "scholar-design"; XCTAssertFalse(ai.canEditPresetInstruction)
            ai.selectedPreset = "serena-original"; XCTAssertEqual(ai.presetInstruction,"默认自然表达")
            ai.presetInstruction = "临时编辑"; ai.kind = .custom; ai.kind = .preset
            XCTAssertEqual(ai.presetInstruction,"默认自然表达"); XCTAssertEqual(ai.instruction,"独立自定义指令")
            ai.presetInstruction = "编辑"; ai.resetPresetInstruction(); XCTAssertEqual(ai.presetInstruction,"默认自然表达")
        }
    }
    @MainActor func testPresetOverrideUsesLatestDraftAndEmptyClearsDefaultWithoutRecognition() async throws {
        try await exercise { ai,recognizer,_ in
            ai.usesAutomaticInstruction = false
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            for instruction in ["  慵懒、自然。  ",""] {
                ai.presetInstruction = instruction; ai.text = "嗯，我，我刚刚更新了文字。"
                ai.generate(); try await self.settle(ai)
                let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
                XCTAssertEqual(body,["voice":"serena-original","text":ai.text,"instruction":instruction])
                XCTAssertEqual(ai.result?.revoice?.instruction,instruction)
                XCTAssertEqual(ai.result?.revoice?.voiceID,"serena-original"); XCTAssertEqual(recognizer.calls,0)
            }
        }
    }
    @MainActor func testOldServerKeepsDefaultPresetAndNeverSendsUnsupportedOverride() async throws {
        try await exercise { ai,_,_ in
            XCTAssertFalse(ai.canEditPresetInstruction); ai.text = "你好。"; ai.generate(); try await self.settle(ai)
            XCTAssertNil(RevoiceHTTPProtocol.state.submissions.last?["instruction"])
            XCTAssertEqual(ai.result?.revoice?.instruction,"默认自然表达")
        }
    }
    @MainActor func testPresetPendingTaskKeepsFrozenOverrideWhileNewDraftChanges() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.usesAutomaticInstruction = false
            RevoiceHTTPProtocol.state.presetInstructionSupported = true; ai.connect(); try await self.settle(ai)
            ai.text = "旧配音文字。"; ai.presetInstruction = "旧表达"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let old = try XCTUnwrap(ai.pendingJobID)
            ai.text = "最新文字。"; ai.presetInstruction = "  新表达。  "
            ai.connect(); try await self.settle(ai)
            XCTAssertEqual(ai.presetInstruction,"  新表达。  "); XCTAssertEqual(store.job(old)?.context.instruction,"旧表达")
            ai.generate(); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            XCTAssertEqual(ai.pendingJobID,old); XCTAssertEqual(ai.text,"最新文字。")
            try self.finishPending(manager,store,id:old)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["instruction"],"  新表达。  ")
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.last?["text"],"最新文字。")
            XCTAssertEqual(store.job(old)?.phase,.failed)
        }
    }
    func testAsyncSubmissionResponseLossRecoversSameIDAndFrozenTextOnlyParameters() async throws {
        RevoiceHTTPProtocol.state.reset(); RevoiceHTTPProtocol.state.asyncJobs = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel(); RevoiceHTTPProtocol.state.reset() }
        let client = CloudRevoiceClient(session:session)
        let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",
            proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
        _ = try await client.connect(connection)
        let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:.custom(speaker:"Serena",instruction:"  慵懒  "),
            voiceName:"Serena",instruction:"  慵懒  ",fixedReferenceID:nil,recognizedText:"原识别文字",text:"嗯，我，我没连上 Wi-Fi。",sourceAudioID:UUID())
        RevoiceHTTPProtocol.state.failAfterSubmission = true
        do { _ = try await client.submitJob(connection,context:context); XCTFail("Response loss must be surfaced") }
        catch { XCTAssertTrue(error is URLError) }
        let recovered = try await client.submitJob(connection,context:context)
        let queried = try await client.job(connection,id:context.id)
        XCTAssertEqual(recovered.id,queried.id); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,2)
        let bodies = RevoiceHTTPProtocol.state.submissions
        XCTAssertEqual(bodies[0],bodies[1]); XCTAssertEqual(Set(bodies[0].keys),["mode","requestID","speaker","instruction","text"])
        XCTAssertEqual(bodies[0]["instruction"],"  慵懒  "); XCTAssertEqual(bodies[0]["text"],context.text)
    }
    func testConnectionFormatAndOriginValidation() throws {
        XCTAssertNoThrow(try CloudEndpoint.validate("https://unit-tests.modal.run"))
        for address in ["http://test.modal.run","https://modal.run.evil.example","https://a:b@test.modal.run","https://test.modal.run/?key=x","https://test.modal.run/path","file:///tmp"] {
            XCTAssertThrowsError(try CloudEndpoint.validate(address))
        }
        let origin = try CloudEndpoint.validate("https://unit-tests.modal.run")
        XCTAssertNoThrow(try CloudEndpoint.resultURL("/v1/tts?request=test",relativeTo:origin,origin:origin))
        for value in ["https://other.modal.run/result","http://unit-tests.modal.run/result","https://unit-tests.modal.run:444/result","https://a:b@unit-tests.modal.run/result"] {
            XCTAssertThrowsError(try CloudEndpoint.resultURL(value,relativeTo:origin,origin:origin))
        }
    }
    func testTextAndInstructionLimitsCountUnicodeScalarsWithoutTruncation() throws {
        XCTAssertEqual(try RevoiceLimits.text("  嗯，我，我还没连上 Wi-Fi。  "),"嗯，我，我还没连上 Wi-Fi。")
        XCTAssertNoThrow(try RevoiceLimits.text(String(repeating:"字",count:1000)))
        XCTAssertThrowsError(try RevoiceLimits.text(String(repeating:"字",count:1001)))
        XCTAssertThrowsError(try RevoiceLimits.text(" "))
        XCTAssertThrowsError(try RevoiceLimits.text("字\u{0000}"))
        XCTAssertNoThrow(try RevoiceLimits.instruction(String(repeating:"字",count:500)))
        XCTAssertThrowsError(try RevoiceLimits.instruction(String(repeating:"字",count:501)))
    }
    func testPayloadHasOnlyTextAndFixedSelection() throws {
        for speaker in RevoiceSpeaker.all {
            let body = try RevoiceChoice.custom(speaker:speaker.id,instruction:"  轻声自然。  ").body(text:"嗯，我，我知道。")
            let values = try XCTUnwrap(try JSONSerialization.jsonObject(with:body) as? [String:String])
            XCTAssertEqual(Set(values.keys),["text","speaker","instruction"])
            XCTAssertEqual(values["instruction"],"  轻声自然。  ")
        }
        let preset = try RevoiceChoice.preset(id:"serena-original",variant:"custom").body(text:"你好。")
        XCTAssertEqual(Set(try XCTUnwrap(try JSONSerialization.jsonObject(with:preset) as? [String:String]).keys),["text","voice"])
        XCTAssertThrowsError(try RevoiceChoice.custom(speaker:"unknown",instruction:"").body(text:"你好。"))
    }
    @MainActor func testSpeechAvailabilityNeverSilentlyFallsBackToNetwork() throws {
        XCTAssertNoThrow(try DeviceSpeechRecognizer.requireDeviceRecognition(authorized:true,available:true,supported:true))
        for values in [(false,true,true),(true,false,true),(true,true,false)] {
            XCTAssertThrowsError(try DeviceSpeechRecognizer.requireDeviceRecognition(authorized:values.0,available:values.1,supported:values.2))
        }
    }
    func testWaveformLengthIsIndependentFromInputAndIdentityIsVerified() throws {
        let choice = RevoiceChoice.custom(speaker:"Serena",instruction:"")
        for seconds in [0.1,90.0,180.0] {
            let data = RevoiceTestAudio.wav(seconds:seconds)
            let result = try RevoiceWAV.validate(data,response:RevoiceTestAudio.response(data,choice:choice,duration:seconds),choice:choice,totalSeconds:1)
            XCTAssertEqual(result.duration,seconds,accuracy:1.0/24000)
        }
        let long = RevoiceTestAudio.wav(seconds:181)
        XCTAssertThrowsError(try RevoiceWAV.validate(long,response:RevoiceTestAudio.response(long,choice:choice,duration:181),choice:choice,totalSeconds:1))
        var data = RevoiceTestAudio.wav(seconds:1)
        let response = try RevoiceTestAudio.response(data,choice:choice,duration:1)
        data[data.count-1] ^= 1
        XCTAssertThrowsError(try RevoiceWAV.validate(data,response:response,choice:choice,totalSeconds:1))
        XCTAssertThrowsError(try RevoiceWAV.validate(RevoiceTestAudio.wav(seconds:1),response:response,choice:.custom(speaker:"Vivian",instruction:""),totalSeconds:1))
    }
    @MainActor private func exercise(_ body:(RevoiceController,RevoiceTestRecognizer,AudioAsset) async throws->Void) async throws {
        RevoiceHTTPProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [RevoiceHTTPProtocol.self]
        let recognizer = RevoiceTestRecognizer()
        let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
        let ai = RevoiceController(client:CloudRevoiceClient(session:URLSession(configuration:config)),recognizer:recognizer,connection:connection,saveConnection:{_ in},draftStore:nil)
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let input = try AudioFileManager.importFile(from:fixture)
        var results:[AudioAsset] = [];ai.onResult = { results.append($0) }
        defer { ai.cancel();try? AudioFileManager.removeAudio(input);for result in results { try? AudioFileManager.removeAudio(result) } }
        ai.connect();try await settle(ai)
        XCTAssertEqual(ai.voices.count,2)
        try await body(ai,recognizer,input)
    }
    @MainActor private func settle(_ ai:RevoiceController) async throws {
        for _ in 0..<400 where ai.busy { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertFalse(ai.busy)
    }
    @MainActor private func exerciseAsync(_ body:(RevoiceController,RevoiceTestRecognizer,BackgroundRevoiceTransfers,PendingRevoiceStore) async throws->Void) async throws {
        RevoiceHTTPProtocol.state.reset(); RevoiceHTTPProtocol.state.asyncJobs = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
        let session = URLSession(configuration:config)
        let store = PendingRevoiceStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true))
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:config)
        let recognizer = RevoiceTestRecognizer()
        let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",
            proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
        let ai = RevoiceController(client:CloudRevoiceClient(session:session),recognizer:recognizer,
            connection:connection,saveConnection:{_ in},backgroundTransfers:manager,draftStore:nil)
        defer {
            ai.cancel(); manager.invalidateForTesting(); session.invalidateAndCancel()
            try? FileManager.default.removeItem(at:store.directory); RevoiceHTTPProtocol.state.reset()
        }
        ai.connect(); try await settle(ai)
        try await body(ai,recognizer,manager,store)
    }
    @MainActor private func waitForSubmissions(_ count:Int) async throws {
        for _ in 0..<400 where RevoiceHTTPProtocol.state.submissions.count < count { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,count)
    }
    @MainActor private func finishPending(_ manager:BackgroundRevoiceTransfers,_ store:PendingRevoiceStore,id:UUID) throws {
        var job = try XCTUnwrap(store.job(id))
        job.phase = .failed; job.failureKind = .generation
        try store.save(job); manager.onChange?(job,RevoiceJobFailureKind.generation.message,nil)
    }
    @MainActor func testAsyncNewGenerationUsesLatestSpeakerInstructionTextAndNewIDForAllSpeakers() async throws {
        try await exerciseAsync { ai,recognizer,manager,store in
            ai.usesAutomaticInstruction = false
            ai.kind = .custom
            var ids:Set<String> = []
            for (index,speaker) in RevoiceSpeaker.all.enumerated() {
                let previous = ai.pendingJobID
                if let previous { try self.finishPending(manager,store,id:previous) }
                ai.selectedSpeaker = speaker.id; ai.instruction = "  第 \(index) 次，自然明亮。  "; ai.text = "最新文字 \(index)，嗯，我，我知道。"
                RevoiceHTTPProtocol.state.failAfterSubmission = true
                ai.generate(); try await self.settle(ai)
                let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
                XCTAssertEqual(body["speaker"],speaker.id); XCTAssertEqual(body["instruction"],ai.instruction)
                XCTAssertEqual(body["text"],ai.text); XCTAssertEqual(body["mode"],"custom")
                XCTAssertEqual(Set(body.keys),["mode","requestID","speaker","instruction","text"])
                XCTAssertTrue(ids.insert(try XCTUnwrap(body["requestID"])).inserted)
                if let previous { XCTAssertEqual(store.job(previous)?.phase,.failed) }
                XCTAssertEqual(ai.pendingContext?.choice,.custom(speaker:speaker.id,instruction:ai.instruction))
            }
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,9); XCTAssertEqual(recognizer.calls,0)
        }
    }
    @MainActor func testAsyncNewPresetGenerationDoesNotCarryCustomParametersOrPreviousID() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.text = "上一段。"; ai.instruction = "旧指令"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let previous = try XCTUnwrap(ai.pendingJobID)
            ai.kind = .preset; ai.selectedPreset = "scholar-design"; ai.text = "现在用固定书生声线。"; ai.instruction = "不得污染固定预设"
            ai.generate(); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1); XCTAssertEqual(ai.pendingJobID,previous)
            try self.finishPending(manager,store,id:previous)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(body["voice"],"scholar-design"); XCTAssertEqual(body["text"],ai.text)
            XCTAssertEqual(Set(body.keys),["mode","requestID","voice","text"])
            XCTAssertNotEqual(body["requestID"],previous.uuidString); XCTAssertEqual(store.job(previous)?.phase,.failed)
            XCTAssertEqual(ai.pendingContext?.choice,.preset(id:"scholar-design",variant:"base"))
        }
    }
    @MainActor func testRecoveringPreviousJobKeepsItsFrozenRequestWithoutOverwritingEditedDraft() async throws {
        try await exerciseAsync { ai,_,_,_ in
            ai.kind = .custom; ai.text = "上一次已提交的话。"; ai.selectedSpeaker = "Serena"; ai.instruction = "  旧指令  "
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let frozen = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.first)
            ai.text = "我现在正在编辑的话。"; ai.selectedSpeaker = "Vivian"; ai.instruction = "新指令"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.resumePending()
            try await self.waitForSubmissions(2); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions[1],frozen)
            XCTAssertEqual(ai.text,"我现在正在编辑的话。"); XCTAssertEqual(ai.selectedSpeaker,"Vivian"); XCTAssertEqual(ai.instruction,"新指令")
            ai.foregroundChanged(false); RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.foregroundChanged(true)
            try await self.waitForSubmissions(3); try await self.settle(ai)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions[2],frozen)
            XCTAssertEqual(ai.text,"我现在正在编辑的话。"); XCTAssertEqual(ai.selectedSpeaker,"Vivian"); XCTAssertEqual(ai.instruction,"新指令")
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let fresh = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(fresh,frozen); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,3)
            XCTAssertFalse(ai.canGenerateDraft); XCTAssertEqual(ai.text,"我现在正在编辑的话。")
        }
    }
    @MainActor func testInvalidNewDraftDoesNotAbandonRecoverablePreviousGeneration() async throws {
        try await exerciseAsync { ai,_,_,store in
            ai.kind = .custom; ai.text = "这段仍然可以取回。"; RevoiceHTTPProtocol.state.failAfterSubmission = true
            ai.generate(); try await self.settle(ai); let previous = try XCTUnwrap(ai.pendingJobID)
            ai.instruction = String(repeating:"字",count:501); ai.generate()
            XCTAssertNotNil(ai.errorMessage); XCTAssertEqual(ai.pendingJobID,previous)
            XCTAssertEqual(store.job(previous)?.phase,.suspended); XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            ai.instruction = "有效的新指令"; ai.text = String(repeating:"字",count:1001); ai.generate()
            XCTAssertEqual(ai.pendingJobID,previous); XCTAssertEqual(store.job(previous)?.phase,.suspended)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
        }
    }
    @MainActor func testNewDraftCannotReplaceInFlightSubmissionOrLoseItsRetrieval() async throws {
        try await exerciseAsync { ai,_,_,store in
            ai.usesAutomaticInstruction = false
            ai.kind = .custom; ai.selectedSpeaker = "Serena"; ai.text = "正在提交的旧任务。"; ai.instruction = "旧指令"
            RevoiceHTTPProtocol.state.responseDelay = 0.4; ai.generate(); try await self.waitForSubmissions(1)
            let previous = try XCTUnwrap(ai.pendingJobID)
            ai.selectedSpeaker = "Vivian"; ai.text = "替换后新的内容。"; ai.instruction = "自然明亮"
            ai.generate(); try await self.settle(ai)
            try await Task.sleep(for:.milliseconds(500))
            let fresh = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(fresh["speaker"],"Serena"); XCTAssertEqual(fresh["text"],"正在提交的旧任务。"); XCTAssertEqual(fresh["instruction"],"旧指令")
            XCTAssertEqual(fresh["requestID"],previous.uuidString); XCTAssertEqual(store.job(previous)?.phase,.suspended)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1); XCTAssertEqual(ai.pendingJobID,previous)
            XCTAssertEqual(ai.text,"替换后新的内容。"); XCTAssertEqual(ai.selectedSpeaker,"Vivian"); XCTAssertFalse(ai.busy)
        }
    }
    @MainActor func testCancelledRecoveryConnectionDoesNotRestoreDraftOrSubmitOldParameters() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.text = "重开前保存的任务。"; ai.instruction = "旧指令"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let previous = try XCTUnwrap(ai.pendingJobID)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
            let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
            let client = CloudRevoiceClient(session:session)
            let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
            let restarted = RevoiceController(client:client,recognizer:RevoiceTestRecognizer(),connection:connection,
                saveConnection:{_ in},backgroundTransfers:manager,draftStore:nil)
            defer { restarted.cancel() }
            XCTAssertEqual(restarted.text,"重开前保存的任务。")
            RevoiceHTTPProtocol.state.responseDelay = 0.4; restarted.resumePending()
            for _ in 0..<100 where !restarted.busy { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertTrue(restarted.busy)
            restarted.text = "返回后全新的内容。"; restarted.selectedSpeaker = "Vivian"; restarted.instruction = "新指令"
            XCTAssertTrue(restarted.cancel()); try await Task.sleep(for:.milliseconds(500))
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1); XCTAssertNil(client.downloadOrigin(for:connection))
            XCTAssertEqual(store.job(previous)?.phase,.abandoned)
            XCTAssertEqual(restarted.text,"返回后全新的内容。"); XCTAssertEqual(restarted.selectedSpeaker,"Vivian")
            RevoiceHTTPProtocol.state.responseDelay = 0; restarted.connect(); try await self.settle(restarted)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; restarted.generate(); try await self.settle(restarted)
            let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(body["text"],"重开前保存的任务。"); XCTAssertEqual(body["requestID"],previous.uuidString)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1); XCTAssertFalse(restarted.canGenerateDraft)
            XCTAssertEqual(restarted.text,"返回后全新的内容。"); XCTAssertEqual(store.job(previous)?.phase,.abandoned)
        }
    }
    @MainActor func testRestartedPendingDownloadLoadsCatalogWithoutChangingItsStateOrNewDraft() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.text = "之前已提交的任务。"; ai.instruction = "旧指令"
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let previous = try XCTUnwrap(ai.pendingJobID)
            var job = try XCTUnwrap(store.job(previous))
            let origin = try CloudJobEndpoint.origin("https://unit-download.modal.run")
            job.reply = .init(id:job.networkID,state:"queued",createdAt:job.context.createdAt.timeIntervalSince1970,
                expiresAt:job.context.createdAt.addingTimeInterval(86400).timeIntervalSince1970,
                downloadURL:origin.appendingPathComponent("v1/jobs/"+job.networkID+"/audio"),
                downloadToken:String(repeating:"a",count:64),error:nil)
            job.downloadOrigin = origin; job.phase = .downloading; job.lastError = nil; try store.save(job)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
            let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
            let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
            let restarted = RevoiceController(client:CloudRevoiceClient(session:session),recognizer:RevoiceTestRecognizer(),
                connection:connection,saveConnection:{_ in},backgroundTransfers:manager,draftStore:nil)
            defer { restarted.cancel() }
            XCTAssertTrue(restarted.voices.isEmpty); XCTAssertTrue(restarted.speakers.isEmpty)
            restarted.text = "重开后最新的文字。"; restarted.selectedSpeaker = "Vivian"; restarted.instruction = "自然明亮"
            manager.onChange?(job,"配音中 · 可切换 App 或锁屏",nil)
            restarted.connect(); XCTAssertTrue(restarted.connecting)
            for _ in 0..<400 where restarted.connecting { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertFalse(restarted.connecting); XCTAssertEqual(restarted.voices.count,2); XCTAssertEqual(restarted.speakers.count,9)
            XCTAssertEqual(restarted.stage,.generating); XCTAssertEqual(restarted.status,"配音中 · 可切换 App 或锁屏")
            XCTAssertEqual(restarted.pendingJobID,previous); XCTAssertEqual(store.job(previous)?.phase,.downloading)
            XCTAssertEqual(restarted.text,"重开后最新的文字。"); XCTAssertEqual(restarted.selectedSpeaker,"Vivian"); XCTAssertEqual(restarted.instruction,"自然明亮")
            XCTAssertFalse(restarted.canGenerateDraft)
            restarted.generate()
            let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(body["text"],"之前已提交的任务。"); XCTAssertEqual(body["requestID"],previous.uuidString)
            XCTAssertEqual(store.job(previous)?.phase,.downloading); XCTAssertEqual(restarted.pendingJobID,previous)
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1); XCTAssertEqual(restarted.text,"重开后最新的文字。")
        }
    }
    @MainActor func testOldTransferCallbacksCannotClearReplacementIDOrChangeItsStatus() async throws {
        try await exerciseAsync { ai,_,manager,store in
            ai.kind = .custom; ai.text = "旧任务。"; RevoiceHTTPProtocol.state.failAfterSubmission = true
            ai.generate(); try await self.settle(ai); let previous = try XCTUnwrap(ai.pendingJobID)
            ai.selectedSpeaker = "Vivian"; ai.text = "新任务。"; ai.instruction = "新指令"
            try self.finishPending(manager,store,id:previous)
            RevoiceHTTPProtocol.state.failAfterSubmission = true; ai.generate(); try await self.settle(ai)
            let current = try XCTUnwrap(ai.pendingJobID), status = ai.status, error = ai.errorMessage
            var old = try XCTUnwrap(store.job(previous)); old.phase = .failed; old.lastError = "旧任务失败"
            manager.onChange?(old,"旧任务不应该覆盖新任务",nil)
            XCTAssertEqual(ai.pendingJobID,current); XCTAssertEqual(ai.status,status); XCTAssertEqual(ai.errorMessage,error)
            XCTAssertEqual(ai.text,"新任务。"); XCTAssertEqual(ai.selectedSpeaker,"Vivian"); XCTAssertEqual(ai.instruction,"新指令")
            XCTAssertTrue(ai.cancel()); let stopped = ai.status
            manager.onChange?(old,"停止等待后也不能恢复旧错误",nil)
            XCTAssertNil(ai.pendingJobID); XCTAssertEqual(ai.status,stopped); XCTAssertFalse(ai.busy)
        }
    }
    func testBackgroundCapabilityIsNotCachedFromAnIncompleteConnection() async throws {
        RevoiceHTTPProtocol.state.reset(); RevoiceHTTPProtocol.state.asyncJobs = true; RevoiceHTTPProtocol.state.invalidVoices = true
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RevoiceHTTPProtocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel(); RevoiceHTTPProtocol.state.reset() }
        let client = CloudRevoiceClient(session:session)
        let connection = CloudConnection(endpoint:"https://unit-tests.modal.run",proxyTokenID:"unit-test-id",proxyTokenSecret:"unit-test-secret",apiKey:String(repeating:"x",count:48))
        do { _ = try await client.connect(connection); XCTFail("An empty voice list cannot complete connection") }
        catch { XCTAssertNil(client.downloadOrigin(for:connection)) }
    }
    @MainActor func testCustomRecordingWaitsForReviewAndEditingDoesNotRecognizeAgain() async throws {
        try await exercise { ai,recognizer,input in
            ai.usesAutomaticInstruction = false
            ai.kind = .custom;ai.recorded(input);try await self.settle(ai)
            XCTAssertEqual(recognizer.calls,1);XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
            ai.text = "修改后的原话。";ai.instruction = "  放松一点。  ";ai.generate();try await self.settle(ai)
            let result = try XCTUnwrap(ai.result)
            XCTAssertEqual(recognizer.calls,1);XCTAssertEqual(result.revoice?.synthesisText,"修改后的原话。")
            XCTAssertEqual(result.revoice?.recognizedText,"嗯，我，我想明天再去。")
            XCTAssertEqual(result.revoice?.instruction,"  放松一点。  ")
            XCTAssertEqual(Set(try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last).keys),["speaker","text","instruction"])
        }
    }
    @MainActor func testAutomaticRecognitionPreservesNewerDraftAndChangedCustomMode() async throws {
        try await exercise { ai,recognizer,input in
            ai.usesAutomaticInstruction = false
            recognizer.delay = true; ai.recorded(input)
            for _ in 0..<200 where recognizer.calls == 0 { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertEqual(recognizer.calls,1)
            ai.kind = .custom; ai.selectedSpeaker = "Vivian"; ai.instruction = "自然明亮"; ai.text = "我识别期间手动编辑的新内容。"
            try await self.settle(ai)
            XCTAssertEqual(ai.text,"我识别期间手动编辑的新内容。"); XCTAssertEqual(ai.recognizedText,"嗯，我，我想明天再去。")
            XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
            ai.generate(); try await self.settle(ai)
            let body = try XCTUnwrap(RevoiceHTTPProtocol.state.submissions.last)
            XCTAssertEqual(body["speaker"],"Vivian"); XCTAssertEqual(body["instruction"],"自然明亮")
            XCTAssertEqual(body["text"],"我识别期间手动编辑的新内容。"); XCTAssertEqual(recognizer.calls,1)
        }
    }
    @MainActor func testPresetRecordingOnlyRecognizesAndManualGenerationIsRequired() async throws {
        try await exercise { ai,recognizer,input in
            ai.recorded(input);try await self.settle(ai)
            XCTAssertNil(ai.result);XCTAssertEqual(recognizer.calls,1)
            XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
            ai.generate();try await self.settle(ai);XCTAssertNotNil(ai.result)
            let draft = ai.text,result = ai.result
            ai.selectInput(nil);XCTAssertEqual(ai.text,draft);XCTAssertNil(ai.recognizedText);XCTAssertEqual(ai.result?.id,result?.id)
        }
    }
    @MainActor func testCancelledRecognitionCannotPopulateNewInput() async throws {
        try await exercise { ai,recognizer,input in
            recognizer.delay=true;ai.selectInput(input);ai.recognize()
            try await Task.sleep(for:.milliseconds(100));ai.selectInput(nil)
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertTrue(ai.text.isEmpty);XCTAssertNil(ai.recognizedText);XCTAssertNil(ai.input);XCTAssertNil(ai.result)
        }
    }
    @MainActor func testSpeechFailureRetainsRecordingAndTypedTextCanGenerate() async throws {
        try await exercise { ai,recognizer,input in
            recognizer.failure=true;ai.kind = .custom;ai.recorded(input);try await self.settle(ai)
            XCTAssertEqual(ai.input?.id,input.id);XCTAssertNotNil(ai.errorMessage)
            ai.text="手动输入的原话。";ai.generate();try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(recognizer.calls,1)
        }
    }
    @MainActor func testNetworkFailureDoesNotAutoResubmitAndNextGenerationWorks() async throws {
        try await exercise { ai,_,_ in
            ai.text="你好。";RevoiceHTTPProtocol.state.failNext=true;ai.generate();try await self.settle(ai)
            XCTAssertNil(ai.result);XCTAssertNotNil(ai.errorMessage);XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
            ai.generate();try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
        }
    }
    @MainActor func testCrossOriginRedirectRefusedBeforeAnyResultIsSaved() async throws {
        try await exercise { ai,_,_ in
            ai.text="你好。";RevoiceHTTPProtocol.state.redirect="https://other.modal.run/result"
            ai.generate();try await self.settle(ai)
            XCTAssertNil(ai.result);XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            XCTAssertTrue(ai.errorMessage?.contains("跳转") == true)
        }
    }
    @MainActor func testSameOrigin303UsesGetWithoutResubmittingText() async throws {
        try await exercise { ai,_,_ in
            ai.text="同一条文字只提交一次。";RevoiceHTTPProtocol.state.redirect="/v1/tts?result=test"
            ai.generate();try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            XCTAssertEqual(RevoiceHTTPProtocol.state.methods,["POST","GET"])
        }
    }
    @MainActor func testRejectedResponseNeverSavesAndCanRetryManually() async throws {
        try await exercise { ai,_,_ in
            ai.text="你好。"
            for status in [401,403,429,504] {
                RevoiceHTTPProtocol.state.responseStatus=status;ai.generate();try await self.settle(ai)
                XCTAssertNil(ai.result);XCTAssertNotNil(ai.errorMessage)
            }
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,4)
            RevoiceHTTPProtocol.state.responseStatus=200;ai.generate();try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,5)
        }
    }
    @MainActor func testOverlongOutputRejectedBeforeRegisteringAudio() async throws {
        try await exercise { ai,_,_ in
            RevoiceHTTPProtocol.state.data=RevoiceTestAudio.wav(seconds:181)
            ai.text="不能截断的完整话语。";ai.generate();try await self.settle(ai)
            XCTAssertNil(ai.result);XCTAssertNotNil(ai.errorMessage)
            XCTAssertEqual(ai.text,"不能截断的完整话语。")
        }
    }
    @MainActor func testStopWaitingDiscardsLateGenerationAndNextRequestWorks() async throws {
        try await exercise { ai,_,_ in
            RevoiceHTTPProtocol.state.responseDelay=0.5;ai.text="停止等待后的文字仍保留。";ai.generate()
            for _ in 0..<100 where RevoiceHTTPProtocol.state.submissions.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,1)
            ai.cancel();try await Task.sleep(for:.milliseconds(700))
            XCTAssertNil(ai.result);XCTAssertFalse(ai.busy);XCTAssertEqual(ai.text,"停止等待后的文字仍保留。")
            RevoiceHTTPProtocol.state.responseDelay=0;ai.generate();try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(RevoiceHTTPProtocol.state.submissions.count,2)
        }
    }
    @MainActor func testNinetySecondOutputSavesWithMetadataAndCanMixInFull() async throws {
        try await exercise { ai,_,input in
            RevoiceHTTPProtocol.state.data=RevoiceTestAudio.wav(seconds:90)
            ai.text="完整长成品测试。";ai.generate();try await self.settle(ai)
            let result = try XCTUnwrap(ai.result)
            XCTAssertEqual(result.duration,90,accuracy:1.0/24000)
            let restored = try JSONDecoder().decode(AudioAsset.self,from:JSONEncoder().encode(result))
            XCTAssertEqual(restored.revoice?.sha256,result.revoice?.sha256)
            let mix = try RecordedVoiceMixer.mix(voiceURL:AudioFileManager.url(for:result),musicURL:AudioFileManager.url(for:input),settings:.init(),volumes:.init(voice:1,music:0.04,master:0.9))
            defer { try? AudioFileManager.removeAudio(mix) }
            XCTAssertEqual(mix.duration,90,accuracy:0.01)
        }
    }
    @MainActor func testLegacyCloudKeepsPresetsAndDisablesUnsupportedCustomMode() async throws {
        try await exercise { ai,_,_ in
            RevoiceHTTPProtocol.state.customSupported=false;ai.connect();try await self.settle(ai)
            XCTAssertTrue(ai.speakers.isEmpty);XCTAssertEqual(ai.voices.count,2)
            ai.kind = .custom;ai.text="你好。";ai.generate()
            XCTAssertNotNil(ai.errorMessage);XCTAssertTrue(RevoiceHTTPProtocol.state.submissions.isEmpty)
        }
    }
}
