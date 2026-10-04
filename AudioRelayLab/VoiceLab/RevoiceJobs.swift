import Foundation
import CryptoKit

struct CloudJobReply: Codable, Sendable {
    let id:String
    let state:String
    let createdAt:Double
    let expiresAt:Double
    let downloadURL:URL
    let downloadToken:String
    let error:String?
    func validated(requestID:UUID, origin:URL) throws -> CloudJobReply {
        guard id == requestID.uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
              ["queued","running","complete","failed"].contains(state),
              createdAt.isFinite, expiresAt.isFinite, expiresAt > createdAt, expiresAt-createdAt <= 86401,
              downloadToken.count == 64, downloadToken.allSatisfy({ $0.isHexDigit }),
              CloudJobEndpoint.sameOrigin(downloadURL,origin), downloadURL.query == nil,
              downloadURL.path == "/v1/jobs/\(id)/audio" else {
            throw LabError.message("云端任务或下载地址不兼容，未开始下载")
        }
        return self
    }
}

enum CloudJobEndpoint {
    static func sameOrigin(_ url:URL,_ origin:URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? 443) == (origin.port ?? 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    static func origin(_ value:String) throws -> URL {
        guard let url = URL(string:value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw LabError.message("后台下载来源不兼容") }
        return url
    }
}

extension CloudConnection {
    var fingerprint:String {
        let data = Data([endpoint,proxyTokenID,proxyTokenSecret,apiKey].joined(separator:"\n").utf8)
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
}

struct RevoiceSaveContext: Codable, Sendable {
    let id:UUID
    let createdAt:Date
    let choice:RevoiceChoice
    let voiceName:String
    let instruction:String
    let fixedReferenceID:String?
    let recognizedText:String?
    let text:String
    let sourceAudioID:UUID?
}

struct PendingRevoiceJob: Codable, Sendable, Identifiable {
    enum Phase:String,Codable { case submitting, downloading, waitingForForeground, suspended, abandoned, completed, failed }
    let context:RevoiceSaveContext
    let primaryOrigin:URL
    let connectionFingerprint:String
    var phase:Phase = .submitting
    var reply:CloudJobReply?
    var downloadOrigin:URL?
    var attempts = 0
    var lastError:String?
    var lastTransferFailure:RevoiceTransferFailure?
    var transferID:UUID?
    var id:UUID { context.id }
    var networkID:String { id.uuidString.replacingOccurrences(of:"-",with:"").lowercased() }
    var expiresAt:Date { reply.map { Date(timeIntervalSince1970:$0.expiresAt) } ?? context.createdAt.addingTimeInterval(86400) }
    var isUnfinished:Bool { [.submitting,.downloading,.waitingForForeground,.suspended].contains(phase) }
    var isPending:Bool { isUnfinished && expiresAt > Date() }
}

/// Only fixed operation names and Foundation error identifiers are retained.
/// NSError descriptions/userInfo can include download URLs, tokens or paths.
struct RevoiceTransferFailure: Codable, Sendable {
    let operation:String
    let domain:String
    let code:Int
    let underlyingDomain:String?
    let underlyingCode:Int?
    init(operation:String,error:Error) {
        let value = error as NSError
        self.operation = operation; domain = Self.safeDomain(value.domain); code = value.code
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        underlyingDomain = underlying.map { Self.safeDomain($0.domain) }; underlyingCode = underlying?.code
    }
    private static func safeDomain(_ value:String) -> String {
        [NSCocoaErrorDomain,NSPOSIXErrorDomain,NSURLErrorDomain].contains(value) ? value : "Error"
    }
    var summary:String {
        let underlying = underlyingDomain.flatMap { domain in underlyingCode.map { " / \(domain):\($0)" } } ?? ""
        return "\(operation) · \(domain):\(code)\(underlying)"
    }
}

struct RevoiceTransferError: Error, Sendable {
    let failure:RevoiceTransferFailure
}

struct RevoiceDownloadEnvelope: Codable, Sendable {
    let id:UUID
    let fileName:String
    let url:URL
    let status:Int
    let headers:[String:String]
    var transferID:UUID? = nil
    var response:HTTPURLResponse? { HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers) }
}

/// Atomic files live outside the user audio library and are excluded from backup.
struct PendingRevoiceStore: Sendable {
    let directory:URL
    init(directory:URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("revoice-jobs",isDirectory:true)
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,
            attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath:directory.path)
        var target = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
    func save(_ job:PendingRevoiceJob) throws {
        try prepare()
        try JSONEncoder().encode(job).write(to:directory.appendingPathComponent(job.id.uuidString+".job.json"),
            options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func job(_ id:UUID) -> PendingRevoiceJob? {
        guard let data = try? Data(contentsOf:directory.appendingPathComponent(id.uuidString+".job.json")),
              let value = try? JSONDecoder().decode(PendingRevoiceJob.self,from:data), value.id == id else { return nil }
        return value
    }
    func all() -> [PendingRevoiceJob] {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".job.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf:url) else { return nil }
                return try? JSONDecoder().decode(PendingRevoiceJob.self,from:data)
            }.sorted { $0.context.createdAt > $1.context.createdAt }
    }
    func stage(_ temporary:URL,id:UUID,response:HTTPURLResponse,transferID:UUID? = nil) throws -> RevoiceDownloadEnvelope {
        // A URLSession temporary file is only borrowed for this delegate callback.
        // Read it synchronously; moving/unlinking it or changing its attributes can
        // require permissions the download daemon does not grant to a signed app.
        // Atomic writes create our own protected files without inheriting the
        // daemon file's owner, protection class or read-only access capability.
        let operation = "read-download"
        let name = id.uuidString+"_"+UUID().uuidString+".download"
        let target = directory.appendingPathComponent(name)
        do {
            let reader = try FileHandle(forReadingFrom:temporary)
            defer { try? reader.close() }
            var data = Data()
            while let chunk = try reader.read(upToCount:512*1024),!chunk.isEmpty {
                guard data.count+chunk.count <= 10*1024*1024 else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(chunk)
            }
            return try stage(data,id:id,response:response,fileName:name,transferID:transferID)
        } catch let error as RevoiceTransferError { throw error }
        catch {
            // A failed copy never destroys the borrowed source or a previous
            // successful download. Only this attempt's app-owned files are removed.
            try? FileManager.default.removeItem(at:target)
            throw RevoiceTransferError(failure:.init(operation:operation,error:error))
        }
    }
    func stage(_ data:Data,id:UUID,response:HTTPURLResponse,fileName:String? = nil,transferID:UUID? = nil) throws -> RevoiceDownloadEnvelope {
        var operation = "prepare-staging"
        let name = fileName ?? id.uuidString+"_"+UUID().uuidString+".download"
        guard name == URL(fileURLWithPath:name).lastPathComponent,name.hasPrefix(id.uuidString+"_") else {
            throw RevoiceTransferError(failure:.init(operation:operation,error:URLError(.badServerResponse)))
        }
        let target = directory.appendingPathComponent(name)
        do {
            try prepare()
            guard let url = response.url, !data.isEmpty,data.count <= 10*1024*1024 else {
                throw URLError(.badServerResponse)
            }
            operation = "write-download"
            try data.write(to:target,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            let allowed = ["Content-Type","Content-Range","X-Audio-SHA256","X-Audio-Sample-Rate","X-Audio-Duration",
                       "X-Generation-Seconds","X-Model-Load-Seconds","X-Worker-Session","X-Model-Variant",
                       "X-Voice-ID","X-Speaker-ID","X-Generation-Mode","X-Model-Revision","X-Request-ID"]
            var headers:[String:String] = [:]
            for key in allowed { if let value = response.value(forHTTPHeaderField:key) { headers[key] = value } }
            let envelope = RevoiceDownloadEnvelope(id:id,fileName:name,url:url,status:response.statusCode,headers:headers,transferID:transferID)
            operation = "write-receipt"
            try JSONEncoder().encode(envelope).write(to:target.appendingPathExtension("json"),
                options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            return envelope
        } catch {
            try? FileManager.default.removeItem(at:target)
            try? FileManager.default.removeItem(at:target.appendingPathExtension("json"))
            throw RevoiceTransferError(failure:.init(operation:operation,error:error))
        }
    }
    func envelopes() -> [RevoiceDownloadEnvelope] {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".download.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf:url),let value = try? JSONDecoder().decode(RevoiceDownloadEnvelope.self,from:data),
                      value.fileName == URL(fileURLWithPath:value.fileName).lastPathComponent,
                      value.fileName.hasPrefix(value.id.uuidString+"_") else { return nil }
                return value
            }
    }
    func remove(_ envelope:RevoiceDownloadEnvelope) {
        guard envelope.fileName == URL(fileURLWithPath:envelope.fileName).lastPathComponent else { return }
        let target = directory.appendingPathComponent(envelope.fileName)
        try? FileManager.default.removeItem(at:target)
        try? FileManager.default.removeItem(at:target.appendingPathExtension("json"))
    }
    func cleanup() {
        for job in all() where !job.isUnfinished && job.context.createdAt.addingTimeInterval(7*86400) <= Date() {
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(job.id.uuidString+".job.json"))
        }
        for envelope in envelopes() where job(envelope.id) == nil || job(envelope.id)?.isUnfinished == false
            || (job(envelope.id)?.expiresAt ?? .distantPast) <= Date() { remove(envelope) }
    }
}
