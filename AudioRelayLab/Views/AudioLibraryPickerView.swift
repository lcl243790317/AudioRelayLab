import SwiftUI

struct AudioLibraryPickerView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    let onSelect: (AudioAsset) -> Void
    @State private var choices:[AudioAsset]
    @Environment(\.dismiss) private var dismiss
    init(coordinator:ExperimentCoordinator,onSelect:@escaping (AudioAsset)->Void) {
        self.coordinator = coordinator; self.onSelect = onSelect
        _choices = State(initialValue:coordinator.library.filter { $0.source != .bundled })
    }
    var body: some View {
        List {
            ForEach(choices) { asset in
                Button {
                    guard !coordinator.controlsLocked, !coordinator.aiVoice.connecting else { return }
                    onSelect(asset)
                } label: {
                    VStack(alignment:.leading,spacing:6) {
                        Text(asset.libraryName).foregroundStyle(PaperTheme.ink)
                        PaperCaption("\(asset.sourceTitle) · \(AudioPlaybackSettings.time(asset.duration))")
                    }
                }.buttonStyle(.plain).disabled(coordinator.controlsLocked || coordinator.aiVoice.connecting)
            }
        }.paperList()
            .navigationTitle("选择一段人声")
            .toolbar { Button("取消") { dismiss() } }
            .transaction { $0.animation = nil }
    }
}
