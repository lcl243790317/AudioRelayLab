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
    @State private var snapshot: SelectionSnapshot<Value>?
    @Environment(\.keyboardDismissAction) private var clearFocus
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Button {
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
    static func perform() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.endEditing(true) }
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
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(.immediately)
            .background(OutsideKeyboardDismiss(clearFocus:clearFocus).frame(width:0,height:0))
            .onDisappear { clearFocus?(); KeyboardDismiss.perform() }
            .environment(\.keyboardDismissAction,{ clearFocus?(); KeyboardDismiss.perform() })
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { clearFocus?(); KeyboardDismiss.perform() }
                    .buttonStyle(PaperButtonStyle(compact:true)).accessibilityIdentifier("keyboard.done")
            } }
    }
}

private struct OutsideKeyboardDismiss:UIViewRepresentable {
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
        @objc private func dismissKeyboard() { clearFocus?(); KeyboardDismiss.perform() }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
            guard let window else { return false }
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
            return !hitsEditor(window)
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool { true }
    }
}

extension View {
    func keyboardDone(onDismiss:(()->Void)? = nil) -> some View { modifier(KeyboardDone(clearFocus:onDismiss)) }
}
