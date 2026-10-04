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
    enum Phase:String,Codable { case submitting, downloading, suspended, abandoned, completed, failed }
    let context:RevoiceSaveContext
    let primaryOrigin:URL
    let connectionFingerprint:String
    var phase:Phase = .submitting
    var reply:CloudJobReply?
    var downloadOrigin:URL?
    var attempts = 0
    var lastError:String?
    var id:UUID { context.id }
    var networkID:String { id.uuidString.replacingOccurrences(of:"-",with:"").lowercased() }
    var expiresAt:Date { reply.map { Date(timeIntervalSince1970:$0.expiresAt) } ?? context.createdAt.addingTimeInterval(86400) }
    var isUnfinished:Bool { [.submitting,.downloading,.suspended].contains(phase) }
    var isPending:Bool { isUnfinished && expiresAt > Date() }
}

struct RevoiceDownloadEnvelope: Codable, Sendable {
    let id:UUID
    let fileName:String
    let url:URL
    let status:Int
    let headers:[String:String]
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
    func stage(_ temporary:URL,id:UUID,response:HTTPURLResponse) throws -> RevoiceDownloadEnvelope {
        try prepare()
        guard let url = response.url else { throw URLError(.badServerResponse) }
        let name = id.uuidString+"_"+UUID().uuidString+".download"
        let target = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at:temporary,to:target)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:target.path)
        let allowed = ["Content-Type","Content-Range","X-Audio-SHA256","X-Audio-Sample-Rate","X-Audio-Duration",
                       "X-Generation-Seconds","X-Model-Load-Seconds","X-Worker-Session","X-Model-Variant",
                       "X-Voice-ID","X-Speaker-ID","X-Generation-Mode","X-Model-Revision","X-Request-ID"]
        var headers:[String:String] = [:]
        for key in allowed { if let value = response.value(forHTTPHeaderField:key) { headers[key] = value } }
        let envelope = RevoiceDownloadEnvelope(id:id,fileName:name,url:url,status:response.statusCode,headers:headers)
        do {
            try JSONEncoder().encode(envelope).write(to:target.appendingPathExtension("json"),
                options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        } catch { try? FileManager.default.removeItem(at:target); throw error }
        return envelope
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
        for envelope in envelopes() where job(envelope.id) == nil || (job(envelope.id)?.expiresAt ?? .distantPast) <= Date() { remove(envelope) }
    }
}
