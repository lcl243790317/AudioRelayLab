import AVFoundation
import CryptoKit
import XCTest
@testable import AudioRelayLab

private enum RevoiceTestAudio {
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
    var methods:[String] = []
    var responseStatus = 200
    var responseDelay = 0.0
    func reset() { lock.lock();defer{lock.unlock()};data = RevoiceTestAudio.wav(seconds:1);submissions=[];failNext=false;redirect=nil;customSupported=true;methods=[];responseStatus=200;responseDelay=0 }
    func respond(_ request:URLRequest) throws -> (Data,Int,[String:String]) {
        lock.lock();defer{lock.unlock()}
        let path = request.url?.path ?? ""
        if path == "/v1/health" {
            return (try JSONSerialization.data(withJSONObject:["status":"ok","capabilities":["customTTS":customSupported,"textOnly":true]]),200,[:])
        }
        if path == "/v1/voices" {
            return (try JSONEncoder().encode(CloudRevoiceClient.VoicesForTests()),200,[:])
        }
        if path == "/v1/speakers" {
            return (try JSONSerialization.data(withJSONObject:["speakers":RevoiceSpeaker.all.map{["id":$0.id,"displayName":$0.displayName]}]),200,[:])
        }
        methods.append(request.httpMethod ?? "")
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
            if let redirect { return (Data(),303,["Location":redirect]) }
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
        let voices:[RevoiceVoice] = [.init(id:"serena-original",displayName:"Serena",variant:"custom"),.init(id:"scholar-design",displayName:"书生",variant:"base")]
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
        let ai = RevoiceController(client:CloudRevoiceClient(session:URLSession(configuration:config)),recognizer:recognizer,connection:connection,saveConnection:{_ in})
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
    @MainActor func testCustomRecordingWaitsForReviewAndEditingDoesNotRecognizeAgain() async throws {
        try await exercise { ai,recognizer,input in
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
    @MainActor func testPresetRecordingAutomaticallyGeneratesAndNewInputClearsOldText() async throws {
        try await exercise { ai,recognizer,input in
            ai.recorded(input);try await self.settle(ai)
            XCTAssertNotNil(ai.result);XCTAssertEqual(recognizer.calls,1)
            ai.selectInput(nil);XCTAssertTrue(ai.text.isEmpty);XCTAssertNil(ai.recognizedText);XCTAssertNil(ai.result)
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
