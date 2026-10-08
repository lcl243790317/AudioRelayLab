import Foundation
import UIKit

/// A fixed background session survives suspension and system relaunch. Its
/// requests contain only a read-only credential for one result, never Modal keys.
@MainActor final class BackgroundRevoiceTransfers: NSObject, URLSessionDownloadDelegate {
    nonisolated static let identifier = "com.audiorelaylab.AudioRelayLab.revoice-results.v1"
    static let shared = BackgroundRevoiceTransfers()
    nonisolated let store:PendingRevoiceStore
    private let sessionIdentifier:String
    private lazy var session:URLSession = makeSession()
    private let configuration:URLSessionConfiguration?
    private var processing:Set<UUID> = []
    private var scheduled:Set<UUID> = []
    private var abandoned:Set<UUID> = []
    private var foregroundRecoveries:[UUID:Task<Void,Never>] = [:]
    private var foregroundTokens:[UUID:UUID] = [:]
    private var restoring = false
    private var restoreRequested = false
    private var isForeground = UIApplication.shared.applicationState == .active
    private var eventsFinished = false
    private var completion:(()->Void)?
    var onChange:((PendingRevoiceJob,String,AudioAsset?)->Void)?
    var onNeedsSubmission:((PendingRevoiceJob)->Void)?
    var pending:PendingRevoiceJob? { store.all().first { $0.isPending && !abandoned.contains($0.id) } }

    init(store:PendingRevoiceStore = .init(),identifier:String = BackgroundRevoiceTransfers.identifier,
         configuration:URLSessionConfiguration? = nil) {
        self.store = store; sessionIdentifier = identifier; self.configuration = configuration
        super.init()
        _ = session
    }
    private func makeSession() -> URLSession {
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier:sessionIdentifier)
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true; config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900; config.httpMaximumConnectionsPerHost = 1
        config.httpCookieStorage = nil; config.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration:config,delegate:self,delegateQueue:queue)
    }
    func begin(_ job:PendingRevoiceJob) throws {
        guard !store.all().contains(where:{$0.blocksNewSubmission}) else {
            throw LabError.message("旧任务可能仍在云端执行；请先在最近任务中继续取回，当前草稿已保留")
        }
        try store.save(job); onChange?(job,"正在提交配音…",nil)
    }
    func attach(_ reply:CloudJobReply,origin:URL,id:UUID) throws {
        guard var job = store.job(id), job.isPending,!abandoned.contains(id) else { return }
        _ = try reply.validated(requestID:id,origin:origin)
        job.reply = reply; job.downloadOrigin = origin; job.phase = .downloading; job.lastError = nil
        job.lastTransferFailure = nil; job.failureKind = nil; job.submissionRejected = false
        try store.save(job)
        if job.expiresAt <= Date() { expire(job); return }
        if reply.state == "failed" { suspend(id,message:RevoiceJobFailureKind.generation.message,terminal:true,kind:.generation); return }
        schedule(job)
    }
    func submissionFailed(_ id:UUID,message:String) { suspend(id,message:message,terminal:false) }
    func submissionFailed(_ id:UUID,error:Error) {
        let kind = RevoiceJobFailureKind.classify(error)
        let rejected = (error as? RevoiceServiceError)?.notAccepted == true
        if rejected,var job = store.job(id),job.isPending {
            job.submissionRejected = true
            do { try store.save(job) }
            catch { suspend(id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); return }
        }
        suspend(id,message:(rejected ? "本次提交未被接受。" : "")+kind.message,terminal:rejected || !kind.canRetry,kind:kind)
    }
    /// Explicitly undo a stop tombstone before any transport can be resumed.
    func resume(_ id:UUID) throws {
        guard var job = store.job(id),job.expiresAt > Date() else { throw RevoiceServiceError(kind:.expired) }
        guard job.canRetrieve else { throw RevoiceServiceError(kind:job.failureKind ?? .generation) }
        guard !store.all().contains(where:{$0.id != id && $0.blocksNewSubmission}) else {
            throw LabError.message("请先完成当前云端任务，再取回这份任务")
        }
        guard !processing.contains(id) else { throw LabError.message("正在结束上次结果校验，请稍后继续取回") }
        let oldTransfer = job.transferID
        job.phase = job.reply == nil ? .submitting : .downloading
        job.transferID = UUID(); job.attempts = 0; job.lastError = nil; job.failureKind = nil
        job.submissionRejected = nil
        try store.save(job)
        abandoned.remove(id); scheduled.remove(id)
        foregroundTokens.removeValue(forKey:id)
        foregroundRecoveries.removeValue(forKey:id)?.cancel()
        // The new transfer token makes old native cancellation callbacks harmless.
        session.getAllTasks { tasks in
            for task in tasks where Self.identity(task.taskDescription)?.id == id && Self.identity(task.taskDescription)?.transferID == oldTransfer { task.cancel() }
        }
        if job.reply == nil { onNeedsSubmission?(job) } else { schedule(job) }
    }
    @discardableResult func cancel() -> Bool {
        for var job in store.all() where job.isPending {
            let previous = job
            job.phase = .abandoned; job.lastError = nil
            do { try store.save(job) }
            catch { onChange?(previous,"停止等待标记无法保存，请保持 App 打开后重试",nil); return false }
            abandoned.insert(job.id)
            scheduled.remove(job.id)
            foregroundRecoveries.removeValue(forKey:job.id)?.cancel()
            foregroundTokens.removeValue(forKey:job.id)
            let id = job.id
            let oldTransfer = previous.transferID
            session.getAllTasks { tasks in
                for task in tasks where Self.identity(task.taskDescription)?.id == id && Self.identity(task.taskDescription)?.transferID == oldTransfer { task.cancel() }
            }
            onChange?(job,"已停止等待 · 云端可能继续完成，迟到结果不会保存",nil)
        }
        return true
    }
    func setForeground(_ active:Bool) {
        guard isForeground != active else { return }
        isForeground = active
        guard store.all().contains(where: { $0.isPending && $0.reply != nil }) else { return }
        // Invalidate the old transport before cancelling it. Its late callbacks
        // can no longer change the same cloud job's new transport or save twice.
        for var job in store.all() where job.isPending && job.reply != nil && !processing.contains(job.id) {
            job.transferID = UUID(); job.attempts = 0
            do { try store.save(job) }
            catch { continue }
            scheduled.remove(job.id)
            foregroundTokens.removeValue(forKey:job.id)
            foregroundRecoveries.removeValue(forKey:job.id)?.cancel()
        }
        Task { await restore(retrySuspended:active) }
    }
    func handleEvents(_ handler:@escaping ()->Void) {
        completion = handler; eventsFinished = false
        Task { await restore(retrySuspended:false) }
    }
    func restore(retrySuspended:Bool = true) async {
        guard !restoring else { restoreRequested = true; return }
        restoring = true
        defer {
            restoring = false
            if restoreRequested { restoreRequested = false; Task { await restore(retrySuspended:isForeground) } }
        }
        for job in store.all() where job.isUnfinished && job.expiresAt <= Date() { expire(job) }
        store.cleanup()
        // Incoming files were copied out of URLSession's temporary location before
        // its delegate returned. A crash during saving can therefore be recovered.
        for envelope in store.envelopes() { process(envelope) }
        let tasks = await session.allTasks
        var nativeIDs:Set<UUID> = []
        for task in tasks where task.state != .completed {
            guard let identity = Self.identity(task.taskDescription),let job = store.job(identity.id),
                  job.isPending,job.transferID == identity.transferID,!isForeground else { task.cancel(); continue }
            nativeIDs.insert(identity.id)
        }
        scheduled = nativeIDs.union(foregroundRecoveries.keys)
        for job in store.all() where job.isPending && !abandoned.contains(job.id) && !processing.contains(job.id) {
            if let kind = job.failureKind,[RevoiceJobFailureKind.authentication,.configuration,.validation,.localSave].contains(kind) { continue }
            if job.reply == nil { onNeedsSubmission?(job) }
            else if !scheduled.contains(job.id) {
                if !isForeground && job.phase == .waitingForForeground { continue }
                if !retrySuspended && (job.phase == .suspended || job.attempts >= 8) { continue }
                var resumed = job; resumed.attempts = 0; resumed.phase = .downloading
                do { try store.save(resumed) }
                catch { suspend(job.id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); continue }
                schedule(resumed)
            } else { onChange?(job,"配音中 · 可切换 App 或锁屏",nil) }
        }
        completeEventsIfPossible()
    }
    private func schedule(_ value:PendingRevoiceJob,after seconds:Double = 0) {
        guard !scheduled.contains(value.id),value.isPending,var job = store.job(value.id),job.isPending,
              !abandoned.contains(job.id),let reply = job.reply, let origin = job.downloadOrigin else { return }
        if isForeground { recoverInForeground(job,after:seconds); return }
        do {
            _ = try reply.validated(requestID:job.id,origin:origin)
            if job.attempts >= 8 { suspend(job.id,message:"云端任务已保留，返回 App 后继续取回",terminal:false); return }
            let request = try Self.request(reply:reply,id:job.id,origin:origin)
            let transfer = session.downloadTask(with:request)
            let token = UUID(); job.transferID = token
            transfer.taskDescription = job.id.uuidString+"|"+token.uuidString
            if seconds > 0 { transfer.earliestBeginDate = Date().addingTimeInterval(seconds) }
            job.attempts += 1; job.phase = .downloading; try store.save(job)
            scheduled.insert(job.id); onChange?(job,"配音中 · 可切换 App 或锁屏",nil)
            transfer.resume()
        } catch {
            let kind = RevoiceJobFailureKind.classify(error)
            suspend(job.id,message:kind.message,terminal:!kind.canRetry,kind:kind)
        }
    }
    static func request(reply:CloudJobReply,id:UUID,origin:URL) throws -> URLRequest {
        _ = try reply.validated(requestID:id,origin:origin)
        var components = URLComponents(url:reply.downloadURL,resolvingAgainstBaseURL:false)
        components?.queryItems = [.init(name:"wait",value:"120")]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:180)
        request.setValue("Bearer "+reply.downloadToken,forHTTPHeaderField:"Authorization")
        return request
    }
    private nonisolated static func identity(_ description:String?) -> (id:UUID,transferID:UUID?)? {
        guard let description else { return nil }
        let parts = description.split(separator:"|",omittingEmptySubsequences:false)
        guard (1...2).contains(parts.count),let id = UUID(uuidString:String(parts[0])) else { return nil }
        if parts.count == 1 { return (id,nil) } // Existing background sessions.
        guard let token = UUID(uuidString:String(parts[1])) else { return nil }
        return (id,token)
    }
    private func recoverInForeground(_ value:PendingRevoiceJob,after seconds:Double = 0) {
        guard isForeground,foregroundRecoveries[value.id] == nil,!scheduled.contains(value.id),
              var job = store.job(value.id),job.isPending,!abandoned.contains(job.id),
              let reply = job.reply,let origin = job.downloadOrigin else { return }
        if job.attempts >= 8 { suspend(job.id,message:"任务已保留，稍后可继续取回",terminal:false); return }
        do {
            _ = try reply.validated(requestID:job.id,origin:origin)
            job.attempts += 1; job.phase = .downloading; job.lastError = nil
            job.transferID = UUID(); try store.save(job)
        } catch {
            let kind = RevoiceJobFailureKind.classify(error)
            suspend(job.id,message:kind.message,terminal:!kind.canRetry,kind:kind); return
        }
        guard let token = job.transferID else { return }
        foregroundTokens[job.id] = token
        scheduled.insert(job.id); onChange?(job,"配音中 · 可切换 App 或锁屏",nil)
        foregroundRecoveries[job.id] = Task { [weak self, job] in
            guard let self else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = self.configuration?.protocolClasses
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 180
            let resultSession = URLSession(configuration:configuration)
            defer {
                resultSession.invalidateAndCancel()
                if self.foregroundTokens[job.id] == token {
                    self.foregroundRecoveries.removeValue(forKey:job.id)
                    self.foregroundTokens.removeValue(forKey:job.id)
                    self.scheduled.remove(job.id)
                }
            }
            do {
                if seconds > 0 { try await Task.sleep(for:.seconds(seconds)) }
                try Task.checkCancellation()
                let request = try Self.request(reply:reply,id:job.id,origin:origin)
                // Streaming bypasses daemon-owned download files, and keeps the
                // same 10 MiB cap even if Content-Length is absent or dishonest.
                let (bytes,response) = try await resultSession.bytes(for:request,delegate:RevoiceResultRedirectBlocker())
                guard let response = response as? HTTPURLResponse,
                      let url = response.url,CloudJobEndpoint.sameOrigin(url,origin),url.path == reply.downloadURL.path,
                      response.expectedContentLength <= 10*1024*1024 else { throw URLError(.badServerResponse) }
                let data = try await Self.readResultBytes(bytes,expectedLength:response.expectedContentLength)
                try Task.checkCancellation()
                guard self.isForeground,let current = self.store.job(job.id),current.isPending,
                      current.transferID == token,!self.abandoned.contains(job.id) else { return }
                let envelope = try self.store.stage(data,id:job.id,response:response,transferID:token)
                self.process(envelope)
            } catch {
                guard self.store.job(job.id)?.transferID == token, !Task.isCancelled else { return }
                if self.isForeground {
                    let failure = (error as? RevoiceTransferError)?.failure ?? RevoiceTransferFailure(operation:"foreground-retrieve",error:error)
                    let kind = RevoiceJobFailureKind.classify(error)
                    self.suspend(job.id,message:kind.message,terminal:!kind.canRetry,failure:failure,kind:kind)
                } else { self.waitForForeground(job.id,failure:nil) }
            }
        }
    }
    private nonisolated static func readResultBytes(_ bytes:URLSession.AsyncBytes,expectedLength:Int64) async throws -> Data {
        try await withTaskCancellationHandler {
            // This helper runs off MainActor. Buffered byte iteration and large
            // WAV accumulation must not stall editing, scrolling or Stop.
            var data = Data()
            if expectedLength > 0 { data.reserveCapacity(Int(expectedLength)) }
            for try await byte in bytes {
                guard data.count < 10*1024*1024 else { throw URLError(.dataLengthExceedsMaximum) }
                if data.count%65536 == 0 { try Task.checkCancellation() }
                data.append(byte)
            }
            return data
        } onCancel: { bytes.task.cancel() }
    }
    func invalidateForTesting() {
        for task in foregroundRecoveries.values { task.cancel() }
        session.invalidateAndCancel()
    }
    private func suspend(_ id:UUID,message:String,terminal:Bool,failure:RevoiceTransferFailure? = nil,kind:RevoiceJobFailureKind? = nil) {
        guard var job = store.job(id),job.isUnfinished else { return }
        if job.expiresAt <= Date() { expire(job); return }
        job.phase = terminal ? .failed : .suspended; job.lastError = message
        job.failureKind = kind ?? .network
        if let failure { job.lastTransferFailure = failure }
        do { try store.save(job) }
        catch {
            job.failureKind = .localSave
            job.lastError = "本次任务状态保存失败，尚未持久化；请保持 App 打开。"+RevoiceJobFailureKind.localSave.message
            onChange?(job,job.lastError ?? RevoiceJobFailureKind.localSave.message,nil); return
        }
        scheduled.remove(id); onChange?(job,message,nil)
    }
    private func waitForForeground(_ id:UUID,failure:RevoiceTransferFailure?) {
        guard var job = store.job(id),job.isPending,!abandoned.contains(id) else { return }
        job.phase = .waitingForForeground; job.lastError = nil
        if let failure { job.lastTransferFailure = failure }
        do { try store.save(job) }
        catch { suspend(id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); return }
        scheduled.remove(id)
        onChange?(job,"配音任务已保留，返回 App 后自动保存",nil)
        if isForeground {
            job.attempts = 0
            do { try store.save(job) }
            catch { suspend(id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); return }
            schedule(job)
        }
    }
    func process(_ envelope:RevoiceDownloadEnvelope) {
        guard let current = store.job(envelope.id),current.isPending,current.transferID == envelope.transferID,
              !abandoned.contains(envelope.id) else { store.remove(envelope); return }
        guard !processing.contains(envelope.id) else { return }
        processing.insert(envelope.id)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.store.remove(envelope); self.processing.remove(envelope.id)
                self.completeEventsIfPossible()
            }
            self.scheduled.remove(envelope.id)
            guard let job = self.store.job(envelope.id),job.isUnfinished,
                  job.transferID == envelope.transferID,!self.abandoned.contains(job.id) else { return }
            if job.expiresAt <= Date() { self.expire(job); return }
            guard let origin = job.downloadOrigin,CloudJobEndpoint.sameOrigin(envelope.url,origin),
                  envelope.url.path == job.reply?.downloadURL.path,let response = envelope.response else {
                self.suspend(job.id,message:RevoiceJobFailureKind.validation.message,terminal:false,kind:.validation); return
            }
            do {
                let url = self.store.directory.appendingPathComponent(envelope.fileName)
                let bytes = (try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard bytes > 0,bytes <= 10*1024*1024 else { throw LabError.invalidFormat }
                let data = try Data(contentsOf:url)
                if envelope.status == 202 {
                    guard bytes <= 4096 else { throw LabError.invalidFormat }
                    let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:String]
                    guard object?["id"] == job.networkID,
                          ["queued","running"].contains(object?["state"] ?? "") else { throw LabError.invalidFormat }
                    var updated = job
                    if let reply = job.reply,let state = object?["state"] {
                        updated.reply = .init(id:reply.id,state:state,createdAt:reply.createdAt,expiresAt:reply.expiresAt,
                            downloadURL:reply.downloadURL,downloadToken:reply.downloadToken,error:nil)
                    }
                    try self.store.save(updated); self.schedule(updated,after:5); return
                }
                guard [200,206].contains(envelope.status) else {
                    let serverError = (try? JSONSerialization.jsonObject(with:data)) as? [String:String]
                    let kind:RevoiceJobFailureKind
                    switch envelope.status {
                    case 300...399: kind = .validation
                    case 401,403: kind = .authentication
                    case 404,410: kind = .expired
                    case 429: kind = .busy
                    case 400,422: kind = .parameters
                    default: kind = serverError?["error"] == "Generation failed" ? .generation : .network
                    }
                    self.suspend(job.id,message:kind.message,terminal:!kind.canRetry,kind:kind)
                    return
                }
                guard response.value(forHTTPHeaderField:"X-Request-ID") == job.networkID else { throw LabError.invalidFormat }
                let work = Task.detached {
                    try RevoiceWAV.validate(data,response:response,choice:job.context.choice,
                        totalSeconds:max(0,Date().timeIntervalSince(job.context.createdAt)))
                }
                let audio = try await work.value
                // Re-read cancellation after validation. Saving/registration below
                // is one MainActor transaction; cancellation cannot race it.
                guard var current = self.store.job(job.id),current.isPending,
                      current.transferID == envelope.transferID,!self.abandoned.contains(job.id) else { return }
                current.phase = .saving
                do { try self.store.save(current) }
                catch { self.suspend(job.id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); return }
                self.onChange?(current,"保存中",nil)
                let asset:AudioAsset
                do { asset = try RevoiceSaving.save(audio,context:current.context,jobID:current.networkID) }
                catch {
                    if let value = error as? LabError,case .invalidFormat = value {
                        self.suspend(job.id,message:"成品文件校验失败，请在音频库检查已有成品，再取回同一任务",terminal:false,kind:.validation)
                    } else { self.suspend(job.id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave) }
                    return
                }
                current.phase = .completed; current.reply = nil; current.lastError = nil
                current.lastTransferFailure = nil; current.failureKind = nil
                do { try self.store.save(current) }
                catch { self.suspend(job.id,message:RevoiceJobFailureKind.localSave.message,terminal:false,kind:.localSave); return }
                self.onChange?(current,"已保存 · 成品 \(AudioPlaybackSettings.time(asset.duration))",asset)
            } catch {
                guard self.store.job(job.id)?.transferID == envelope.transferID else { return }
                let domain = (error as NSError).domain
                let kind:RevoiceJobFailureKind = [NSCocoaErrorDomain,NSPOSIXErrorDomain].contains(domain) ? .localSave : .validation
                self.suspend(job.id,message:kind.message,terminal:false,kind:kind)
            }
        }
    }
    private func completeEventsIfPossible() {
        guard eventsFinished,processing.isEmpty,let handler = completion else { return }
        completion = nil; eventsFinished = false; handler()
    }
    private func expire(_ value:PendingRevoiceJob) {
        var job = value; job.phase = .failed; job.reply = nil
        job.failureKind = .expired; job.lastError = RevoiceJobFailureKind.expired.message
        try? store.save(job); scheduled.remove(job.id)
        onChange?(job,job.lastError ?? "任务已过期",nil)
    }
    nonisolated func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        guard let identity = Self.identity(downloadTask.taskDescription),
              let response = downloadTask.response as? HTTPURLResponse else { return }
        do {
            let envelope = try store.stage(location,id:identity.id,response:response,transferID:identity.transferID)
            Task { @MainActor [weak self] in self?.process(envelope) }
        } catch {
            let failure = (error as? RevoiceTransferError)?.failure ?? RevoiceTransferFailure(operation:"stage-download",error:error)
            Task { @MainActor [weak self] in
                guard let self,self.store.job(identity.id)?.transferID == identity.transferID else { return }
                self.waitForForeground(identity.id,failure:failure)
            }
        }
    }
    nonisolated func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                                newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        // A task credential is only valid at its verified, direct result endpoint.
        completionHandler(nil)
    }
    nonisolated func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,
                                didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten > 10*1024*1024 || totalBytesExpectedToWrite > 10*1024*1024 { downloadTask.cancel() }
    }
    nonisolated func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        guard error != nil,let identity = Self.identity(task.taskDescription) else { return }
        Task { @MainActor [weak self] in
            guard let self,self.store.job(identity.id)?.transferID == identity.transferID,
                  self.store.job(identity.id)?.phase == .downloading else { return }
            self.waitForForeground(identity.id,failure:nil)
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session:URLSession) {
        Task { @MainActor [weak self] in
            self?.eventsFinished = true; self?.completeEventsIfPossible()
        }
    }
}

/// Async result endpoints are direct URLs. Redirecting the job token is never
/// necessary, so foreground recovery rejects redirects before another request.
private final class RevoiceResultRedirectBlocker:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        completionHandler(nil)
    }
}

@MainActor final class RevoiceBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,
                     completionHandler:@escaping ()->Void) {
        guard identifier == BackgroundRevoiceTransfers.identifier else { completionHandler(); return }
        BackgroundRevoiceTransfers.shared.handleEvents(completionHandler)
    }
}
