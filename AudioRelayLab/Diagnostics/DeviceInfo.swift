import UIKit
import Darwin

struct DeviceInfo: Codable {
    let model: String
    let modelIdentifier: String
    let systemVersion: String
    let appVersion: String
    let build: String
    enum CodingKeys: String, CodingKey { case model, modelIdentifier, systemVersion, appVersion, build }

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

extension DeviceInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? "未知"
        modelIdentifier = (try? c.decode(String.self, forKey: .modelIdentifier)) ?? "未知"
        systemVersion = (try? c.decode(String.self, forKey: .systemVersion)) ?? "未知"
        appVersion = (try? c.decode(String.self, forKey: .appVersion)) ?? "未知"
        build = (try? c.decode(String.self, forKey: .build)) ?? "未知"
    }
}
