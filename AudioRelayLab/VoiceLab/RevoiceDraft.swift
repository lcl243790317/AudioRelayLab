import Foundation

enum SpeechInsertionMode:String,Codable,CaseIterable { case replace, append }

/// Editing data only. Connection secrets and submitted job snapshots belong elsewhere.
struct RevoiceDraft:Codable,Equatable {
    var version = 1
    var text = ""
    var kind = "preset"
    var preset = "serena-original"
    var speaker = "Serena"
    var customInstruction = ""
    var presetInstruction = ""
    var instructionPresetID:String?
    var automatic = false
    var automaticDraft:AutomaticInstructionDraft?
    var inputID:UUID?
    var recognitionRange:RevoiceRecognitionRange?
    var insertionMode:SpeechInsertionMode = .replace
    var recognizedText:String?

    init() {}
    enum CodingKeys:String,CodingKey {
        case version,text,kind,preset,speaker,customInstruction,presetInstruction,instructionPresetID
        case automatic,automaticDraft,inputID,recognitionRange,insertionMode,recognizedText
    }
    // Older files and individual damaged fields do not discard the readable text.
    init(from decoder:Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = (try? c.decode(Int.self,forKey:.version)) ?? 0
        text = (try? c.decode(String.self,forKey:.text)) ?? ""
        kind = (try? c.decode(String.self,forKey:.kind)) ?? kind
        preset = (try? c.decode(String.self,forKey:.preset)) ?? preset
        speaker = (try? c.decode(String.self,forKey:.speaker)) ?? speaker
        customInstruction = (try? c.decode(String.self,forKey:.customInstruction)) ?? ""
        presetInstruction = (try? c.decode(String.self,forKey:.presetInstruction)) ?? ""
        instructionPresetID = try? c.decode(String.self,forKey:.instructionPresetID)
        automatic = (try? c.decode(Bool.self,forKey:.automatic)) ?? false
        automaticDraft = try? c.decode(AutomaticInstructionDraft.self,forKey:.automaticDraft)
        inputID = try? c.decode(UUID.self,forKey:.inputID)
        recognitionRange = try? c.decode(RevoiceRecognitionRange.self,forKey:.recognitionRange)
        insertionMode = (try? c.decode(SpeechInsertionMode.self,forKey:.insertionMode)) ?? .replace
        recognizedText = try? c.decode(String.self,forKey:.recognizedText)
    }
}

struct RevoiceDraftStore {
    let directory:URL
    var file:URL { directory.appendingPathComponent("editing-v1.json") }
    var backup:URL { directory.appendingPathComponent("editing-recovery.json") }
    init(directory:URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("revoice-draft",isDirectory:true)
    }
    struct Loaded { let draft:RevoiceDraft?; let warning:String?; let existed:Bool }
    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath:file.path) else {
            if let data = read(backup),let draft = decode(data) {
                return .init(draft:draft,warning:"已从草稿恢复副本读取，请检查内容。",existed:true)
            }
            if FileManager.default.fileExists(atPath:backup.path) {
                return .init(draft:read(backup).flatMap(recoverText),warning:"草稿恢复副本损坏，已保留能读取的文字；请检查内容。",existed:true)
            }
            return .init(draft:nil,warning:nil,existed:false)
        }
        if let data = read(file),let draft = decode(data) {
            return .init(draft:draft,warning:draft.version > 1 ? "草稿版本较新，已读取可识别的编辑内容。" : nil,existed:true)
        }
        if let data = read(file),let draft = recoverText(data) {
            return .init(draft:draft,warning:"草稿文件损坏，已保留能读取的文字；请检查声线与识别片段。",existed:true)
        }
        if let data = read(backup),let draft = decode(data) {
            return .init(draft:draft,warning:"草稿文件损坏，已恢复最近的副本；请检查内容。",existed:true)
        }
        return .init(draft:nil,warning:"草稿文件无法读取，未自动提交任何内容。",existed:true)
    }
    private func read(_ url:URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber,
              size.intValue <= 128*1024 else { return nil }
        return try? Data(contentsOf:url)
    }
    private func recoverText(_ data:Data) -> RevoiceDraft? {
        if data.count <= 128*1024,
           let source = String(data:data,encoding:.utf8),
           let expression = try? NSRegularExpression(pattern:#""text"\s*:\s*("(?:\\.|[^"\\])*")"#),
           let match = expression.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)),
           let range = Range(match.range(at:1),in:source),
           let text = try? JSONDecoder().decode(String.self,from:Data(source[range].utf8)) {
            var draft = RevoiceDraft(); draft.text = text
            return draft
        }
        return nil
    }
    private func decode(_ data:Data) -> RevoiceDraft? {
        guard data.count <= 128*1024 else { return nil }
        return try? JSONDecoder().decode(RevoiceDraft.self,from:data)
    }
    /// All callers serialize on MainActor; both files use atomic replacement.
    func save(_ draft:RevoiceDraft) throws {
        let data = try JSONEncoder().encode(draft)
        guard data.count <= 128*1024 else { throw LabError.message("草稿过大，请缩短文字和指令后重试保存") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var target = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        try data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try data.write(to:backup,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}
