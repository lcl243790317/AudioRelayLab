import Foundation

private final class RevoiceRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest, completionHandler:@escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class CloudRevoiceClient: @unchecked Sendable {
    private let session:URLSession
    private let capabilityLock = NSLock()
    private var jobOrigin:URL?
    private var jobFingerprint:String?
    private let redirectBlocker = RevoiceRedirectBlocker()
    init(session:URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 180; config.timeoutIntervalForResource = 900
            config.urlCache = nil; config.httpCookieStorage = nil
            self.session = URLSession(configuration:config, delegate:redirectBlocker, delegateQueue:nil)
        }
    }
    struct Health:Decodable {
        let status:String
        let capabilities:Capabilities?
        let jobDownloadOrigin:String?
        struct Capabilities:Decodable { let customTTS:Bool; let textOnly:Bool; let asyncJobs:Bool? }
    }
    struct Voices:Decodable { let voices:[RevoiceVoice] }
    struct Speakers:Decodable { let speakers:[RevoiceSpeaker] }
    func connect(_ connection:CloudConnection) async throws -> ([RevoiceVoice],[RevoiceSpeaker]) {
        let (healthData,_,_) = try await request(connection,path:"v1/health")
        let health = try JSONDecoder().decode(Health.self,from:healthData)
        guard health.status == "ok" else { throw LabError.message("云端服务尚未就绪") }
        let origin:URL?
        if health.capabilities?.asyncJobs == true {
            guard let value = health.jobDownloadOrigin else { throw LabError.message("云端没有提供后台下载来源") }
            origin = try CloudJobEndpoint.origin(value)
        } else { origin = nil }
        let (voiceData,_,_) = try await request(connection,path:"v1/voices")
        let voices = try JSONDecoder().decode(Voices.self,from:voiceData).voices
        guard !voices.isEmpty, Set(voices.map(\.id)).count == voices.count,
              voices.allSatisfy({ !$0.id.isEmpty && ["custom","base"].contains($0.variant) }) else {
            throw LabError.message("云端预设列表不兼容，请更新服务")
        }
        var speakers:[RevoiceSpeaker] = []
        if health.capabilities?.customTTS == true && health.capabilities?.textOnly == true {
            let (speakerData,_,_) = try await request(connection,path:"v1/speakers")
            speakers = try JSONDecoder().decode(Speakers.self,from:speakerData).speakers
            guard Set(speakers.map(\.id)) == Set(RevoiceSpeaker.all.map(\.id)), speakers.count == 9 else {
                throw LabError.message("云端 speaker 列表与当前模型不匹配")
            }
        }
        try Task.checkCancellation()
        capabilityLock.withLock { jobOrigin = origin; jobFingerprint = connection.fingerprint }
        return (voices,speakers)
    }
    func downloadOrigin(for connection:CloudConnection) -> URL? {
        capabilityLock.withLock { jobFingerprint == connection.fingerprint ? jobOrigin : nil }
    }
    func submitJob(_ connection:CloudConnection, context:RevoiceSaveContext) async throws -> CloudJobReply {
        var object = try JSONSerialization.jsonObject(with:context.choice.body(text:context.text)) as? [String:Any] ?? [:]
        object["mode"] = context.choice.mode; object["requestID"] = context.id.uuidString
        let data = try JSONSerialization.data(withJSONObject:object)
        guard data.count <= 8192 else { throw LabError.message("配音请求超过允许大小") }
        let (reply,_,_) = try await request(connection,path:"v1/jobs",body:data)
        guard let origin = downloadOrigin(for:connection) else { throw LabError.message("当前云端未提供后台任务能力，请重新连接") }
        return try JSONDecoder().decode(CloudJobReply.self,from:reply).validated(requestID:context.id,origin:origin)
    }
    func job(_ connection:CloudConnection,id:UUID) async throws -> CloudJobReply {
        let value = id.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let (data,_,_) = try await request(connection,path:"v1/jobs/"+value)
        guard let origin = downloadOrigin(for:connection) else { throw LabError.message("请先重新连接云端") }
        return try JSONDecoder().decode(CloudJobReply.self,from:data).validated(requestID:id,origin:origin)
    }
    func synthesize(_ connection:CloudConnection, choice:RevoiceChoice, text:String) async throws -> RevoiceAudio {
        let body = try choice.body(text:text)
        let (data,response,seconds) = try await request(connection,path:choice.mode == "custom" ? "v1/tts/custom" : "v1/tts",body:body)
        return try RevoiceWAV.validate(data,response:response,choice:choice,totalSeconds:seconds)
    }
    private func request(_ connection:CloudConnection, path:String, body:Data? = nil) async throws -> (Data,HTTPURLResponse,Double) {
        try await withThrowingTaskGroup(of:(Data,HTTPURLResponse,Double).self) { group in
            group.addTask { try await self.requestWithinDeadline(connection,path:path,body:body) }
            group.addTask { try await Task.sleep(for:.seconds(900)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
    private func requestWithinDeadline(_ connection:CloudConnection, path:String, body:Data?) async throws -> (Data,HTTPURLResponse,Double) {
        let base = try connection.validate(), started = Date()
        var url = base.appendingPathComponent(path), method = body == nil ? "GET" : "POST", payload = body
        for _ in 0..<8 {
            try Task.checkCancellation()
            let remaining = 900-Date().timeIntervalSince(started)
            guard remaining > 0 else { throw URLError(.timedOut) }
            var request = URLRequest(url:url, cachePolicy:.reloadIgnoringLocalCacheData, timeoutInterval:min(body == nil && url.query == nil ? 12 : 180, remaining))
            request.httpMethod = method; request.httpBody = payload
            request.setValue(connection.proxyTokenID,forHTTPHeaderField:"Modal-Key")
            request.setValue(connection.proxyTokenSecret,forHTTPHeaderField:"Modal-Secret")
            request.setValue(connection.apiKey,forHTTPHeaderField:"X-AudioRelay-Key")
            if payload != nil { request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
            let (stream, rawResponse) = try await session.bytes(for:request,delegate:redirectBlocker)
            guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 303 {
                guard let location = response.value(forHTTPHeaderField:"Location") else { throw URLError(.badServerResponse) }
                url = try CloudEndpoint.resultURL(location,relativeTo:url,origin:base); method = "GET"; payload = nil
                continue
            }
            switch response.statusCode {
            case 200: break
            case 202 where path == "v1/jobs": break
            case 401,403: throw LabError.message("云端认证失败，请重新导入连接配置")
            case 429: throw LabError.message("云端正在配音或请求过于频繁，请稍后手动重试")
            case 400,413,415,422: throw LabError.message("云端拒绝了配音参数，请检查文字、speaker 和 instruction")
            default: throw LabError.message("云端生成未完成（HTTP \(response.statusCode)），可稍后重试")
            }
            let maximum = body == nil || path.hasPrefix("v1/jobs") ? 64*1024 : 10*1024*1024
            guard response.expectedContentLength <= Int64(maximum) else { throw LabError.message("云端返回的文件过大") }
            var data = Data(); data.reserveCapacity(min(maximum,max(0,Int(response.expectedContentLength))))
            for try await byte in stream {
                guard data.count < maximum else { throw LabError.message("云端返回的文件过大") }
                data.append(byte)
                if data.count%65536 == 0 {
                    try Task.checkCancellation()
                    guard Date().timeIntervalSince(started) < 900 else { throw URLError(.timedOut) }
                }
            }
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < 900 else { throw URLError(.timedOut) }
            return (data,response,Date().timeIntervalSince(started))
        }
        throw LabError.message("云端结果跳转次数过多，请稍后重试")
    }
}

enum RevoiceError {
    static func message(_ error:Error) -> String {
        if let error = error as? LabError { return error.errorDescription ?? "重新配音未完成" }
        if error is CancellationError { return "已停止等待" }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "云端等待超时；请求未自动重新提交，可稍后手动重试"
            case .cancelled: return "已停止等待"
            case .notConnectedToInternet,.networkConnectionLost: return "网络已断开，文字已保留，请恢复连接后重试"
            default: return "无法连接云端，请检查网络后重试"
            }
        }
        if error is DecodingError { return "云端响应不兼容，请更新服务后重试" }
        return "重新配音未完成，文字已保留，可重试或手动修改"
    }
}
