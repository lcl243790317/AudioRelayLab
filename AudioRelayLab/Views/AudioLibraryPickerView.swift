import SwiftUI

struct AudioLibraryPickerView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    let title:String
    let onSelect: (AudioAsset) -> Void
    @State private var choices:[AudioAsset]
    @Environment(\.dismiss) private var dismiss
    init(coordinator:ExperimentCoordinator,title:String = "选择一段人声",includesBundled:Bool = false,onSelect:@escaping (AudioAsset)->Void) {
        self.coordinator = coordinator; self.title = title; self.onSelect = onSelect
        _choices = State(initialValue:coordinator.library.filter { includesBundled || $0.source != .bundled })
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
                }.buttonStyle(PaperButtonStyle()).disabled(coordinator.controlsLocked || coordinator.aiVoice.connecting)
            }
        }.paperList()
            .navigationTitle(title)
            .toolbar { Button("取消") { dismiss() } }
            .transaction { $0.animation = nil }
    }
}
