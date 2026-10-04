import Foundation
import CryptoKit
import Security

struct CloudConnection: Codable, Sendable {
    let endpoint: String
    let proxyTokenID: String
    let proxyTokenSecret: String
    let apiKey: String
    func validate() throws -> URL {
        let url = try CloudEndpoint.validate(endpoint)
        for value in [proxyTokenID, proxyTokenSecret, apiKey] {
            guard !value.isEmpty, value.utf8.count <= 512, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw LabError.message("连接配置中的密钥格式无效，请重新导入")
            }
        }
        guard apiKey.count >= 32 else { throw LabError.message("连接配置中的应用密钥不完整") }
        return url
    }
    static func decode(_ data: Data) throws -> CloudConnection {
        guard data.count <= 8192 else { throw LabError.message("连接配置文件过大") }
        do {
            let result = try JSONDecoder().decode(Self.self, from:data)
            _ = try result.validate()
            return result
        } catch let error as LabError { throw error }
        catch { throw LabError.message("请输入完整的 modal-client.json 连接配置") }
    }
}

enum CloudEndpoint {
    static func validate(_ text: String) throws -> URL {
        guard let url = URL(string:text), url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".modal.run"), url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw LabError.message("连接配置需要有效的 HTTPS Modal 地址")
        }
        return url
    }
    static func resultURL(_ location: String, relativeTo current: URL, origin: URL) throws -> URL {
        guard let url = URL(string:location, relativeTo:current)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == origin.host?.lowercased(),
              (url.port ?? 443) == (origin.port ?? 443), url.user == nil, url.password == nil,
              url.fragment == nil else {
            throw LabError.message("云端结果跳转地址不安全，已停止请求")
        }
        return url
    }
}

enum CloudConnectionStore {
    private static let base: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"AudioRelayLab.Modal", kSecAttrAccount as String:"connection"]
    static func load() -> CloudConnection? {
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? CloudConnection.decode(data)
    }
    static func save(_ connection: CloudConnection) throws {
        _ = try connection.validate()
        let attributes = [kSecValueData as String:try JSONEncoder().encode(connection)]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = base; query.merge(attributes) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LabError.message("连接配置无法保存到钥匙串，请重新签名后再导入") }
    }
}

struct RevoiceVoice: Codable, Identifiable, Hashable { let id:String; let displayName:String; let variant:String }
struct RevoiceSpeaker: Codable, Identifiable, Hashable {
    let id:String; let displayName:String
    static let all: [Self] = [
        .init(id:"Serena",displayName:"Serena · 温柔女声"), .init(id:"Vivian",displayName:"Vivian · 明亮女声"),
        .init(id:"Dylan",displayName:"Dylan · 北京青年男声"), .init(id:"Uncle_Fu",displayName:"Uncle_Fu · 醇厚男声"),
        .init(id:"Eric",displayName:"Eric · 成都男声"), .init(id:"Ryan",displayName:"Ryan · 活力英语男声"),
        .init(id:"Aiden",displayName:"Aiden · 清朗英语男声"), .init(id:"Ono_Anna",displayName:"Ono_Anna · 轻巧日语女声"),
        .init(id:"Sohee",displayName:"Sohee · 温暖韩语女声")]
}

enum RevoiceChoice: Equatable, Sendable {
    case preset(id:String, variant:String)
    case custom(speaker:String, instruction:String)
    var mode:String { if case .custom = self { return "custom" }; return "preset" }
    var variant:String { if case .preset(_, let variant) = self { return variant }; return "custom" }
    var voiceID:String { if case .preset(let id, _) = self { return id }; return "custom" }
    var speakerID:String? { if case .custom(let speaker, _) = self { return speaker }; return nil }
    var instruction:String? { if case .custom(_, let instruction) = self { return instruction }; return nil }
    func body(text:String) throws -> Data {
        let text = try RevoiceLimits.text(text)
        var values:[String:String] = ["text":text]
        switch self {
        case .preset(let id, let variant):
            guard !id.isEmpty, ["custom","base"].contains(variant) else { throw LabError.message("请选择可用的预设声线") }
            values["voice"] = id
        case .custom(let speaker, let instruction):
            guard RevoiceSpeaker.all.contains(where:{$0.id == speaker}) else { throw LabError.message("请选择模型支持的 speaker") }
            try RevoiceLimits.instruction(instruction)
            values["speaker"] = speaker; values["instruction"] = instruction
        }
        return try JSONSerialization.data(withJSONObject:values)
    }
}

enum RevoiceLimits {
    static let maximumOutputSeconds = 180.0
    static func text(_ value:String) throws -> String {
        let trimmed = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LabError.message("请先输入或识别配音文字") }
        guard trimmed.unicodeScalars.count <= 1000 else { throw LabError.message("配音文字最多 1,000 字符，请分段生成") }
        try unicode(trimmed); return trimmed
    }
    static func instruction(_ value:String) throws {
        guard value.unicodeScalars.count <= 500 else { throw LabError.message("instruction 最多 500 字符") }
        try unicode(value)
    }
    private static func unicode(_ value:String) throws {
        guard value.unicodeScalars.allSatisfy({ $0.value >= 32 || [9,10,13].contains($0.value) }) else {
            throw LabError.message("文字包含不支持的控制字符")
        }
    }
    static func output(_ seconds:Double) throws {
        guard seconds.isFinite, seconds > 0, seconds <= maximumOutputSeconds else {
            throw LabError.message("成品长度异常或超过 180 秒，未保存半成品")
        }
    }
}

struct RevoiceMetadata: Codable {
    let provider:String
    let generationMode:String
    let voiceID:String
    let speakerID:String?
    let instruction:String?
    let recognizedText:String?
    let synthesisText:String
    let sourceAudioID:UUID?
    let modelVariant:String
    let modelRevision:String
    let sha256:String
    let generationSeconds:Double
    let totalSeconds:Double
}

struct RevoiceAudio: Sendable {
    let data:Data; let duration:Double; let sha256:String; let revision:String
    let speaker:String?; let generationSeconds:Double; let totalSeconds:Double
}

enum RevoiceWAV {
    static func validate(_ data:Data, response:HTTPURLResponse, choice:RevoiceChoice, totalSeconds:Double) throws -> RevoiceAudio {
        func invalid() -> LabError { .message("云端音频或校验信息不完整，未保存半成品") }
        func word(_ offset:Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
        func number(_ offset:Int) -> Int { Int(word(offset)) | Int(word(offset+2)) << 16 }
        guard response.statusCode == 200, response.value(forHTTPHeaderField:"Content-Type")?.split(separator:";").first == "audio/wav",
              data.count >= 44, data.count <= 10*1024*1024, data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8), number(4) == data.count-8 else { throw invalid() }
        var offset = 12, formatOK = false, pcm:Range<Int>?
        while offset+8 <= data.count {
            let size = number(offset+4), start = offset+8
            guard size <= data.count-start else { throw invalid() }
            let tag = data[offset..<offset+4]
            if tag == Data("fmt ".utf8) {
                guard !formatOK, size >= 16, word(start) == 1, word(start+2) == 1,
                      number(start+4) == 24000, number(start+8) == 48000, word(start+12) == 2, word(start+14) == 16 else { throw invalid() }
                formatOK = true
            } else if tag == Data("data".utf8) {
                guard pcm == nil, size > 0, size%2 == 0 else { throw invalid() }; pcm = start..<start+size
            }
            offset = start+size+(size%2)
        }
        guard offset == data.count, formatOK, let pcm else { throw invalid() }
        let duration = Double(pcm.count)/48000
        try RevoiceLimits.output(duration)
        let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard hash == response.value(forHTTPHeaderField:"X-Audio-SHA256"),
              let supplied = Double(response.value(forHTTPHeaderField:"X-Audio-Duration") ?? ""), supplied.isFinite,
              abs(supplied-duration) <= 1.0/24000,
              response.value(forHTTPHeaderField:"X-Audio-Sample-Rate") == "24000",
              response.value(forHTTPHeaderField:"X-Model-Variant") == choice.variant,
              response.value(forHTTPHeaderField:"X-Voice-ID") == choice.voiceID,
              response.value(forHTTPHeaderField:"X-Generation-Mode") == choice.mode,
              let revision = response.value(forHTTPHeaderField:"X-Model-Revision"), revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit }),
              let generation = Double(response.value(forHTTPHeaderField:"X-Generation-Seconds") ?? ""), generation.isFinite, generation >= 0 else { throw invalid() }
        let speaker = response.value(forHTTPHeaderField:"X-Speaker-ID").flatMap { $0.isEmpty ? nil : $0 }
        if case .custom(let expected, _) = choice { guard speaker == expected else { throw invalid() } }
        var audible = false
        for i in stride(from:pcm.lowerBound,to:pcm.upperBound,by:2) {
            if abs(Int(Int16(bitPattern:word(i)))) >= 4 { audible = true; break }
        }
        guard audible else { throw invalid() }
        return .init(data:data,duration:duration,sha256:hash,revision:revision,speaker:speaker,
                     generationSeconds:generation,totalSeconds:totalSeconds)
    }
}
