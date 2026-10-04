import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Providers can report a .json file as generic data. Validate the contents after
/// selection rather than making a valid configuration impossible to select.
@MainActor struct JSONDocumentPicker: UIViewControllerRepresentable {
    let onSelection: (URL) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> AudioDocumentPicker.Delegate {
        .init(onSelection: onSelection, onCancel: onCancel)
    }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        Self.makePicker(delegate: context.coordinator)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    static func makePicker(delegate: UIDocumentPickerDelegate) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.loadViewIfNeeded()
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = delegate
        return picker
    }
}

enum JSONImportFile {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let lease = AudioAccessLease(url)
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(LabError.invalidFormat)
        NSFileCoordinator().coordinate(readingItemAt: lease.url, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                guard data.count <= maximumBytes else { throw LabError.message("JSON 文件超过允许大小") }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
    /// Only remove a copy made by the picker, never the user's original document.
    static func removePickerCopy(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        guard resolved.hasPrefix(home),
              resolved.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/") || resolved.contains("/Documents/Inbox/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
