import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The system browser dims unsupported types; selected audio is still validated by decoding.
@MainActor struct AudioDocumentPicker: UIViewControllerRepresentable {
    static let supportedExtensions = ["wav", "mp3", "m4a", "aac", "aiff", "aifc", "caf", "flac"]
    static let supportedTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    let onSelection: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Delegate { Delegate(onSelection: onSelection, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = Self.makePicker(delegate: context.coordinator)
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    static func makePicker(delegate: UIDocumentPickerDelegate) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        // Initialize the embedded browser before applying its display options.
        picker.loadViewIfNeeded()
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = delegate
        return picker
    }
    @MainActor final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (URL) -> Void
        private let onCancel: () -> Void
        private var delivered = false
        init(onSelection: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !delivered else { return }; delivered = true
            if let url = urls.first { onSelection(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !delivered else { return }; delivered = true; onCancel()
        }
    }
}
