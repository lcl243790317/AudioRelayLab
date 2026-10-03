import SwiftUI
import UIKit

enum PaperTheme {
    static let background = Color(red:0.91,green:0.91,blue:0.89)
    static let paper = Color(red:0.975,green:0.971,blue:0.955)
    static let ink = Color(red:0.23,green:0.24,blue:0.23)
    static let secondary = Color(red:0.42,green:0.43,blue:0.41)
    static let accent = Color(red:0.20,green:0.42,blue:0.49)
    static let line = Color.black.opacity(0.10)
    static let body = Font.system(.body,design:.serif)
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
        let descriptor = UIFont.systemFont(ofSize:17).fontDescriptor.withDesign(.serif)
        let font = descriptor.map { UIFont(descriptor:$0,size:17) } ?? UIFont.systemFont(ofSize:17)
        navigation.titleTextAttributes = [.font:font,.foregroundColor:UIColor(ink)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
}

struct PaperTexture: View {
    var card = false
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(card ? PaperTheme.paper : PaperTheme.background))
            // Stable vector grain; no bitmap, randomness, or per-frame animation.
            for y in stride(from:0,to:Int(size.height),by:9) {
                for x in stride(from:0,to:Int(size.width),by:11) {
                    let shift = (x*17+y*13)%7
                    let rect = CGRect(x:CGFloat(x+shift),y:CGFloat(y+(shift%3)),width:0.7,height:0.7)
                    context.fill(Path(ellipseIn:rect),with:.color(.black.opacity(0.028)))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct PaperScreen<Content:View>: View {
    let content: Content
    init(@ViewBuilder content:()->Content) { self.content=content() }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) { content }
                .padding(20).frame(maxWidth:620).frame(maxWidth:.infinity)
        }.background(PaperTexture().ignoresSafeArea())
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
                Text(title).font(.system(.headline,design:.serif)).tracking(1)
                Rectangle().fill(PaperTheme.line).frame(height:1).accessibilityHidden(true)
            }
            content
        }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
            .background(PaperTexture(card:true))
            .clipShape(RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).stroke(.white.opacity(0.8),lineWidth:1))
            .shadow(color:.black.opacity(0.09),radius:6,x:0,y:4)
    }
}

struct PaperHeader: View {
    let title:String
    let subtitle:String
    var symbol = "waveform"
    var body: some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:10) {
                Text(title).font(.system(.largeTitle,design:.serif)).tracking(2)
                Text(subtitle).font(.subheadline).foregroundStyle(PaperTheme.secondary)
            }
            Spacer(minLength:4)
            Image(systemName:symbol).font(.title3)
                .frame(width:56,height:56)
                .overlay(Circle().stroke(PaperTheme.secondary.opacity(0.55),lineWidth:1))
                .overlay(Circle().inset(by:4).stroke(PaperTheme.secondary.opacity(0.35),lineWidth:1))
                .rotationEffect(.degrees(-12)).foregroundStyle(PaperTheme.secondary)
                .accessibilityHidden(true)
        }.padding(.vertical,8)
    }
}

struct PaperButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(.callout,design:.serif))
            .frame(maxWidth:.infinity,minHeight:44)
            .foregroundStyle(primary ? PaperTheme.paper : PaperTheme.ink)
            .background(primary ? PaperTheme.secondary : PaperTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius:4))
            .overlay(RoundedRectangle(cornerRadius:4).stroke(primary ? Color.black.opacity(0.15) : PaperTheme.line,lineWidth:1))
            .shadow(color:.black.opacity(0.10),radius:configuration.isPressed ? 1 : 3,x:0,y:configuration.isPressed ? 1 : 2)
            .opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed ? 0.985 : 1)
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
    }
}
