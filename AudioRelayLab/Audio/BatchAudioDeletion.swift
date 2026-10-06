import Foundation

struct BatchAudioDeleteResult {
    var deletedIDs:Set<UUID> = []
    var failures:[UUID:String] = [:]
    var cleanupWarnings:[String] = []
    var summary:String {
        "已删除 \(deletedIDs.count) 项" + (failures.isEmpty ? "" : "，\(failures.count) 项未删除，可重试")
            + (cleanupWarnings.isEmpty ? "" : "；部分附属记录清理未完成，请查看诊断")
    }
}
