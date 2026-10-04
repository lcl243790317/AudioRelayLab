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
        guard pending == nil else { throw LabError.message("先取回或停止等待上一段配音") }
        try store.save(job); onChange?(job,"正在提交配音…",nil)
    }
    func attach(_ reply:CloudJobReply,origin:URL,id:UUID) throws {
        guard var job = store.job(id), job.isPending,!abandoned.contains(id) else { return }
        _ = try reply.validated(requestID:id,origin:origin)
        job.reply = reply; job.downloadOrigin = origin; job.phase = .downloading; job.lastError = nil
        job.lastTransferFailure = nil
        try store.save(job)
        if reply.state == "failed" { suspend(id,message:"云端生成失败，文字已保留",terminal:true); return }
        schedule(job)
    }
    func submissionFailed(_ id:UUID,message:String) { suspend(id,message:message,terminal:false) }
    @discardableResult func cancel() -> Bool {
        for var job in store.all() where job.isPending {
            let previous = job
            job.phase = .abandoned; job.lastError = nil
            do { try store.save(job) }
            catch { onChange?(previous,"停止等待标记无法保存，请保持 App 打开后重试",nil); return false }
            abandoned.insert(job.id)
            scheduled.remove(job.id)
            foregroundRecoveries.removeValue(forKey:job.id)?.cancel()
            let id = job.id
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription == id.uuidString { task.cancel() }
            }
            onChange?(job,"已停止等待 · 云端可能继续完成，迟到结果不会保存",nil)
        }
        return true
    }
    func setForeground(_ active:Bool) {
        isForeground = active
        if !active {
            // The cloud job continues. A foreground recovery never pretends to
            // be an iOS background transfer, and may be resumed on the next open.
            for task in foregroundRecoveries.values { task.cancel() }
        }
    }
    func handleEvents(_ handler:@escaping ()->Void) {
        completion = handler; eventsFinished = false
        Task { await restore(retrySuspended:false) }
    }
    func restore(retrySuspended:Bool = true) async {
        for job in store.all() where job.isUnfinished && job.expiresAt <= Date() { expire(job) }
        store.cleanup()
        // Incoming files were copied out of URLSession's temporary location before
        // its delegate returned. A crash during saving can therefore be recovered.
        for envelope in store.envelopes() { process(envelope) }
        let tasks = await session.allTasks
        scheduled = Set(tasks.compactMap { task in
            guard task.state != .completed, let value = task.taskDescription else { return nil }
            return UUID(uuidString:value)
        }).union(foregroundRecoveries.keys)
        for job in store.all() where job.isPending && !abandoned.contains(job.id) && !processing.contains(job.id) {
            if job.reply == nil { onNeedsSubmission?(job) }
            else if !scheduled.contains(job.id) {
                if !retrySuspended && (job.phase == .suspended || job.attempts >= 8) { continue }
                var resumed = job; resumed.attempts = 0; resumed.phase = .downloading
                do { try store.save(resumed) }
                catch { suspend(job.id,message:"任务记录暂时无法写入，请保持 App 打开后重试",terminal:false); continue }
                if retrySuspended && isForeground && Self.needsForegroundRecovery(job) { recoverInForeground(resumed) }
                else { schedule(resumed) }
            } else { onChange?(job,"配音中 · 可切换 App 或锁屏",nil) }
        }
        completeEventsIfPossible()
    }
    private func schedule(_ value:PendingRevoiceJob,after seconds:Double = 0) {
        guard !scheduled.contains(value.id),value.isPending,var job = store.job(value.id),job.isPending,
              !abandoned.contains(job.id),let reply = job.reply, let origin = job.downloadOrigin else { return }
        if isForeground && Self.needsForegroundRecovery(job) { recoverInForeground(job,after:seconds); return }
        do {
            _ = try reply.validated(requestID:job.id,origin:origin)
            if job.attempts >= 8 { suspend(job.id,message:"云端任务已保留，返回 App 后继续取回",terminal:false); return }
            let request = try Self.request(reply:reply,id:job.id,origin:origin)
            let transfer = session.downloadTask(with:request)
            transfer.taskDescription = job.id.uuidString
            if seconds > 0 { transfer.earliestBeginDate = Date().addingTimeInterval(seconds) }
            job.attempts += 1; job.phase = .downloading; try store.save(job)
            scheduled.insert(job.id); onChange?(job,"配音中 · 可切换 App 或锁屏",nil)
            transfer.resume()
        } catch { suspend(job.id,message:"无法恢复结果下载，文字和任务已保留",terminal:false) }
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
    private static func needsForegroundRecovery(_ job:PendingRevoiceJob) -> Bool {
        job.lastTransferFailure != nil || job.lastError?.contains("下载文件无法暂存") == true
    }
    private func recoverInForeground(_ value:PendingRevoiceJob,after seconds:Double = 0) {
        guard isForeground,foregroundRecoveries[value.id] == nil,!scheduled.contains(value.id),
              var job = store.job(value.id),job.isPending,!abandoned.contains(job.id),
              let reply = job.reply,let origin = job.downloadOrigin else { return }
        if job.attempts >= 8 { suspend(job.id,message:"任务已保留，稍后可继续取回",terminal:false); return }
        do {
            _ = try reply.validated(requestID:job.id,origin:origin)
            job.attempts += 1; job.phase = .downloading; try store.save(job)
        } catch { suspend(job.id,message:"无法恢复结果下载，文字和任务已保留",terminal:false); return }
        scheduled.insert(job.id); onChange?(job,"正在前台取回配音 · 无需重新生成",nil)
        foregroundRecoveries[job.id] = Task { [weak self, job] in
            guard let self else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 180
            let resultSession = URLSession(configuration:configuration)
            defer {
                resultSession.invalidateAndCancel(); self.foregroundRecoveries.removeValue(forKey:job.id)
                self.scheduled.remove(job.id)
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
                      !self.abandoned.contains(job.id) else { return }
                let envelope = try self.store.stage(data,id:job.id,response:response)
                self.process(envelope)
            } catch {
                if Task.isCancelled {
                    self.suspend(job.id,message:"任务已保留，返回 App 后继续取回",terminal:false)
                } else {
                    let failure = (error as? RevoiceTransferError)?.failure ?? RevoiceTransferFailure(operation:"foreground-retrieve",error:error)
                    self.suspend(job.id,message:"暂时无法取回配音，任务已保留（\(failure.summary)）",terminal:false,failure:failure)
                }
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
    private func suspend(_ id:UUID,message:String,terminal:Bool,failure:RevoiceTransferFailure? = nil) {
        guard var job = store.job(id),job.isUnfinished else { return }
        if job.expiresAt <= Date() { expire(job); return }
        job.phase = terminal ? .failed : .suspended; job.lastError = message
        if let failure { job.lastTransferFailure = failure }
        try? store.save(job); scheduled.remove(id); onChange?(job,message,nil)
    }
    func process(_ envelope:RevoiceDownloadEnvelope) {
        guard !processing.contains(envelope.id) else { return }
        processing.insert(envelope.id)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.store.remove(envelope); self.processing.remove(envelope.id)
                self.completeEventsIfPossible()
            }
            self.scheduled.remove(envelope.id)
            guard let job = self.store.job(envelope.id),job.isUnfinished,!self.abandoned.contains(job.id) else { return }
            if job.expiresAt <= Date() { self.expire(job); return }
            guard let origin = job.downloadOrigin,CloudJobEndpoint.sameOrigin(envelope.url,origin),
                  envelope.url.path == job.reply?.downloadURL.path,let response = envelope.response else {
                self.suspend(job.id,message:"下载来源不匹配，已拒绝保存",terminal:true); return
            }
            do {
                let url = self.store.directory.appendingPathComponent(envelope.fileName)
                let bytes = (try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard bytes > 0,bytes <= 10*1024*1024 else { throw LabError.invalidFormat }
                let data = try Data(contentsOf:url)
                if envelope.status == 202 {
                    guard bytes <= 4096 else { throw LabError.invalidFormat }
                    let object = try JSONSerialization.jsonObject(with:data) as? [String:String]
                    guard object?["id"] == job.networkID,
                          ["queued","running"].contains(object?["state"] ?? "") else { throw LabError.invalidFormat }
                    self.schedule(job,after:5); return
                }
                guard [200,206].contains(envelope.status) else {
                    let serverError = (try? JSONSerialization.jsonObject(with:data)) as? [String:String]
                    let terminal = [400,401,403,404,410,422].contains(envelope.status) || serverError?["error"] == "Generation failed"
                    self.suspend(job.id,message:terminal ? "任务已失效或认证失败，文字已保留" : "云端结果暂不可用，返回后可继续取回",terminal:terminal)
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
                guard var current = self.store.job(job.id),current.isPending,!self.abandoned.contains(job.id) else { return }
                self.onChange?(current,"保存中",nil)
                let asset = try RevoiceSaving.save(audio,context:current.context,jobID:current.networkID)
                current.phase = .completed; current.reply = nil; current.lastError = nil
                current.lastTransferFailure = nil
                try self.store.save(current)
                self.onChange?(current,"已保存 · 成品 \(AudioPlaybackSettings.time(asset.duration))",asset)
            } catch {
                self.suspend(job.id,message:"音频或保存校验未通过，未保存半成品；任务可重新取回",terminal:false)
            }
        }
    }
    private func completeEventsIfPossible() {
        guard eventsFinished,processing.isEmpty,let handler = completion else { return }
        completion = nil; eventsFinished = false; handler()
    }
    private func expire(_ value:PendingRevoiceJob) {
        var job = value; job.phase = .failed; job.reply = nil
        job.lastError = "任务已超过 24 小时取回窗口，文字已保留，可以重新生成"
        try? store.save(job); scheduled.remove(job.id)
        onChange?(job,job.lastError ?? "任务已过期",nil)
    }
    nonisolated func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        guard let value = downloadTask.taskDescription,let id = UUID(uuidString:value),
              let response = downloadTask.response as? HTTPURLResponse else { return }
        do {
            let envelope = try store.stage(location,id:id,response:response)
            Task { @MainActor [weak self] in self?.process(envelope) }
        } catch {
            let failure = (error as? RevoiceTransferError)?.failure ?? RevoiceTransferFailure(operation:"stage-download",error:error)
            Task { @MainActor [weak self] in
                self?.suspend(id,message:"下载文件无法暂存，任务已保留；可在前台取回（\(failure.summary)）",terminal:false,failure:failure)
            }
        }
    }
    nonisolated func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,
                                didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten > 10*1024*1024 || totalBytesExpectedToWrite > 10*1024*1024 { downloadTask.cancel() }
    }
    nonisolated func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        guard error != nil,let value = task.taskDescription,let id = UUID(uuidString:value) else { return }
        Task { @MainActor [weak self] in self?.suspend(id,message:"连接暂停，配音任务已保留；返回 App 后自动取回",terminal:false) }
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
