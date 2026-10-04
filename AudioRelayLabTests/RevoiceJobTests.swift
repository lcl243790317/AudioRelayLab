import AVFoundation
import Combine
import CryptoKit
import UIKit
import XCTest
@testable import AudioRelayLab

/// Uses Foundation's actual download task/delegate temporary-file lifecycle.
/// All requests target the CI's isolated HTTPS loopback fixture, never Modal.
private final class RevoiceDownloadProbe:NSObject,URLSessionDownloadDelegate,@unchecked Sendable {
    let manager:BackgroundRevoiceTransfers
    let removeBorrowedFile:Bool
    private let lock = NSLock()
    private var location:URL?
    private var completionError:String?
    init(manager:BackgroundRevoiceTransfers,removeBorrowedFile:Bool = false) {
        self.manager = manager; self.removeBorrowedFile = removeBorrowedFile
    }
    var downloadedLocation:URL? { lock.lock(); defer { lock.unlock() }; return location }
    var errorCode:String? { lock.lock(); defer { lock.unlock() }; return completionError }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo url:URL) {
        lock.lock(); location = url; lock.unlock()
        if removeBorrowedFile { try? FileManager.default.removeItem(at:url) }
        manager.urlSession(session,downloadTask:downloadTask,didFinishDownloadingTo:url)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if let error {
            let value = error as NSError
            lock.lock(); completionError = "\(value.domain):\(value.code)"; lock.unlock()
        }
        manager.urlSession(session,task:task,didCompleteWithError:error)
    }
}

final class RevoiceJobTests:XCTestCase {
    @MainActor func testForegroundRetrievalSucceedsWithoutNativeTemporaryFileOrTransientError() async throws {
        let store = try store(), job = try fixtureJob(); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        var failures:[String] = []; manager.onChange = { job,_,_ in if let error = job.lastError { failures.append(error) } }
        manager.setForeground(true); await manager.restore()
        for _ in 0..<500 where store.job(job.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.phase,.completed); XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(store.job(job.id)?.lastTransferFailure)
        XCTAssertNotNil(store.job(job.id)?.transferID); XCTAssertEqual(store.job(job.id)?.attempts,1)
        let asset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(asset) }
    }
    @MainActor func testForegroundBackgroundHandoffKeepsJobIDAndSavesOnce() async throws {
        let store = try store()
        let id = try XCTUnwrap(UUID(uuidString:"20200000"+String(UUID().uuidString.dropFirst(8))))
        let job = try fixtureJob(id:id); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        var saved = 0,errors:[String] = []
        manager.onChange = { value,_,asset in if asset != nil { saved += 1 }; if let error = value.lastError { errors.append(error) } }
        manager.setForeground(true); await manager.restore()
        for _ in 0..<200 where store.job(job.id)?.attempts != 2 { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.attempts,2)
        manager.setForeground(false); await manager.restore(retrySuspended:false)
        manager.setForeground(true); await manager.restore()
        for _ in 0..<500 where store.job(job.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.phase,.completed); XCTAssertEqual(store.job(job.id)?.context.id,job.id)
        XCTAssertEqual(saved,1); XCTAssertTrue(errors.isEmpty)
        let asset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(asset) }
    }
    @MainActor func testLateTransportReceiptAndCancellationCannotAffectNewTransport() async throws {
        let store = try store(); var job = try pending(context()); job.transferID = UUID(); try store.save(job)
        let old = try envelope(store,job),oldToken = try XCTUnwrap(job.transferID)
        job.transferID = UUID(); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        manager.process(old)
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with:try XCTUnwrap(job.reply?.downloadURL))
        task.taskDescription = job.id.uuidString+"|"+oldToken.uuidString
        manager.urlSession(session,task:task,didCompleteWithError:URLError(.cancelled))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.job(job.id)?.phase,.downloading); XCTAssertNil(store.job(job.id)?.lastError)
        XCTAssertEqual(store.job(job.id)?.transferID,job.transferID)
        XCTAssertFalse(try AudioFileManager.listLocalAudio().contains { $0.id == job.id })
        XCTAssertTrue(store.envelopes().isEmpty)
    }
    private func context(id:UUID = UUID(),seconds:Double = 1,instruction:String = "  轻声自然  ") -> RevoiceSaveContext {
        .init(id:id,createdAt:Date(),choice:.custom(speaker:"Serena",instruction:instruction),
            voiceName:"Serena",instruction:instruction,fixedReferenceID:nil,recognizedText:"嗯，我，我知道。",
            text:"嗯，我，我知道。",sourceAudioID:nil)
    }
    private func reply(_ context:RevoiceSaveContext,origin:String = "https://unit-download.modal.run") throws -> CloudJobReply {
        let id = context.id.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        return .init(id:id,state:"complete",createdAt:context.createdAt.timeIntervalSince1970,
            expiresAt:context.createdAt.addingTimeInterval(86400).timeIntervalSince1970,
            downloadURL:try XCTUnwrap(URL(string:origin+"/v1/jobs/"+id+"/audio")),
            downloadToken:String(repeating:"a",count:64),error:nil)
    }
    private func pending(_ context:RevoiceSaveContext) throws -> PendingRevoiceJob {
        var job = PendingRevoiceJob(context:context,primaryOrigin:try XCTUnwrap(URL(string:"https://unit-tests.modal.run")),
            connectionFingerprint:"test-only"); job.reply = try reply(context)
        job.downloadOrigin = try CloudJobEndpoint.origin("https://unit-download.modal.run"); job.phase = .downloading
        return job
    }
    private func store() throws -> PendingRevoiceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return .init(directory:directory)
    }
    func testDurableJobRoundTripPreservesFrozenParametersAndTombstone() throws {
        let store = try store(), context = context(); var job = try pending(context)
        try store.save(job)
        let restored = try XCTUnwrap(PendingRevoiceStore(directory:store.directory).job(context.id))
        XCTAssertEqual(restored.context.choice,context.choice); XCTAssertEqual(restored.context.instruction,context.instruction)
        XCTAssertTrue(restored.isPending); XCTAssertEqual(restored.reply?.id,job.networkID)
        job.phase = .abandoned; try store.save(job)
        XCTAssertFalse(try XCTUnwrap(store.job(context.id)).isPending)
    }
    func testReadOnlyBorrowedDownloadIsCopiedWithoutMovingOrChangingSource() throws {
        let store = try store(), job = try pending(context())
        try store.prepare()
        let borrowed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:borrowed,withIntermediateDirectories:true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:borrowed.path)
            try? FileManager.default.removeItem(at:borrowed)
        }
        let source = borrowed.appendingPathComponent("download.tmp"), data = RevoiceTestAudio.wav(seconds:1)
        try data.write(to:source)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:source.path)
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:borrowed.path)
        // This fixture reproduces the permission distinction hidden by the old
        // app-owned writable .tmp tests: reading is allowed; unlinking is not.
        XCTAssertThrowsError(try FileManager.default.moveItem(at:source,to:store.directory.appendingPathComponent("old-move.download")))
        let response = try RevoiceTestAudio.response(data,choice:job.context.choice,duration:1)
        let receipt = try store.stage(source,id:job.id,response:response)
        XCTAssertEqual(try Data(contentsOf:source),data)
        XCTAssertEqual(try Data(contentsOf:store.directory.appendingPathComponent(receipt.fileName)),data)
        XCTAssertEqual(store.envelopes().count,1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:source.path)[.posixPermissions] as? NSNumber)?.intValue,0o444)
    }
    func testMissingBorrowedDownloadKeepsJobAndReportsOnlySafeFailureIdentifiers() throws {
        let store = try store(), job = try pending(context()); try store.save(job)
        let missing = store.directory.appendingPathComponent("private-token-and-text.tmp")
        let response = try RevoiceTestAudio.response(RevoiceTestAudio.wav(seconds:1),choice:job.context.choice,duration:1)
        do { _ = try store.stage(missing,id:job.id,response:response); XCTFail("Missing file must not stage") }
        catch let failure as RevoiceTransferError {
            XCTAssertEqual(failure.failure.operation,"read-download")
            XCTAssertFalse(failure.failure.summary.contains("private-token"))
        }
        XCTAssertEqual(store.job(job.id)?.phase,.downloading)
        XCTAssertTrue(store.envelopes().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:store.directory,includingPropertiesForKeys:nil).count,1)
        let error = NSError(domain:NSCocoaErrorDomain,code:513,userInfo:[
            NSFilePathErrorKey:missing.path,NSLocalizedDescriptionKey:"secret spoken text",
            NSUnderlyingErrorKey:NSError(domain:NSPOSIXErrorDomain,code:13)])
        let diagnostic = try JSONEncoder().encode(RevoiceTransferFailure(operation:"write-download",error:error))
        XCTAssertFalse(String(decoding:diagnostic,as:UTF8.self).contains("secret"))
        XCTAssertFalse(String(decoding:diagnostic,as:UTF8.self).contains(missing.path))
    }
    func testOldPersistedTaskWithoutDiagnosticStillDecodesAndRetainsDraft() throws {
        let job = try pending(context())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(job)) as? [String:Any])
        object.removeValue(forKey:"lastTransferFailure")
        object["phase"] = "suspended"; object["lastError"] = "下载文件无法暂存，任务已保留"
        let restored = try JSONDecoder().decode(PendingRevoiceJob.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(restored.lastTransferFailure); XCTAssertTrue(restored.isPending)
        XCTAssertEqual(restored.context.text,job.context.text)
    }
    private func fixtureJob(id:UUID = UUID()) throws -> PendingRevoiceJob {
        guard let endpoint = ProcessInfo.processInfo.environment["REVOICE_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the CI's local trusted HTTPS download fixture")
        }
        let origin = try CloudJobEndpoint.origin(endpoint), context = context(id:id)
        var job = PendingRevoiceJob(context:context,primaryOrigin:origin,connectionFingerprint:"loopback-only")
        job.reply = try reply(context,origin:endpoint); job.downloadOrigin = origin; job.phase = .downloading
        return job
    }
    @MainActor func testRealURLSessionDelegateCopiesTemporaryFileBeforeReturnAndSavesWAV() async throws {
        let store = try store(), job = try fixtureJob(); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        let probe = RevoiceDownloadProbe(manager:manager), session = URLSession(configuration:.ephemeral,delegate:probe,delegateQueue:nil)
        defer { session.invalidateAndCancel(); manager.invalidateForTesting() }
        let request = try BackgroundRevoiceTransfers.request(reply:XCTUnwrap(job.reply),id:job.id,origin:XCTUnwrap(job.downloadOrigin))
        let download = session.downloadTask(with:request); download.taskDescription = job.id.uuidString; download.resume()
        for _ in 0..<500 where store.job(job.id)?.phase != .completed && probe.errorCode == nil {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertNil(probe.errorCode)
        XCTAssertEqual(store.job(job.id)?.phase,.completed)
        let asset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertEqual(asset.revoice?.speakerID,"Serena"); XCTAssertEqual(asset.duration,1,accuracy:1/24000.0)
        let borrowed = try XCTUnwrap(probe.downloadedLocation)
        for _ in 0..<50 where FileManager.default.fileExists(atPath:borrowed.path) { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:borrowed.path))
        XCTAssertTrue(store.envelopes().isEmpty)
    }
    @MainActor func testRealDownloadFailureRecoversRetainedJobThenGeneratesFreshJob() async throws {
        let store = try store(), job = try fixtureJob()
        let initial = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        initial.setForeground(false)
        await initial.restore(retrySuspended:false)
        try store.save(job)
        let probe = RevoiceDownloadProbe(manager:initial,removeBorrowedFile:true)
        let session = URLSession(configuration:.ephemeral,delegate:probe,delegateQueue:nil)
        defer { session.invalidateAndCancel(); initial.invalidateForTesting() }
        let request = try BackgroundRevoiceTransfers.request(reply:XCTUnwrap(job.reply),id:job.id,origin:XCTUnwrap(job.downloadOrigin))
        let download = session.downloadTask(with:request); download.taskDescription = job.id.uuidString; download.resume()
        for _ in 0..<500 where store.job(job.id)?.phase == .downloading && probe.errorCode == nil {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertNil(probe.errorCode); XCTAssertEqual(store.job(job.id)?.phase,.waitingForForeground)
        XCTAssertNil(store.job(job.id)?.lastError)
        XCTAssertEqual(store.job(job.id)?.lastTransferFailure?.operation,"read-download")
        XCTAssertFalse(try AudioFileManager.listLocalAudio().contains { $0.id == job.id })
        initial.invalidateForTesting()
        // Simulate reopening an upgraded app: the cloud ID and draft survive,
        // and result retrieval uses GET only, bypassing the missing temp file.
        let restored = BackgroundRevoiceTransfers(store:PendingRevoiceStore(directory:store.directory),
            identifier:UUID().uuidString,configuration:.ephemeral)
        defer { restored.invalidateForTesting() }
        restored.setForeground(true); await restored.restore(); await restored.restore()
        for _ in 0..<500 where store.job(job.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.phase,.completed); XCTAssertNil(restored.pending)
        let recovered = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(recovered) }
        XCTAssertEqual(recovered.revoice?.synthesisText,job.context.text)
        let fresh = try fixtureJob(); try restored.begin(fresh)
        try restored.attach(XCTUnwrap(fresh.reply),origin:XCTUnwrap(fresh.downloadOrigin),id:fresh.id)
        for _ in 0..<500 where store.job(fresh.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(fresh.id)?.phase,.completed); XCTAssertNil(restored.pending)
        let newAsset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == fresh.id })
        defer { try? AudioFileManager.removeAudio(newAsset) }
        XCTAssertNotEqual(recovered.id,newAsset.id)
    }
    @MainActor func testLegacyStagingFailureCanBeRetrievedAfterUpgrade() async throws {
        let store = try store(); var job = try fixtureJob()
        job.phase = .suspended; job.lastError = "下载文件无法暂存，任务已保留"; job.lastTransferFailure = nil
        try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        manager.setForeground(true); await manager.restore()
        for _ in 0..<500 where store.job(job.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.phase,.completed)
        let asset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertNil(store.job(job.id)?.lastTransferFailure)
        XCTAssertEqual(asset.revoice?.instruction,job.context.instruction)
    }
    @MainActor func testForegroundRecoveryRetriesPending202AndCoalescesRepeatedRestore() async throws {
        let store = try store()
        let id = try XCTUnwrap(UUID(uuidString:"20200000"+String(UUID().uuidString.dropFirst(8))))
        var job = try fixtureJob(id:id)
        job.phase = .suspended; job.lastError = "下载文件无法暂存，任务已保留"
        try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        manager.setForeground(true); await manager.restore(); await manager.restore()
        // The HTTPS fixture returns running/202 for this ID's first GET. It
        // returns WAV on the next GET, after the production five-second wait.
        for _ in 0..<700 where store.job(job.id)?.phase != .completed { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(store.job(job.id)?.phase,.completed)
        XCTAssertEqual(store.job(job.id)?.attempts,2)
        XCTAssertNil(manager.pending)
        let asset = try XCTUnwrap(try AudioFileManager.listLocalAudio().first { $0.id == job.id })
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertEqual(asset.revoice?.jobID,job.networkID)
    }
    @MainActor func testBackgroundRequestHasOnlyJobCredentialAndFixedHTTPSOrigin() throws {
        let context = context(), reply = try reply(context)
        let origin = try CloudJobEndpoint.origin("https://unit-download.modal.run")
        let request = try BackgroundRevoiceTransfers.request(reply:reply,id:context.id,origin:origin)
        XCTAssertEqual(request.httpMethod,"GET"); XCTAssertEqual(request.url?.query,"wait=120")
        XCTAssertEqual(request.allHTTPHeaderFields,["Authorization":"Bearer "+reply.downloadToken])
        XCTAssertThrowsError(try BackgroundRevoiceTransfers.request(reply:reply,id:context.id,
            origin:CloudJobEndpoint.origin("https://other.modal.run")))
    }
    func testJobIdentityAndURLValidationRejectCrossOriginAndExpiredShape() throws {
        let context = context(), origin = try CloudJobEndpoint.origin("https://unit-download.modal.run")
        XCTAssertNoThrow(try reply(context).validated(requestID:context.id,origin:origin))
        XCTAssertThrowsError(try reply(context).validated(requestID:UUID(),origin:origin))
        XCTAssertThrowsError(try reply(context,origin:"https://different.modal.run").validated(requestID:context.id,origin:origin))
        for value in ["http://a.modal.run","https://user:pass@a.modal.run","https://a.modal.run/path","https://a.modal.run/?secret=x"] {
            XCTAssertThrowsError(try CloudJobEndpoint.origin(value))
        }
    }
    func testSaveIsIdempotentAndDetectsCorruptedExistingFile() throws {
        let context = context(); let bytes = RevoiceTestAudio.wav(seconds:1)
        let audio = try RevoiceWAV.validate(bytes,response:RevoiceTestAudio.response(bytes,choice:context.choice,duration:1),
            choice:context.choice,totalSeconds:3)
        let first = try RevoiceSaving.save(audio,context:context,jobID:context.id.uuidString)
        defer { try? AudioFileManager.removeAudio(first) }
        let again = try RevoiceSaving.save(audio,context:context,jobID:context.id.uuidString)
        XCTAssertEqual(first.id,again.id)
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { $0.id==first.id }.count,1)
        XCTAssertEqual(first.revoice?.instruction,context.instruction)
        let url = try AudioFileManager.url(for:first); try Data("broken".utf8).write(to:url,options:.atomic)
        XCTAssertThrowsError(try RevoiceSaving.save(audio,context:context))
    }
    func testLongOutputMixPreservesVoiceIdentityAndSourceRecords() throws {
        let context = context(); let bytes = RevoiceTestAudio.wav(seconds:70)
        let audio = try RevoiceWAV.validate(bytes,response:RevoiceTestAudio.response(bytes,choice:context.choice,duration:70),
            choice:context.choice,totalSeconds:3)
        let voice = try RevoiceSaving.save(audio,context:context)
        let music = try AudioFileManager.importFile(from:XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav")))
        defer { try? AudioFileManager.removeAudio(voice); try? AudioFileManager.removeAudio(music) }
        let mixed = try RecordedVoiceMixer.mix(voiceURL:AudioFileManager.url(for:voice),musicURL:AudioFileManager.url(for:music),
            settings:.init(startOffset:0.3,playbackRate:2),volumes:.init(),voiceAsset:voice,musicAsset:music)
        defer { try? AudioFileManager.removeAudio(mixed) }
        XCTAssertEqual(mixed.duration,70,accuracy:1/48000.0); XCTAssertEqual(mixed.revoice?.speakerID,"Serena")
        XCTAssertEqual(mixed.mixSource?.voiceAssetID,voice.id); XCTAssertEqual(mixed.mixSource?.musicAssetID,music.id)
        XCTAssertTrue(mixed.fileName.contains("Serena"))
    }
    func testReadableNamesPreserveSpeakerHashAndUnicodeByteBudget() {
        let instruction = String(repeating:"自然放松慵懒一点",count:20)
        let hash = SHA256.hash(data:Data(instruction.utf8)).map { String(format:"%02x",$0) }.joined().prefix(8)
        let name = AudioNaming.revoice(voiceName:"Serena",speaker:"Serena",instruction:instruction)
        XCTAssertTrue(name.contains("Serena")); XCTAssertTrue(name.contains(hash)); XCTAssertLessThanOrEqual(name.utf8.count,180)
        XCTAssertTrue(AudioNaming.revoice(voiceName:"Serena",speaker:"Serena",instruction:"").contains("自然表达"))
        XCTAssertTrue(AudioNaming.revoice(voiceName:"清润书生",speaker:nil,instruction:"",fixedReferenceID:"scholar-design").contains("scholar-design"))
        let sanitized = AudioNaming.generated(kind:"配音",label:"Serena/instruction:natural\\test",fileExtension:"wav")
        XCTAssertTrue(sanitized.contains("Serena")); XCTAssertTrue(sanitized.contains("natural")); XCTAssertFalse(sanitized.contains("/"))
    }
    @MainActor private func background(_ test:(BackgroundRevoiceTransfers,PendingRevoiceStore,PendingRevoiceJob)->Void) throws {
        let store = try store(), job = try pending(context())
        try store.save(job)
        let config = URLSessionConfiguration.ephemeral
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:config)
        defer { manager.invalidateForTesting() }
        test(manager,store,job)
    }
    @MainActor private func envelope(_ store:PendingRevoiceStore,_ job:PendingRevoiceJob,
                                    origin:String? = nil,broken:Bool = false) throws -> RevoiceDownloadEnvelope {
        let bytes = RevoiceTestAudio.wav(seconds:1)
        let template = try RevoiceTestAudio.response(bytes,choice:job.context.choice,duration:1)
        var headers = template.allHeaderFields.reduce(into:[String:String]()) { if let key=$1.key as? String { $0[key]=String(describing:$1.value) } }
        headers["X-Request-ID"] = job.networkID
        let url = try XCTUnwrap(origin.flatMap(URL.init(string:)) ?? job.reply?.downloadURL)
        let response = try XCTUnwrap(HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:headers))
        let file = store.directory.appendingPathComponent(UUID().uuidString+".tmp")
        try (broken ? Data("bad".utf8) : bytes).write(to:file)
        return try store.stage(file,id:job.id,response:response,transferID:job.transferID)
    }
    @MainActor func testLateResultAfterStopIsDiscardedAcrossManagerRestart() async throws {
        let store = try store(); var job = try pending(context()); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        manager.cancel(); XCTAssertNil(manager.pending); XCTAssertEqual(store.job(job.id)?.phase,.abandoned)
        job.phase = .abandoned
        let file = try envelope(store,job); manager.process(file)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent(file.fileName).path))
        XCTAssertFalse(try AudioFileManager.listLocalAudio().contains { $0.id == job.id })
        let restarted = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { restarted.invalidateForTesting() }; XCTAssertNil(restarted.pending)
    }
    @MainActor func testRestoredDownloadAndRepeatedCallbackSaveOneAsset() async throws {
        let store = try store(), job = try pending(context()); try store.save(job)
        let first = try envelope(store,job), duplicate = try envelope(store,job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        var saved:[AudioAsset] = []; manager.onChange = { _,_,asset in if let asset { saved.append(asset) } }
        manager.process(first)
        for _ in 0..<100 where saved.isEmpty { try await Task.sleep(for:.milliseconds(20)) }
        let asset = try XCTUnwrap(saved.first); defer { try? AudioFileManager.removeAudio(asset) }
        manager.process(duplicate); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(saved.count,1); XCTAssertEqual(store.job(job.id)?.phase,.completed); XCTAssertNil(manager.pending)
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { $0.id == asset.id }.count,1)
    }
    @MainActor func testRedirectedOrBrokenResultNeverEntersLibrary() async throws {
        for wrongOrigin in [true,false] {
            let store = try store(), job = try pending(context()); try store.save(job)
            let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
            defer { manager.invalidateForTesting() }
            let file = try envelope(store,job,origin:wrongOrigin ? "https://evil.example/v1/jobs/"+job.networkID+"/audio" : nil,broken:!wrongOrigin)
            manager.process(file)
            for _ in 0..<50 where store.job(job.id)?.phase == .downloading { try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertEqual(store.job(job.id)?.phase,wrongOrigin ? .failed : .suspended)
            XCTAssertFalse(try AudioFileManager.listLocalAudio().contains { $0.id == job.id })
        }
    }
    @MainActor func testJSONPickerAcceptsGenericFileAndCancelDeliversOnce() {
        var cancelled = 0
        let delegate = AudioDocumentPicker.Delegate(onSelection:{ _ in XCTFail("cancel") },onCancel:{ cancelled += 1 })
        let picker = JSONDocumentPicker.makePicker(delegate:delegate)
        XCTAssertTrue(picker.shouldShowFileExtensions); XCTAssertFalse(picker.allowsMultipleSelection)
        delegate.documentPickerWasCancelled(picker); delegate.documentPickerWasCancelled(picker); XCTAssertEqual(cancelled,1)
    }
    func testJSONReadBoundsAndOwnedCopyCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("generic.dat")
        try Data(repeating:32,count:8192).write(to:file)
        XCTAssertEqual(try JSONImportFile.read(file,maximumBytes:8192).count,8192)
        try Data(repeating:32,count:8193).write(to:file)
        XCTAssertThrowsError(try JSONImportFile.read(file,maximumBytes:8192))
        try Data("bad json".utf8).write(to:file)
        XCTAssertThrowsError(try CloudConnection.decode(JSONImportFile.read(file,maximumBytes:8192)))
        JSONImportFile.removePickerCopy(file); XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testSelectionSnapshotDoesNotChangeWhenAvailableOptionsChange() {
        var choices = (0..<500).map { SelectionChoice(id:$0,title:String($0)) }
        let snapshot = SelectionSnapshot(choices:choices,selected:300)
        choices.removeFirst(100)
        XCTAssertEqual(snapshot.choices.count,500); XCTAssertEqual(snapshot.choices.first?.id,0)
        XCTAssertEqual(snapshot.selected,300); XCTAssertEqual(choices.count,400)
    }
    @MainActor func testIdleCoordinatorRefreshDoesNotPublishUnchangedState() {
        let coordinator = ExperimentCoordinator(); var updates = 0
        let token = coordinator.objectWillChange.sink { updates += 1 }
        for _ in 0..<100 { coordinator.refresh() }
        XCTAssertEqual(updates,0); token.cancel()
    }
    @MainActor func testExpiredTaskUnlocksGenerationAndKeepsEditableDraft() async throws {
        let store = try store(), original = context()
        let expired = RevoiceSaveContext(id:original.id,createdAt:Date().addingTimeInterval(-25*3600),choice:original.choice,
            voiceName:original.voiceName,instruction:original.instruction,fixedReferenceID:nil,recognizedText:original.recognizedText,
            text:original.text,sourceAudioID:nil)
        var job = try pending(expired); job.reply = try reply(expired); try store.save(job)
        let manager = BackgroundRevoiceTransfers(store:store,identifier:UUID().uuidString,configuration:.ephemeral)
        defer { manager.invalidateForTesting() }
        let controller = RevoiceController(connection:nil,backgroundTransfers:manager)
        XCTAssertEqual(controller.text,expired.text)
        await manager.restore()
        XCTAssertNil(manager.pending); XCTAssertFalse(controller.hasPendingJob); XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.text,expired.text); XCTAssertEqual(store.job(job.id)?.phase,.failed)
        XCTAssertTrue(controller.status.contains("24 小时"))
    }
}
