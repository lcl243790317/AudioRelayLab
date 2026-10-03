import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Providers do not always report a usable audio UTI. Accept items, validate PCM after selection.
@MainActor struct AudioDocumentPicker: UIViewControllerRepresentable {
    let onSelection: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Delegate { Delegate(onSelection: onSelection, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = Self.makePicker(delegate: context.coordinator)
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    static func makePicker(delegate: UIDocumentPickerDelegate) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
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
