import Foundation

enum AudioNaming {
    /// The same readable name is used in the library, Files and the share sheet.
    static func generated(kind: String, label: String? = nil, fileExtension suffix: String,
                          date: Date = Date(), id: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let safeLabel = (label ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r"))
            .joined(separator: "-").prefix(36)
        let tag = safeLabel.isEmpty ? "" : "_\(safeLabel)"
        return "\(kind)\(tag)_\(formatter.string(from: date))_\(id.uuidString.prefix(8)).\(suffix)"
    }
}

extension AudioAsset {
    var sourceTitle: String {
        switch source {
        case .bundled: return "内置测试音"
        case .imported: return "导入音频"
        case .aiConverted: return "AI 成品"
        case .mixedRecording: return "混合成品"
        case .voiceLabRecording: return presetName == "AI 原声" ? "原声录音" : "手机变声"
        }
    }
    /// Old recordings keep their stored path and history identity, but have a distinct label.
    var libraryName: String {
        guard source != .bundled, source != .imported,
              !fileName.contains("_" + String(id.uuidString.prefix(8))) else { return fileName }
        return "\(sourceTitle) · \(fileName) · \(id.uuidString.prefix(8))"
    }
}
