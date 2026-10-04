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
    @State private var snapshot: SelectionSnapshot<Value>?
    @Environment(\.keyboardDismissAction) private var clearFocus
    var body: some View {
        Button {
            if let clearFocus { clearFocus() } else { KeyboardDismiss.perform() }
            snapshot = .init(choices: choices, selected: selection)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(choices.first { $0.id == selection }?.title ?? "请选择")
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("select.\(title)")
        .sheet(item: $snapshot) { opened in
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
                    }.buttonStyle(.plain).accessibilityIdentifier("choice.\(choice.id)")
                }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { snapshot = nil }.buttonStyle(.plain)
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
        content.scrollDismissesKeyboard(.interactively)
            .environment(\.keyboardDismissAction,{ clearFocus?(); KeyboardDismiss.perform() })
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { clearFocus?(); KeyboardDismiss.perform() }
                    .buttonStyle(.plain).accessibilityIdentifier("keyboard.done")
            } }
    }
}

extension View {
    func keyboardDone(onDismiss:(()->Void)? = nil) -> some View { modifier(KeyboardDone(clearFocus:onDismiss)) }
}
