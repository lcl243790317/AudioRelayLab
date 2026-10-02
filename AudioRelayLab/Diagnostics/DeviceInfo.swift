import UIKit
import Darwin

struct DeviceInfo: Codable {
    let model: String
    let modelIdentifier: String
    let systemVersion: String
    let appVersion: String
    let build: String

    @MainActor static func current() -> DeviceInfo {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return DeviceInfo(
            model: UIDevice.current.model,
            modelIdentifier: identifier,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        )
    }
}
