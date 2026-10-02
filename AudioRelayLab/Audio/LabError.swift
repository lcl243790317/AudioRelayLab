import Foundation

enum LabError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

func diagnosticError(_ error: Error) -> String {
    let value = error as NSError
    return "错误域=\(value.domain)，错误码=\(value.code)，详情=\(value.localizedDescription)，附加信息=\(value.userInfo)"
}
