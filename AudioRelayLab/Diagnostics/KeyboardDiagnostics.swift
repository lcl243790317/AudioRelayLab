import UIKit
import os

/// No user text, key labels, selection contents or connection data are recorded.
@MainActor enum KeyboardDiagnostics {
    static var experiment:String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KEYBOARD_EXPERIMENT"] ?? "fixed"
        #else
        return "fixed"
        #endif
    }
    static var legacyState:Bool { ["legacy","no-outside","no-disappear"].contains(experiment) }
    static func record(_ event:String,_ detail:String = "") {
        #if DEBUG
        guard enabled else { return }
        observer.start()
        sequence += 1
        let line = "\(session) \(sequence) \(String(format:"%.6f",ProcessInfo.processInfo.systemUptime)) \(experiment) \(event) \(detail)\n"
        log.debug("\(line,privacy:.public)")
        if let data = line.data(using:.utf8) { try? handle?.write(contentsOf:data) }
        #endif
    }
    static func editorID(_ view:UIView?) -> String {
        guard let view else { return "none" }
        let id = view.accessibilityIdentifier ?? ""
        let label = ["revoice.text","revoice.instruction","revoice.instruction.preview"].contains(id) ? id : "editor"
        return "\(label):\(ObjectIdentifier(view))"
    }
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["KEYBOARD_DIAGNOSTICS"] == "1"
    private static let session = UUID().uuidString
    private static var sequence = 0
    private static let log = Logger(subsystem:"com.audiorelaylab.AudioRelayLab",category:"keyboard")
    private static let observer = Observer()
    private static let handle:FileHandle? = {
        guard enabled else { return nil }
        let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("KeyboardDiagnostics",isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent(session+".log")
        guard FileManager.default.createFile(atPath:file.path,contents:nil) else { return nil }
        return try? FileHandle(forWritingTo:file)
    }()
    static func legacyDismiss() {
        record("legacy.dismiss")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.endEditing(true) }
        }
    }
    @MainActor private final class Observer:NSObject {
        private var started = false
        func start() {
            guard !started else { return }; started = true
            for name in [UITextView.textDidBeginEditingNotification,UITextView.textDidEndEditingNotification,
                         UITextField.textDidBeginEditingNotification,UITextField.textDidEndEditingNotification,
                         UITextView.textDidChangeNotification,UITextField.textDidChangeNotification,
                         UIResponder.keyboardWillShowNotification,UIResponder.keyboardDidShowNotification,
                         UIResponder.keyboardWillHideNotification,UIResponder.keyboardDidHideNotification] {
                NotificationCenter.default.addObserver(self,selector:#selector(received),name:name,object:nil)
            }
        }
        @objc private func received(_ notification:Notification) {
            let view = notification.object as? UIView
            record(notification.name.rawValue,"\(editorID(view)) responder=\(view?.isFirstResponder == true)")
        }
    }
    #endif
}
