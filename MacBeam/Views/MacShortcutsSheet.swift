import SwiftUI

/// Full list of Mac keys and shortcuts. On iPhone the HUD and bottom bar cannot fit
/// every option, so this sheet shows them all in sections.
struct MacShortcutsSheet: View {
    let client: RFBClient
    @Binding var stickyModifiers: Set<UInt32>
    let onToast: (String) -> Void
    var onSendClipboard: (() -> Void)? = nil
    var onCopyMacClipboard: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        var id: String { title + keys }
        let title: String
        let keys: String
        let systemImage: String
        let keySym: UInt32
        let modifiers: [UInt32]
    }

    private static let cmd = RFBKeySym.macCommand
    private static let opt = RFBKeySym.macOption
    private static let ctrl = RFBKeySym.macControl
    private static let shift = RFBKeySym.macShift

    private static func ch(_ c: Character) -> UInt32 {
        RFBKeySym.from(character: c) ?? UInt32(c.asciiValue ?? 0)
    }

    private let sections: [(String, [Shortcut])] = [
        ("System", [
            Shortcut(title: "Spotlight", keys: "⌘ Space", systemImage: "magnifyingglass", keySym: RFBKeySym.space, modifiers: [cmd]),
            Shortcut(title: "App Switcher", keys: "⌘ Tab", systemImage: "rectangle.stack", keySym: RFBKeySym.tab, modifiers: [cmd]),
            Shortcut(title: "Mission Control", keys: "⌃ ↑", systemImage: "macwindow.on.rectangle", keySym: RFBKeySym.upArrow, modifiers: [ctrl]),
            Shortcut(title: "App Windows", keys: "⌃ ↓", systemImage: "rectangle.grid.2x2", keySym: RFBKeySym.downArrow, modifiers: [ctrl]),
            Shortcut(title: "Previous Space", keys: "⌃ ←", systemImage: "arrow.left.square", keySym: RFBKeySym.leftArrow, modifiers: [ctrl]),
            Shortcut(title: "Next Space", keys: "⌃ →", systemImage: "arrow.right.square", keySym: RFBKeySym.rightArrow, modifiers: [ctrl]),
            Shortcut(title: "Force Quit", keys: "⌘⌥ Esc", systemImage: "exclamationmark.triangle", keySym: RFBKeySym.escape, modifiers: [cmd, opt]),
            Shortcut(title: "Lock Screen", keys: "⌃⌘ Q", systemImage: "lock", keySym: ch("q"), modifiers: [ctrl, cmd]),
            Shortcut(title: "Screenshot", keys: "⇧⌘ 3", systemImage: "camera", keySym: ch("3"), modifiers: [shift, cmd]),
            Shortcut(title: "Screenshot Area", keys: "⇧⌘ 4", systemImage: "camera.viewfinder", keySym: ch("4"), modifiers: [shift, cmd]),
            Shortcut(title: "Screenshot Tools", keys: "⇧⌘ 5", systemImage: "rectangle.dashed", keySym: ch("5"), modifiers: [shift, cmd]),
        ]),
        ("Editing", [
            Shortcut(title: "Copy", keys: "⌘ C", systemImage: "doc.on.doc", keySym: ch("c"), modifiers: [cmd]),
            Shortcut(title: "Paste", keys: "⌘ V", systemImage: "doc.on.clipboard", keySym: ch("v"), modifiers: [cmd]),
            Shortcut(title: "Cut", keys: "⌘ X", systemImage: "scissors", keySym: ch("x"), modifiers: [cmd]),
            Shortcut(title: "Undo", keys: "⌘ Z", systemImage: "arrow.uturn.backward", keySym: ch("z"), modifiers: [cmd]),
            Shortcut(title: "Redo", keys: "⇧⌘ Z", systemImage: "arrow.uturn.forward", keySym: ch("z"), modifiers: [shift, cmd]),
            Shortcut(title: "Select All", keys: "⌘ A", systemImage: "selection.pin.in.out", keySym: ch("a"), modifiers: [cmd]),
            Shortcut(title: "Find", keys: "⌘ F", systemImage: "text.magnifyingglass", keySym: ch("f"), modifiers: [cmd]),
            Shortcut(title: "Save", keys: "⌘ S", systemImage: "square.and.arrow.down", keySym: ch("s"), modifiers: [cmd]),
        ]),
        ("Windows & Apps", [
            Shortcut(title: "New", keys: "⌘ N", systemImage: "plus.rectangle", keySym: ch("n"), modifiers: [cmd]),
            Shortcut(title: "New Tab", keys: "⌘ T", systemImage: "plus.square.on.square", keySym: ch("t"), modifiers: [cmd]),
            Shortcut(title: "Close Window", keys: "⌘ W", systemImage: "xmark.rectangle", keySym: ch("w"), modifiers: [cmd]),
            Shortcut(title: "Next Window", keys: "⌘ `", systemImage: "rectangle.2.swap", keySym: ch("`"), modifiers: [cmd]),
            Shortcut(title: "Minimise", keys: "⌘ M", systemImage: "minus.rectangle", keySym: ch("m"), modifiers: [cmd]),
            Shortcut(title: "Hide App", keys: "⌘ H", systemImage: "eye.slash", keySym: ch("h"), modifiers: [cmd]),
            Shortcut(title: "Quit App", keys: "⌘ Q", systemImage: "power", keySym: ch("q"), modifiers: [cmd]),
            Shortcut(title: "Settings", keys: "⌘ ,", systemImage: "gearshape", keySym: ch(","), modifiers: [cmd]),
            Shortcut(title: "Reload", keys: "⌘ R", systemImage: "arrow.clockwise", keySym: ch("r"), modifiers: [cmd]),
            Shortcut(title: "Back", keys: "⌘ [", systemImage: "chevron.backward", keySym: ch("["), modifiers: [cmd]),
            Shortcut(title: "Forward", keys: "⌘ ]", systemImage: "chevron.forward", keySym: ch("]"), modifiers: [cmd]),
        ]),
    ]

    private let navigationKeys: [(String, String, UInt32)] = [
        ("Page Up", "Page Up", RFBKeySym.pageUp),
        ("Page Down", "Page Down", RFBKeySym.pageDown),
        ("Home", "Home", RFBKeySym.home),
        ("End", "End", RFBKeySym.end),
        ("←", "Left Arrow", RFBKeySym.leftArrow),
        ("↑", "Up Arrow", RFBKeySym.upArrow),
        ("↓", "Down Arrow", RFBKeySym.downArrow),
        ("→", "Right Arrow", RFBKeySym.rightArrow),
    ]

    private let basicKeys: [(String, String, UInt32)] = [
        ("Esc", "Escape", RFBKeySym.escape),
        ("Tab", "Tab", RFBKeySym.tab),
        ("Space", "Space", RFBKeySym.space),
        ("⏎", "Return", RFBKeySym.returnKey),
        ("⌫", "Delete", RFBKeySym.backSpace),
        ("⌦", "Forward Delete", RFBKeySym.delete),
    ]

    private let functionKeys: [(String, String, UInt32)] = (1...12).map { n in
        ("F\(n)", "F\(n)", RFBKeySym.f1 + UInt32(n - 1))
    }

    private let modifierKeys: [(String, String, UInt32)] = [
        ("⌘", "Command", RFBKeySym.macCommand),
        ("⌥", "Option", RFBKeySym.macOption),
        ("⌃", "Control", RFBKeySym.macControl),
        ("⇧", "Shift", RFBKeySym.macShift),
    ]

    private let keyColumns = [GridItem(.adaptive(minimum: 64), spacing: 8)]

    var body: some View {
        NavigationStack {
            List {
                if onSendClipboard != nil || onCopyMacClipboard != nil {
                    Section("Clipboard") {
                        if let onSendClipboard {
                            Button {
                                onSendClipboard()
                                dismiss()
                            } label: {
                                Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard")
                            }
                        }
                        if let onCopyMacClipboard {
                            Button {
                                onCopyMacClipboard()
                                dismiss()
                            } label: {
                                Label("Copy Mac Clipboard", systemImage: "clipboard")
                            }
                        }
                    }
                }

                Section {
                    keyGrid(modifierKeys, isModifier: true)
                } header: {
                    Text("Modifiers")
                } footer: {
                    Text("Tap a modifier, then a key below (or type on the keyboard) to send a combination.")
                }

                Section("Scroll & Navigate") {
                    keyGrid(navigationKeys, isModifier: false)
                }

                Section("Keys") {
                    keyGrid(basicKeys, isModifier: false)
                }

                Section("Function Keys") {
                    keyGrid(functionKeys, isModifier: false)
                }

                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { shortcut in
                            Button {
                                client.sendKeyTap(keySym: shortcut.keySym, modifiers: shortcut.modifiers)
                                onToast("Sent \(shortcut.title) (\(shortcut.keys))")
                                dismiss()
                            } label: {
                                HStack {
                                    Label(shortcut.title, systemImage: shortcut.systemImage)
                                    Spacer()
                                    Text(shortcut.keys)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityHint("Sends \(shortcut.keys) to the Mac")
                        }
                    }
                }
            }
            .navigationTitle("Mac Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func keyGrid(_ keys: [(String, String, UInt32)], isModifier: Bool) -> some View {
        LazyVGrid(columns: keyColumns, spacing: 8) {
            ForEach(keys, id: \.1) { key in
                let isActive = isModifier && stickyModifiers.contains(key.2)
                Button {
                    if isModifier {
                        if isActive {
                            stickyModifiers.remove(key.2)
                        } else {
                            stickyModifiers.insert(key.2)
                        }
                    } else {
                        client.sendKeyTap(keySym: key.2, modifiers: Array(stickyModifiers))
                        stickyModifiers.removeAll()
                    }
                } label: {
                    Text(key.0)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isActive ? Color.accentColor : Color(.tertiarySystemFill))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.1)
                .accessibilityValue(isModifier ? (isActive ? "Active" : "Inactive") : "")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
