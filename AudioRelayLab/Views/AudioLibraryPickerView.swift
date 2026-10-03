import SwiftUI

struct AudioLibraryPickerView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    let onSelect: (AudioAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(coordinator.library.filter { $0.source != .bundled }) { asset in
                Button {
                    guard !coordinator.controlsLocked, !coordinator.aiVoice.connecting else { return }
                    onSelect(asset)
                } label: {
                    VStack(alignment:.leading,spacing:6) {
                        Text(asset.libraryName).foregroundStyle(PaperTheme.ink)
                        PaperCaption("\(asset.sourceTitle) · \(AudioPlaybackSettings.time(asset.duration))")
                    }
                }.disabled(coordinator.controlsLocked || coordinator.aiVoice.connecting)
            }
        }.paperList()
            .navigationTitle("选择一段人声")
            .toolbar { Button("取消") { dismiss() } }
            .onAppear { coordinator.refreshLibrary() }
    }
}
