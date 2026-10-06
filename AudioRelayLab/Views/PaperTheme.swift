import SwiftUI
import UIKit

enum PaperTheme {
    private static func adaptive(_ light:(Double,Double,Double),_ dark:(Double,Double,Double),alpha:Double=1) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red:rgb.0,green:rgb.1,blue:rgb.2,alpha:alpha)
        })
    }
    static let background = adaptive((247/255,248/255,244/255),(17/255,19/255,43/255))
    static let paper = adaptive((1,1,1),(28/255,31/255,63/255))
    static let ink = adaptive((38/255,50/255,56/255),(243/255,242/255,255/255))
    static let secondary = adaptive((101/255,113/255,123/255),(179/255,184/255,216/255))
    static let accent = adaptive((155/255,82/255,107/255),(120/255,90/255,230/255))
    static let mist = adaptive((216/255,235/255,238/255),(43/255,45/255,85/255))
    static let line = adaptive((0,0,0),(1,1,1),alpha:0.10)
    static let edge = adaptive((1,1,1),(0.32,0.34,0.35),alpha:0.8)
    static let body = Font.system(.body,design:.rounded)
    @MainActor static func configure() {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(paper)
        bar.stackedLayoutAppearance.normal.iconColor = UIColor(secondary)
        bar.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor:UIColor(secondary)]
        bar.stackedLayoutAppearance.selected.iconColor = UIColor(accent)
        bar.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor:UIColor(accent)]
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = UIColor(background)
        let descriptor = UIFont.systemFont(ofSize:17).fontDescriptor.withDesign(.rounded)
        let font = descriptor.map { UIFont(descriptor:$0,size:17) } ?? UIFont.systemFont(ofSize:17)
        navigation.titleTextAttributes = [.font:font,.foregroundColor:UIColor(ink)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
}

struct PaperTexture: View {
    var card = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (card ? PaperTheme.paper : PaperTheme.background).accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct PaperScreen<Content:View>: View {
    let content: Content
    init(@ViewBuilder content:()->Content) { self.content=content() }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) { content }
                .padding(20).frame(maxWidth:680).frame(maxWidth:.infinity)
        }.accessibilityIdentifier("screen.scroll").background(PaperTexture().ignoresSafeArea())
            .foregroundStyle(PaperTheme.ink).font(PaperTheme.body)
    }
}

struct PaperCard<Content:View>: View {
    let title:String?
    let content:Content
    init(_ title:String?=nil,@ViewBuilder content:()->Content) { self.title=title; self.content=content() }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            if let title {
                Text(title).font(.system(.headline,design:.rounded,weight:.semibold))
                Rectangle().fill(PaperTheme.line).frame(height:1).accessibilityHidden(true)
            }
            content
        }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
            .background(PaperTexture(card:true))
            .clipShape(RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).stroke(PaperTheme.line,lineWidth:1).allowsHitTesting(false))
            .shadow(color:.black.opacity(0.06),radius:12,x:0,y:5)
    }
}

struct PaperHeader: View {
    let title:String
    let subtitle:String
    var symbol = "waveform"
    var body: some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:10) {
                Text(title).font(.system(.largeTitle,design:.rounded,weight:.bold))
                Text(subtitle).font(.subheadline).foregroundStyle(PaperTheme.secondary)
            }
            Spacer(minLength:4)
            Image(systemName:symbol).font(.title3)
                .frame(width:56,height:56)
                .background(PaperTheme.mist,in:RoundedRectangle(cornerRadius:20))
                .foregroundStyle(PaperTheme.accent)
                .accessibilityHidden(true)
        }.padding(.vertical,8)
    }
}

struct PaperButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        PaperButtonSurface(configuration: configuration, primary: primary, compact: compact)
    }
}

private struct PaperButtonSurface: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var highlighted: Bool { enabled && configuration.isPressed }
    private var foreground: Color {
        if highlighted || primary { return .white }
        return configuration.role == .destructive ? .red : PaperTheme.ink
    }
    var body: some View {
        configuration.label.font(.system(.callout,design:.rounded,weight:primary ? .semibold : .regular))
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical,8)
            .frame(maxWidth:compact ? nil : .infinity,minHeight:44)
            .foregroundStyle(foreground)
            .background(highlighted || primary ? PaperTheme.accent : PaperTheme.mist.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(highlighted ? PaperTheme.accent : PaperTheme.line,lineWidth:1).allowsHitTesting(false))
            .shadow(color:.black.opacity(0.10),radius:highlighted && !reduceMotion ? 1 : 3,x:0,y:highlighted && !reduceMotion ? 1 : 2)
            .opacity(enabled ? 1 : 0.40)
            .scaleEffect(highlighted && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? .easeOut(duration:0.1) : (configuration.isPressed ? .easeOut(duration:0.08) : .spring(response:0.3,dampingFraction:0.6)),value:configuration.isPressed)
    }
}

struct PaperCaption: View {
    let text:String
    init(_ text:String) { self.text=text }
    var body: some View { Text(text).font(.caption).foregroundStyle(PaperTheme.secondary).lineSpacing(4) }
}

extension View {
    func paperList() -> some View {
        scrollContentBackground(.hidden).background(PaperTexture().ignoresSafeArea())
            .foregroundStyle(PaperTheme.ink).font(PaperTheme.body)
            .buttonStyle(PaperButtonStyle(compact:true))
    }
}
