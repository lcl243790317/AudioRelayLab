import AVFoundation
import CryptoKit
import XCTest
@testable import AudioRelayLab

/// Network contract double; actual GPU/server evidence is recorded separately.
private final class AIHTTPTestState: @unchecked Sendable {
    let lock = NSLock()
    var audio = Data()
    var connectionFailure: URLError.Code?
    var uploadFailure: URLError.Code?
    var submissions = 0
    func reset(audio:Data) {
        lock.lock(); defer { lock.unlock() }
        self.audio = audio; submissions = 0; connectionFailure = nil; uploadFailure = nil
    }
    func respond(_ request:URLRequest) throws -> (Data,[String:String]) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        if path == "/v1/health" {
            if let failure = connectionFailure { connectionFailure = nil; throw URLError(failure) }
            return (Data("{\"engine\":\"contract-double\",\"modelState\":\"ready\",\"protocolVersion\":2}".utf8),[:])
        }
        if path == "/v1/voices" {
            return (Data("{\"voices\":[{\"id\":\"female\",\"name\":\"测试\",\"referenceOrigin\":\"contract-double\"}]}".utf8),[:])
        }
        let hash = SHA256.hash(data:audio).map { String(format:"%02x",$0) }.joined()
        if path.hasSuffix("/audio") { return (audio,["X-Audio-SHA256":hash]) }
        if request.httpMethod == "POST" {
            if let failure = uploadFailure { uploadFailure = nil; throw URLError(failure) }
            submissions += 1
        }
        let metadata = AIConversionMetadata(engine:"contract-double",sourceRevision:"test",device:"test",
            sampleRate:22050,duration:0.5,sha256:hash,voiceID:"female",voiceName:"测试",
            referenceOrigin:"contract-double",conversionSeconds:0.1,settings:["convertStyle":0])
        let metadataObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(metadata))
        let data = try JSONSerialization.data(withJSONObject:["id":"job-\(submissions)",
            "state":request.httpMethod == "POST" ? "queued" : "complete", "message":"完成", "metadata":metadataObject])
        return (data,[:])
    }
}

private final class AIHTTPTestProtocol: URLProtocol, @unchecked Sendable {
    static let state = AIHTTPTestState()
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (data,headers) = try Self.state.respond(request)
            guard let url = request.url, let response = HTTPURLResponse(url:url,
                statusCode:request.httpMethod == "POST" ? 202 : 200,httpVersion:nil,headerFields:headers) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

final class AIConnectionRegressionTests: XCTestCase {
    @MainActor private func exercise(saveKey:((String) throws -> Void)? = nil,
        _ body:(AIConversionController,DiagnosticsLogger,AudioAsset) async throws -> Void) async throws {
        let originalKey = AIConnectionKey.load(), originalAddress = UserDefaults.standard.string(forKey:"aiAddress")
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let prepared = try AIRequestAudio.make(url:fixture,start:0.2,limit:0.5)
        let input = try AudioFileManager.importFile(from:fixture)
        defer {
            try? FileManager.default.removeItem(at:prepared); try? AudioFileManager.removeAudio(input)
            try? AIConnectionKey.save(originalKey)
            if let originalAddress { UserDefaults.standard.set(originalAddress,forKey:"aiAddress") }
            else { UserDefaults.standard.removeObject(forKey:"aiAddress") }
        }
        AIHTTPTestProtocol.state.reset(audio:try Data(contentsOf:prepared))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPTestProtocol.self]
        let logger = DiagnosticsLogger(), ai = AIConversionController(logger:logger,session:URLSession(configuration:config),
            saveKey:saveKey ?? AIConnectionKey.save)
        ai.address = "http://127.0.0.1:7867"; ai.key = "contract-test-key"
        var results:[AudioAsset] = []; ai.onResult = { results.append($0) }
        defer { ai.cancel(); for asset in results { try? AudioFileManager.removeAudio(asset) } }
        try await body(ai,logger,input)
    }
    @MainActor private func settle(_ ai:AIConversionController) async throws {
        for _ in 0..<200 where ai.busy || ai.connecting { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertFalse(ai.busy); XCTAssertFalse(ai.connecting)
    }
    func testNetworkFailuresDescribeComputerConnectionInsteadOfAudioSession() {
        for code in [URLError.Code.cannotConnectToHost,.timedOut,.networkConnectionLost,.cannotFindHost] {
            let message = AIConnectionError.message(URLError(code))
            XCTAssertFalse(message.contains("音频环境")); XCTAssertFalse(message.isEmpty)
        }
        XCTAssertTrue(AIConnectionError.message(URLError(.cannotConnectToHost)).contains("server/run.ps1"))
    }
    @MainActor func testFailedConnectionIsLoggedAndCanReconnectWithoutRelaunch() async throws {
        try await exercise { ai,logger,_ in
            AIHTTPTestProtocol.state.connectionFailure = .cannotConnectToHost
            ai.connect(); try await self.settle(ai)
            XCTAssertTrue(ai.voices.isEmpty); XCTAssertNotNil(ai.errorMessage)
            XCTAssertTrue(logger.entries().contains { $0.category == "AI 连接失败" && $0.message.contains("NSURLErrorDomain") })
            ai.connect(); try await self.settle(ai)
            XCTAssertEqual(ai.voices.count,1); XCTAssertNil(ai.errorMessage)
        }
    }
    @MainActor func testSecureStorageFailureWarnsButKeepsAuthenticatedConnectionUsable() async throws {
        try await exercise(saveKey:{ _ in throw NSError(domain:NSOSStatusErrorDomain,code:-34018) }) { ai,logger,input in
            ai.connect(); try await self.settle(ai)
            XCTAssertEqual(ai.voices.count,1); XCTAssertNil(ai.errorMessage)
            XCTAssertNotNil(ai.connectionWarning)
            XCTAssertTrue(logger.entries().contains { $0.category == "AI 密钥保存失败" && $0.message.contains("-34018") })
            ai.selectInput(input); ai.convert(start:0.2,limit:0.5); try await self.settle(ai)
            XCTAssertNotNil(ai.result)
        }
    }
    @MainActor func testConsecutiveConversionsAndReconnectProduceFreshResults() async throws {
        try await exercise { ai,logger,input in
            ai.connect(); try await self.settle(ai)
            ai.selectInput(input); ai.convert(start:0.2,limit:0.5); try await self.settle(ai)
            let first = try XCTUnwrap(ai.result)
            ai.selectInput(input); XCTAssertNil(ai.result)
            ai.convert(start:0.2,limit:0.5); try await self.settle(ai)
            let second = try XCTUnwrap(ai.result)
            XCTAssertNotEqual(first.id,second.id); XCTAssertEqual(AIHTTPTestProtocol.state.submissions,2)
            XCTAssertEqual(logger.entries().filter { $0.category == "AI 已保存" }.count,2)
            ai.connect(); try await self.settle(ai)
            XCTAssertEqual(ai.voices.count,1); XCTAssertNil(ai.errorMessage)
        }
    }
    @MainActor func testFailedUploadReleasesBusyStateAndNextConversionSucceeds() async throws {
        try await exercise { ai,_,input in
            ai.connect(); try await self.settle(ai); ai.selectInput(input)
            AIHTTPTestProtocol.state.uploadFailure = .networkConnectionLost
            ai.convert(start:0.2,limit:0.5); try await self.settle(ai)
            XCTAssertNotNil(ai.errorMessage); XCTAssertNil(ai.result)
            ai.convert(start:0.2,limit:0.5); try await self.settle(ai)
            XCTAssertNotNil(ai.result); XCTAssertNil(ai.errorMessage)
        }
    }
}
