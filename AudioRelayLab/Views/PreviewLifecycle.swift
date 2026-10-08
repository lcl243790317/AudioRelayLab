import SwiftUI

private struct PreviewStopKey:EnvironmentKey { static let defaultValue:(()->Void)? = nil }
extension EnvironmentValues {
    var stopPagePreview:(()->Void)? {
        get { self[PreviewStopKey.self] }
        set { self[PreviewStopKey.self] = newValue }
    }
}

private struct PreviewLifecycle:ViewModifier {
    let coordinator:ExperimentCoordinator
    @ObservedObject var navigation:AppNavigation
    let owner:UUID
    let tab:AppNavigation.Tab
    func body(content:Content) -> some View {
        content.environment(\.stopPagePreview,{ coordinator.preview.stop(owner:owner) })
            .onAppear { navigation.previewPageAppeared(owner:owner,tab:tab) }
            .onDisappear {
                coordinator.preview.stop(owner:owner)
                navigation.previewPageDisappeared(owner:owner)
            }
            .onChange(of:navigation.tab) { _,value in
                if value != tab {
                    coordinator.preview.stop(owner:owner)
                    navigation.previewPageDisappeared(owner:owner)
                }
            }
    }
}
extension View {
    func previewLifecycle(coordinator:ExperimentCoordinator,owner:UUID,tab:AppNavigation.Tab) -> some View {
        modifier(PreviewLifecycle(coordinator:coordinator,navigation:coordinator.navigation,owner:owner,tab:tab))
    }
}

struct PagePreviewStatus:View {
    @ObservedObject var preview:PreviewPlaybackController
    let owner:UUID
    var body:some View {
        if preview.hasContext(owner:owner) {
            if preview.state == .preparing { ProgressView("正在准备回听…") }
            if preview.state == .playing { PaperCaption("正在回听 · \(AudioPlaybackSettings.time(preview.currentTime))") }
            if let error = preview.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
        }
    }
}

struct PagePreviewStopButton:View {
    @ObservedObject var preview:PreviewPlaybackController
    let owner:UUID
    var body:some View {
        Button("停止回听") { preview.stop(owner:owner) }
            .disabled(!preview.isOwned(by:owner))
            .accessibilityValue(preview.isOwned(by:owner) ? (preview.state == .playing ? "正在回听" : "正在准备") : "未在回听")
    }
}
