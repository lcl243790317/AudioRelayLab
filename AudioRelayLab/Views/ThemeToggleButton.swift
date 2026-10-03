import SwiftUI

struct ThemeToggleButton: View {
    @AppStorage("appearance.nightMode") private var nightMode = false
    var body: some View {
        Button {
            nightMode.toggle()
        } label: {
            Image(systemName:nightMode ? "sun.max.fill" : "moon.fill")
        }.buttonStyle(PaperButtonStyle(compact:true))
            .accessibilityLabel(nightMode ? "切换到日间主题" : "切换到夜间主题")
            .accessibilityValue(nightMode ? "当前为夜间主题" : "当前为日间主题")
    }
}
