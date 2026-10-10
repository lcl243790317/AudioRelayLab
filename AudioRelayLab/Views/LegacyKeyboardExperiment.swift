#if DEBUG
import SwiftUI
import UIKit

// Exact 1.6.7 gesture/lifecycle retained only for controlled DEBUG comparisons.
struct LegacyKeyboardDone: ViewModifier {
    let clearFocus:(()->Void)?
    let dismissOnScroll:Bool
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(dismissOnScroll ? .immediately : .never)
            .background { if KeyboardDiagnostics.experiment != "no-outside" { LegacyOutsideKeyboardDismiss(clearFocus:clearFocus).frame(width:0,height:0) } }
            .onDisappear { KeyboardDiagnostics.record("legacy.disappear"); if KeyboardDiagnostics.experiment != "no-disappear" { clearFocus?(); KeyboardDiagnostics.legacyDismiss() } }
            .environment(\.keyboardDismissAction,{ clearFocus?(); KeyboardDiagnostics.legacyDismiss() })
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { clearFocus?(); KeyboardDiagnostics.legacyDismiss() }
                    .buttonStyle(PaperButtonStyle(compact:true)).accessibilityIdentifier("keyboard.done")
            } }
    }
}

private struct LegacyOutsideKeyboardDismiss:UIViewRepresentable {
    let clearFocus:(()->Void)?
    func makeCoordinator() -> Coordinator { Coordinator(clearFocus:clearFocus) }
    func makeUIView(context:Context) -> Host {
        let view = Host(); view.isUserInteractionEnabled = false
        view.changedWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateUIView(_ view:Host,context:Context) { context.coordinator.clearFocus = clearFocus }
    static func dismantleUIView(_ view:Host,coordinator:Coordinator) { coordinator.attach(nil) }
    final class Host:UIView {
        var changedWindow:((UIWindow?)->Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); changedWindow?(window) }
    }
    @MainActor final class Coordinator:NSObject,UIGestureRecognizerDelegate {
        var clearFocus:(()->Void)?
        private weak var window:UIWindow?
        private lazy var tap:UITapGestureRecognizer = {
            let value = UITapGestureRecognizer(target:self,action:#selector(dismissKeyboard))
            value.cancelsTouchesInView = false; value.delaysTouchesBegan = false; value.delaysTouchesEnded = false
            value.delegate = self; return value
        }()
        init(clearFocus:(()->Void)?) { self.clearFocus = clearFocus }
        func attach(_ value:UIWindow?) {
            guard window !== value else { return }
            window?.removeGestureRecognizer(tap); window = value; value?.addGestureRecognizer(tap)
        }
        @objc private func dismissKeyboard() { KeyboardDiagnostics.record("legacy.gesture.dismiss"); clearFocus?(); KeyboardDiagnostics.legacyDismiss() }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
            KeyboardDiagnostics.record("legacy.touch"); guard let window else { return false }
            // Soft keys and input accessories are input, even when UIKit hosts
            // their touch views outside the text view's descendant hierarchy.
            guard touch.window === window else { KeyboardDiagnostics.record("legacy.touch.ignore","other-window"); return false }
            let keyboardFrame = window.keyboardLayoutGuide.layoutFrame
            if keyboardFrame.height > window.safeAreaInsets.bottom + 1,
               keyboardFrame.contains(touch.location(in:window)) { KeyboardDiagnostics.record("legacy.touch.ignore","keyboard-guide"); return false }
            if let touched = touch.view {
                func hitsInputAccessory(_ view:UIView) -> Bool {
                    if view.isFirstResponder,let accessory = view.inputAccessoryView,
                       touched === accessory || touched.isDescendant(of:accessory) { return true }
                    return view.subviews.contains(where:hitsInputAccessory)
                }
                if hitsInputAccessory(window) { KeyboardDiagnostics.record("legacy.touch.ignore","accessory"); return false }
            }
            var touched = touch.view
            var hitsChrome = false
            while let view = touched {
                if view is UITextField || view is UITextView { KeyboardDiagnostics.record("legacy.touch.ignore","input"); return false }
                if view is UINavigationBar || view is UITabBar || view is UIControl { hitsChrome = true }
                touched = view.superview
            }
            // Chrome/controls can cover an editor's offscreen accessibility frame.
            // Prefer the actual hit view, while preserving taps within an editor.
            if hitsChrome { KeyboardDiagnostics.record("legacy.touch.accept","chrome"); return true }
            // SwiftUI's touch view can be a hosting view rather than the native editor.
            // Exclude editor frames as well as their descendants to preserve focus/selection.
            func hitsEditor(_ view:UIView) -> Bool {
                guard !view.isHidden,view.alpha > 0.01 else { return false }
                if view.clipsToBounds,!view.bounds.contains(touch.location(in:view)) { return false }
                if view is UITextField || view is UITextView {
                    if view.bounds.contains(touch.location(in:view)) { return true }
                }
                return view.subviews.contains(where:hitsEditor)
            }
            let result = !hitsEditor(window); KeyboardDiagnostics.record("legacy.touch.decision",result ? "dismiss" : "editor-frame"); return result
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool { true }
    }
}

#endif
