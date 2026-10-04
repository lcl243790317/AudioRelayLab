import Foundation
import CryptoKit

enum AudioNaming {
    /// The same readable name is used in the library, Files and the share sheet.
    static func generated(kind: String, label: String? = nil, fileExtension suffix: String,
                          date: Date = Date(), id: UUID = UUID(), maximumLabelCharacters: Int = 36) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let illegal = CharacterSet(charactersIn: "/\\:\n\r<>\"|?*").union(.controlCharacters)
        var safeLabel = String((label ?? "").components(separatedBy:illegal).joined(separator:"-")
            .trimmingCharacters(in:.whitespacesAndNewlines).prefix(maximumLabelCharacters))
        let tail = "_\(formatter.string(from:date))_\(id.uuidString.prefix(8)).\(suffix)"
        while ("\(kind)_\(safeLabel)"+tail).utf8.count > 180, !safeLabel.isEmpty { safeLabel.removeLast() }
        let tag = safeLabel.isEmpty ? "" : "_\(safeLabel)"
        return "\(kind)\(tag)"+tail
    }
    static func revoiceLabel(voiceName:String, speaker:String?, instruction:String?, fixedReferenceID:String? = nil) -> String {
        func bounded(_ value:String,bytes:Int) -> String {
            var result = value
            while result.utf8.count > bytes { result.removeLast() }
            return result
        }
        var parts = [bounded(voiceName,bytes:36)]
        if let speaker, !speaker.isEmpty, !voiceName.contains(speaker) { parts.append(bounded(speaker,bytes:24)) }
        if speaker == nil || speaker?.isEmpty == true {
            parts.append(fixedReferenceID.map { "参考-\(bounded($0,bytes:20))" } ?? "固定参考")
        }
        let instruction = instruction ?? ""
        if instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { parts.append("自然表达") }
        else {
            var excerpt = String(instruction.prefix(24))
            let hash = SHA256.hash(data:Data(instruction.utf8)).map { String(format:"%02x",$0) }.joined().prefix(8).description
            let identity = parts.joined(separator:"_")
            while (identity+"_"+excerpt+"_"+hash).utf8.count > 130, !excerpt.isEmpty { excerpt.removeLast() }
            parts.append(excerpt)
            if excerpt != instruction { parts.append(hash) }
        }
        return parts.joined(separator:"_")
    }
    static func revoice(kind:String = "配音",voiceName:String,speaker:String?,instruction:String?,
                        fixedReferenceID:String? = nil,date:Date = Date(),id:UUID = UUID()) -> String {
        generated(kind:kind,label:revoiceLabel(voiceName:voiceName,speaker:speaker,instruction:instruction,fixedReferenceID:fixedReferenceID),
                  fileExtension:"wav",date:date,id:id,maximumLabelCharacters:180)
    }
}

extension AudioAsset {
    var sourceTitle: String {
        switch source {
        case .bundled: return "内置测试音"
        case .imported: return "导入音频"
        case .aiConverted: return "AI 成品"
        case .mixedRecording: return "混合成品"
        case .voiceLabRecording: return ["AI 原声","重新配音原声"].contains(presetName ?? "") ? "原声录音" : "旧手机变声"
        }
    }
    /// Old recordings keep their stored path and history identity, but have a distinct label.
    var libraryName: String {
        guard source != .bundled, source != .imported,
              !fileName.contains("_" + String(id.uuidString.prefix(8))) else { return fileName }
        return "\(sourceTitle) · \(fileName) · \(id.uuidString.prefix(8))"
    }
}
