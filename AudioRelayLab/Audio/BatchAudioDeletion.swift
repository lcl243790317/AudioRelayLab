import Foundation

/// The confirmation sheet and deletion action share the same immutable selection.
struct AudioDeletionRequest: Identifiable {
    struct Item: Identifiable {
        let id: UUID
        let name: String
    }
    let id = UUID()
    let items: [Item]
    var audioIDs: Set<UUID> { Set(items.map(\.id)) }

    init?(assets: [AudioAsset]) {
        let deletable = assets.filter { $0.source != .bundled }
        guard !deletable.isEmpty else { return nil }
        items = deletable.map { Item(id:$0.id,name:$0.libraryName) }
    }
}

struct BatchAudioDeleteResult {
    var deletedIDs:Set<UUID> = []
    var failures:[UUID:String] = [:]
    var cleanupWarnings:[String] = []
    var summary:String {
        "已删除 \(deletedIDs.count) 项" + (failures.isEmpty ? "" : "，\(failures.count) 项未删除，可重试")
            + (cleanupWarnings.isEmpty ? "" : "；部分附属记录清理未完成，请查看诊断")
    }
}
