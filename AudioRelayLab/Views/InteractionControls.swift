import SwiftUI
import UIKit

struct SelectionChoice<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
}

struct SelectionSnapshot<Value: Hashable>: Identifiable {
    let id = UUID()
    let choices: [SelectionChoice<Value>]
    let selected: Value
}

/// Selection owns an immutable list for the lifetime of the sheet. Playback updates
/// must never replace its data or reset the scroll position.
struct StablePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [SelectionChoice<Value>]
    var onDismiss:(()->Void)? = nil
    var beforeOpen:(()->Void)? = nil
    @State private var snapshot: SelectionSnapshot<Value>?
    @Environment(\.keyboardDismissAction) private var clearFocus
    @Environment(\.stopPagePreview) private var stopPreview
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Button {
            beforeOpen?()
            stopPreview?()
            if let clearFocus { clearFocus() } else { KeyboardDismiss.perform() }
            snapshot = .init(choices: choices, selected: selection)
        } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment:.leading,spacing:8) {
                        Text(title).font(.subheadline)
                        HStack(alignment:.top,spacing:12) {
                            Text(choices.first { $0.id == selection }?.title ?? "请选择")
                                .foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                                .fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:0)
                            Image(systemName:"chevron.up.chevron.down").font(.caption)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                } else {
                    HStack {
                        Text(title)
                        Spacer()
                        Text(choices.first { $0.id == selection }?.title ?? "请选择")
                            .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PaperButtonStyle())
        .accessibilityIdentifier("select.\(title)")
        .sheet(item: $snapshot,onDismiss:onDismiss) { opened in
            NavigationStack {
                List(opened.choices) { choice in
                    Button {
                        selection = choice.id
                        snapshot = nil
                    } label: {
                        HStack {
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if choice.id == opened.selected {
                                Image(systemName: "checkmark").foregroundStyle(PaperTheme.accent)
                            }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(PaperButtonStyle()).accessibilityIdentifier("choice.\(choice.id)")
                }
                .paperList().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { snapshot = nil }.buttonStyle(PaperButtonStyle(compact:true))
                } }
            }
            .transaction { $0.animation = nil }
            .accessibilityIdentifier("choices.\(title)")
        }
    }
}

@MainActor enum KeyboardDismiss {
    static func perform(source:String = #function) {
        KeyboardDiagnostics.record("dismiss.explicit",source)
        // An explicit user action belongs to the foreground app window only.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            scene.windows.first(where:{ $0.isKeyWindow })?.endEditing(true)
        }
    }
}

private struct KeyboardDismissKey: EnvironmentKey { static let defaultValue:(()->Void)? = nil }
extension EnvironmentValues {
    var keyboardDismissAction:(()->Void)? {
        get { self[KeyboardDismissKey.self] }
        set { self[KeyboardDismissKey.self] = newValue }
    }
}

private struct KeyboardDone: ViewModifier {
    let clearFocus:(()->Void)?
    let dismissOnScroll:Bool
    @StateObject private var scope = KeyboardContentScope()
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(dismissOnScroll ? .immediately : .never)
            .background(OutsideKeyboardDismiss(scope:scope,clearFocus:clearFocus))
            .onDisappear { scope.pageDisappeared() }
            .environment(\.keyboardDismissAction,{ scope.dismiss(source:"presentation") })
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { scope.dismiss(source:"done") }
                    .buttonStyle(PaperButtonStyle(compact:true)).accessibilityIdentifier("keyboard.done")
            } }
    }
}

/// Touches outside the app content hierarchy never enter this recognizer. No keyboard
/// coordinates, private UIKit classes, re-focusing or cross-window endEditing are needed.
@MainActor final class KeyboardContentScope:NSObject,ObservableObject,UIGestureRecognizerDelegate {
    var clearFocus:(()->Void)?
    private weak var host:UIView?
    private weak var content:UIView?
    private weak var editor:UIView?
    private var taps:[UITapGestureRecognizer] = []
    func attach(_ marker:UIView) {
        host = marker
        guard marker.window != nil,let owner = Self.owner(of:marker) else { detach(); return }
        guard let root = owner.viewIfLoaded else { detach(); return }
        guard content !== root else { return }
        detach(); content = root
        var targets:[UIView] = [root]
        var controller:UIViewController? = owner
        while let value = controller {
            if let nav = value as? UINavigationController { targets.append(nav.navigationBar) }
            if let tab = value as? UITabBarController { targets.append(tab.tabBar) }
            controller = value.parent
        }
        for target in targets where !(target is UIWindow) && !taps.contains(where:{ $0.view === target }) {
            let tap = UITapGestureRecognizer(target:self,action:#selector(outsideTap))
            tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
            tap.delegate = self; target.addGestureRecognizer(tap); taps.append(tap)
        }
        KeyboardDiagnostics.record("scope.attach")
    }
    func detach() {
        for tap in taps { tap.view?.removeGestureRecognizer(tap) }
        taps = []; content = nil
    }
    static func owner(of marker:UIView) -> UIViewController? {
        var responder:UIResponder? = marker.next
        while let value = responder {
            if let controller = value as? UIViewController { return controller }
            responder = value.next
        }
        return nil
    }
    /// A UIControl wrapper must not take precedence over a native editor hit.
    static func editor(at point:CGPoint,in root:UIView) -> UIView? {
        guard !root.isHidden,root.alpha > 0.01 else { return nil }
        if root.clipsToBounds && !root.bounds.contains(point) { return nil }
        for child in root.subviews.reversed() {
            if let result = editor(at:child.convert(point,from:root),in:child) { return result }
        }
        return root is UITextInput && root.bounds.contains(point) ? root : nil
    }
    static func firstResponder(in root:UIView) -> UIView? {
        if root.isFirstResponder { return root }
        return root.subviews.lazy.compactMap { firstResponder(in:$0) }.first
    }
    private func insidePage(_ point:CGPoint,in root:UIView) -> Bool {
        guard let host,host.window != nil else { return false }
        return host.bounds.contains(host.convert(point,from:root))
    }
    func dismiss(source:String) {
        // A departing page never resigns an editor which another page just acquired.
        guard let editor,editor.isFirstResponder else { return }
        KeyboardDiagnostics.record("dismiss.scoped","\(source) \(KeyboardDiagnostics.editorID(editor))")
        clearFocus?(); editor.resignFirstResponder()
    }
    func pageDisappeared() {
        KeyboardDiagnostics.record("scope.disappear",KeyboardDiagnostics.editorID(editor))
        dismiss(source:"page-exit")
    }
    @objc private func outsideTap() { dismiss(source:"outside-content") }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
        guard let root = content,let target = gestureRecognizer.view,let touched = touch.view,
              touched === target || touched.isDescendant(of:target) else {
            KeyboardDiagnostics.record("scope.touch.ignore","outside-hierarchy"); return false
        }
        let point = touch.location(in:root)
        if target === root {
            guard insidePage(point,in:root) else { return false }
            var ancestor:UIView? = touched
            while let value = ancestor {
                if value is UITextInput { editor = value; KeyboardDiagnostics.record("scope.touch.ignore","input \(KeyboardDiagnostics.editorID(value))"); return false }
                ancestor = value.superview
            }
            if let hit = Self.editor(at:point,in:root) {
                editor = hit; KeyboardDiagnostics.record("scope.touch.ignore","editor-frame \(KeyboardDiagnostics.editorID(hit))"); return false
            }
        }
        // Only this scope's current editor can be dismissed, including chrome taps.
        let active = editor?.isFirstResponder == true
        KeyboardDiagnostics.record("scope.touch.decision",active ? "dismiss" : "ignore-no-owned-editor")
        return active
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool { true }
}

private struct OutsideKeyboardDismiss:UIViewRepresentable {
    let scope:KeyboardContentScope
    let clearFocus:(()->Void)?
    func makeCoordinator() -> KeyboardContentScope { scope }
    func makeUIView(context:Context) -> Host {
        let view = Host(); view.isUserInteractionEnabled = false
        view.changed = { [weak scope] host in scope?.attach(host) }
        scope.clearFocus = clearFocus
        return view
    }
    func updateUIView(_ view:Host,context:Context) { scope.clearFocus = clearFocus }
    static func dismantleUIView(_ view:Host,coordinator:KeyboardContentScope) { coordinator.detach(); view.changed = nil }
    final class Host:UIView {
        var changed:((UIView)->Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); changed?(self) }
        override func didMoveToSuperview() { super.didMoveToSuperview(); changed?(self) }
        override func layoutSubviews() { super.layoutSubviews(); changed?(self) }
    }
}

extension View {
    @ViewBuilder func keyboardDone(dismissOnScroll:Bool = true,onDismiss:(()->Void)? = nil) -> some View {
        #if DEBUG
        if KeyboardDiagnostics.experiment != "fixed" {
            modifier(LegacyKeyboardDone(clearFocus:onDismiss,dismissOnScroll:dismissOnScroll))
        } else {
            modifier(KeyboardDone(clearFocus:onDismiss,dismissOnScroll:dismissOnScroll))
        }
        #else
        modifier(KeyboardDone(clearFocus:onDismiss,dismissOnScroll:dismissOnScroll))
        #endif
    }
}
