import SwiftUI

@MainActor final class AppNavigation:ObservableObject {
    enum Tab:Int,Hashable { case playback, workshop, library }
    @Published var tab:Tab = ProcessInfo.processInfo.arguments.contains("voice-snapshot") || ProcessInfo.processInfo.arguments.contains("voice-custom-snapshot") || ProcessInfo.processInfo.arguments.contains("mix-snapshot") ? .workshop : .playback
    @Published private(set) var playbackNotice:String?
    private var previewPage:(owner:UUID,tab:Tab)?
    func previewPageAppeared(owner:UUID,tab:Tab) {
        if self.tab == tab { previewPage = (owner,tab) }
    }
    func previewPageDisappeared(owner:UUID) {
        if previewPage?.owner == owner { previewPage = nil }
    }
    /// Shared navigation toolbars use the visible page's owner, including pushed pages.
    func stopActivePagePreview(_ preview:PreviewPlaybackController) {
        guard let previewPage,previewPage.tab == tab else { return }
        preview.stop(owner:previewPage.owner)
    }
    func clearPlaybackNotice() { playbackNotice = nil }
    @discardableResult func useForPlayback(_ asset:AudioAsset,coordinator:ExperimentCoordinator) -> Bool {
        guard coordinator.selectLocal(asset) else { return false }
        playbackNotice = "已选择“\(asset.libraryName)”；设置延迟后手动开始播放。"
        tab = .playback
        return true
    }
}

struct ApplicationTabs:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var navigation:AppNavigation
    var body:some View {
        TabView(selection:$navigation.tab) {
            MainView(coordinator:coordinator).tabItem { Label("播放",systemImage:"music.note") }.tag(AppNavigation.Tab.playback)
            VoiceLabView(coordinator:coordinator).tabItem { Label("工坊",systemImage:"mic") }.tag(AppNavigation.Tab.workshop)
            LibraryHubView(coordinator:coordinator).tabItem { Label("音频库",systemImage:"folder") }.tag(AppNavigation.Tab.library)
        }
    }
}
