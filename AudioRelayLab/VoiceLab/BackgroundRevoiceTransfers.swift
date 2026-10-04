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
        try store.save(job)
        if reply.state == "failed" { suspend(id,message:"云端生成失败，文字已保留",terminal:true); return }
        schedule(job)
    }
    func submissionFailed(_ id:UUID,message:String) { suspend(id,message:message,terminal:false) }
    func cancel() {
        for var job in store.all() where job.isPending {
            abandoned.insert(job.id)
            job.phase = .abandoned; job.lastError = nil
            do { try store.save(job) }
            catch { onChange?(job,"停止等待标记无法保存，请保持 App 打开后重试",nil); return }
            scheduled.remove(job.id)
            let id = job.id
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription == id.uuidString { task.cancel() }
            }
            onChange?(job,"已停止等待 · 云端可能继续完成，迟到结果不会保存",nil)
        }
    }
    func handleEvents(_ handler:@escaping ()->Void) {
        completion = handler; eventsFinished = false
        Task { await restore(retrySuspended:false) }
    }
    func restore(retrySuspended:Bool = true) async {
        for job in store.all() where job.isUnfinished && job.expiresAt <= Date() { expire(job) }
        store.cleanup()
        // Incoming files were moved out of URLSession's temporary location before
        // its delegate returned. A crash during saving can therefore be recovered.
        for envelope in store.envelopes() { process(envelope) }
        let tasks = await session.allTasks
        scheduled = Set(tasks.compactMap { task in
            guard task.state != .completed, let value = task.taskDescription else { return nil }
            return UUID(uuidString:value)
        })
        for job in store.all() where job.isPending && !abandoned.contains(job.id) && !processing.contains(job.id) {
            if job.reply == nil { onNeedsSubmission?(job) }
            else if !scheduled.contains(job.id) {
                if !retrySuspended && (job.phase == .suspended || job.attempts >= 8) { continue }
                var resumed = job; resumed.attempts = 0; resumed.phase = .downloading
                try? store.save(resumed); schedule(resumed)
            } else { onChange?(job,"配音中 · 可切换 App 或锁屏",nil) }
        }
        completeEventsIfPossible()
    }
    private func schedule(_ value:PendingRevoiceJob,after seconds:Double = 0) {
        guard !scheduled.contains(value.id),value.isPending,var job = store.job(value.id),job.isPending,
              !abandoned.contains(job.id),let reply = job.reply, let origin = job.downloadOrigin else { return }
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
    func invalidateForTesting() { session.invalidateAndCancel() }
    private func suspend(_ id:UUID,message:String,terminal:Bool) {
        guard var job = store.job(id),job.isUnfinished else { return }
        if job.expiresAt <= Date() { expire(job); return }
        job.phase = terminal ? .failed : .suspended; job.lastError = message
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
            Task { @MainActor [weak self] in self?.suspend(id,message:"下载文件无法暂存，任务已保留",terminal:false) }
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

@MainActor final class RevoiceBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,
                     completionHandler:@escaping ()->Void) {
        guard identifier == BackgroundRevoiceTransfers.identifier else { completionHandler(); return }
        BackgroundRevoiceTransfers.shared.handleEvents(completionHandler)
    }
}
