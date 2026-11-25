import SwiftUI
import UIKit

struct RemoteSessionView: View {
    let target: ActiveSessionTarget
    let library: ConnectionLibraryStore
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var client = RFBClient()
    @State private var demoServer: DemoMacVNCServer?
    @State private var demoStartupTask: Task<Void, Never>?
    @State private var canvasController = RemoteCanvasController()

    @State private var inputMode: PointerInputMode
    @State private var isScrollMode = false
    @AppStorage("pointerSize") private var pointerSize: PointerSize = .large
    @AppStorage("scrollSpeed") private var scrollSpeed: ScrollSpeed = .fast
    @State private var showShortcutsSheet = false
    @State private var isToolbarCollapsed = false
    /// Where the hidden-toolbar handle sits, as a fraction of the screen (persisted, draggable).
    @AppStorage("toolbarHandleX") private var toolbarHandleX: Double = 0.92
    @AppStorage("toolbarHandleY") private var toolbarHandleY: Double = 0.04
    @State private var toolbarHandleDrag: CGSize = .zero
    @State private var isSoftwareKeyboardVisible = false
    @State private var keyboardOverlapHeight: CGFloat = 0
    @State private var showSpecialKeysBar = false
    @State private var stickyModifiers: Set<UInt32> = []
    @State private var autoCopyRemoteClipboard = false

    @State private var showSessionInfo = false
    @State private var showCredentialsPrompt = false
    @State private var promptUsername: String
    @State private var promptPassword: String
    @State private var stagedCredentialsForPersistence: RFBCredentials?
    @State private var toastMessage: String?

    init(
        target: ActiveSessionTarget,
        library: ConnectionLibraryStore,
        onClose: @escaping () -> Void
    ) {
        self.target = target
        self.library = library
        self.onClose = onClose
        _inputMode = State(initialValue: target.preferredInputMode)
        _promptUsername = State(initialValue: target.initialCredentials.username)
        _promptPassword = State(initialValue: target.initialCredentials.password)
    }

    /// iPhone (and narrow iPad split view): fewer HUD buttons, shortcuts open as a sheet.
    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var showsModifierBar: Bool {
        client.state.isConnected && (showSpecialKeysBar || isSoftwareKeyboardVisible)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteDisplayView(
                client: client,
                inputMode: inputMode,
                isScrollMode: isScrollMode,
                pointerSize: pointerSize,
                scrollSpeed: scrollSpeed,
                controller: canvasController,
                activeModifiers: stickyModifiers,
                bottomAccessoryInset: showsModifierBar ? 68 : 0,
                onConsumeStickyModifiers: {
                    stickyModifiers.removeAll()
                },
                onSoftwareKeyboardChanged: { visible, overlap in
                    isSoftwareKeyboardVisible = visible
                    keyboardOverlapHeight = overlap
                    if visible {
                        showSpecialKeysBar = true
                    }
                }
            )
            .ignoresSafeArea(.container)

            // Connection / Auth / Error Overlay (always dark chrome over black canvas)
            if !client.state.isConnected {
                connectionOverlay
                    .environment(\.colorScheme, .dark)
            }

            // Floating HUD & Special Keys Bar (scoped to dark chrome for HIG contrast in Light & Dark Mode)
            VStack(spacing: 0) {
                topHUD
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .environment(\.colorScheme, .dark)

                if let toastMessage {
                    Text(toastMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        .environment(\.colorScheme, .dark)
                }

                Spacer()

                if showsModifierBar {
                    macModifierKeyBar
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .environment(\.colorScheme, .dark)
                }
            }

            // Hidden toolbar: only a small, faded, draggable handle remains so nothing covers the Mac.
            if isToolbarCollapsed && client.state.isConnected {
                collapsedToolbarHandle
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(client.state.isConnected)
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.selection, trigger: inputMode)
        .sensoryFeedback(.selection, trigger: isScrollMode)
        .sensoryFeedback(.selection, trigger: stickyModifiers)
        .onAppear {
            wireCallbacks()
            startConnection(credentials: target.initialCredentials)
        }
        .onChange(of: client.state) { _, newState in
            if newState.isConnected {
                // Only persist updated credentials after authentication succeeds.
                if let pid = target.profileID, let staged = stagedCredentialsForPersistence {
                    library.updateCredentialsAfterSuccess(
                        profileID: pid,
                        username: staged.username,
                        password: staged.password
                    )
                    stagedCredentialsForPersistence = nil
                }
            }
        }
        .onDisappear {
            cleanupSession()
        }
        .sheet(isPresented: $showSessionInfo) {
            sessionInfoSheet
        }
        .sheet(isPresented: $showCredentialsPrompt) {
            credentialsPromptSheet
        }
        .sheet(isPresented: $showShortcutsSheet) {
            MacShortcutsSheet(
                client: client,
                stickyModifiers: $stickyModifiers,
                onToast: showToast,
                onSendClipboard: sendClipboardToMac,
                onCopyMacClipboard: copyMacClipboard
            )
        }
    }

    // MARK: - Top Floating HUD (44pt minimum touch targets, HIG dark chrome)

    @ViewBuilder
    private var topHUD: some View {
        if isToolbarCollapsed && client.state.isConnected {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                // Disconnect
                Button {
                    disconnectAndClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.88), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Disconnect")

                // Server Title & Live Status Button
                Button {
                    showSessionInfo = true
                } label: {
                    SessionTitleLabel(client: client, fallbackTitle: target.title)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens session details")

                Spacer(minLength: 2)

                // Pointer Mode Toggle (moved into the Actions menu on iPhone to save width)
                if !isCompact {
                    Button {
                        togglePointerMode()
                    } label: {
                        hudCircleIcon(systemName: inputMode.systemImage, isActive: false)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Pointer Mode")
                    .accessibilityValue(inputMode.displayName)
                    .accessibilityHint("Switches between virtual trackpad and direct touch")
                }

                // Scroll Mode Toggle
                Button {
                    toggleScrollMode()
                } label: {
                    hudCircleIcon(systemName: "arrow.up.and.down.and.arrow.left.and.right", isActive: isScrollMode)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Scroll Mode")
                .accessibilityValue(isScrollMode ? "On" : "Off")
                .accessibilityHint("When on, drag one finger to scroll the Mac up, down, left or right")
                .accessibilityAddTraits(isScrollMode ? .isSelected : [])

                // Software Keyboard Toggle
                Button {
                    let next = !isSoftwareKeyboardVisible
                    canvasController.setKeyboardVisible(next)
                    if !next { showSpecialKeysBar = false }
                } label: {
                    hudCircleIcon(
                        systemName: isSoftwareKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                        isActive: isSoftwareKeyboardVisible
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Keyboard")
                .accessibilityValue(isSoftwareKeyboardVisible ? "Shown" : "Hidden")
                .accessibilityAddTraits(isSoftwareKeyboardVisible ? .isSelected : [])

                // Mac Shortcuts: full sheet on iPhone (every key visible), bottom bar on iPad
                Button {
                    if isCompact {
                        showShortcutsSheet = true
                    } else {
                        withOptionalAnimation {
                            showSpecialKeysBar.toggle()
                        }
                    }
                } label: {
                    hudCircleIcon(systemName: "command", isActive: !isCompact && showSpecialKeysBar)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Mac Shortcuts")
                .accessibilityValue(isCompact ? "" : (showSpecialKeysBar ? "Shown" : "Hidden"))
                .accessibilityAddTraits(!isCompact && showSpecialKeysBar ? .isSelected : [])

                // Session Actions Menu (isolated so live frame/stats updates never rebuild it while open)
                SessionActionsMenu(
                    isConnected: client.state.isConnected,
                    isScrollMode: isScrollMode,
                    inputMode: inputMode,
                    scrollSpeed: $scrollSpeed,
                    pointerSize: $pointerSize,
                    autoCopyRemoteClipboard: $autoCopyRemoteClipboard,
                    perform: performMenuAction
                )
                .equatable()

                // Hide Toolbar
                if client.state.isConnected {
                    Button {
                        hideToolbar()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: isCompact ? 36 : 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Hide Toolbar")
                    .accessibilityHint("Leaves a small button you can drag anywhere and tap to bring the toolbar back")
                }
            }
            .padding(.horizontal, isCompact ? 2 : 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.75))
            .frame(maxWidth: 720)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }

    private func performMenuAction(_ action: SessionMenuAction) {
        switch action {
        case .showAllShortcuts:
            showShortcutsSheet = true
        case .toggleScrollMode:
            toggleScrollMode()
        case .togglePointerMode:
            togglePointerMode()
        case .hideToolbar:
            hideToolbar()
        case .findPointer:
            canvasController.locatePointer()
        case .sendClipboardToMac:
            sendClipboardToMac()
        case .copyMacClipboard:
            copyMacClipboard()
        case .keyTap(let keySym, let modifiers, let toast):
            client.sendKeyTap(keySym: keySym, modifiers: modifiers)
            if let toast { showToast(toast) }
        case .fitToScreen:
            canvasController.fitToScreen()
        case .toggleZoom:
            canvasController.toggleActualSize()
        case .refreshScreen:
            client.requestFullRefresh()
            showToast("Refreshed screen")
        case .showSessionInfo:
            showSessionInfo = true
        }
    }

    private func sendClipboardToMac() {
        if let str = UIPasteboard.general.string, !str.isEmpty {
            client.sendClientCutText(str)
            showToast("Sent iOS clipboard to Mac")
        } else {
            showToast("iOS clipboard is empty")
        }
    }

    private func copyMacClipboard() {
        if !client.remoteClipboard.isEmpty {
            UIPasteboard.general.string = client.remoteClipboard
            showToast("Copied Mac clipboard")
        } else {
            showToast("No clipboard text received yet")
        }
    }

    private func hideToolbar() {
        withOptionalAnimation {
            isToolbarCollapsed = true
        }
        showToast("Toolbar hidden: tap the small button to show it, drag to move it")
    }

    private var collapsedToolbarHandle: some View {
        GeometryReader { geo in
            let size = geo.size
            let margin: CGFloat = 24
            let isDragging = toolbarHandleDrag != .zero
            let position = clampedHandlePosition(
                x: toolbarHandleX * size.width + toolbarHandleDrag.width,
                y: toolbarHandleY * size.height + toolbarHandleDrag.height,
                in: size,
                margin: margin
            )

            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                .opacity(isDragging ? 0.95 : 0.5)
                .scaleEffect(isDragging ? 1.15 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .hoverEffect(.highlight)
                .onTapGesture {
                    withOptionalAnimation {
                        isToolbarCollapsed = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .onChanged { value in
                            toolbarHandleDrag = value.translation
                        }
                        .onEnded { value in
                            let end = clampedHandlePosition(
                                x: toolbarHandleX * size.width + value.translation.width,
                                y: toolbarHandleY * size.height + value.translation.height,
                                in: size,
                                margin: margin
                            )
                            toolbarHandleX = Double(end.x / max(1, size.width))
                            toolbarHandleY = Double(end.y / max(1, size.height))
                            toolbarHandleDrag = .zero
                        }
                )
                .position(position)
                .accessibilityElement()
                .accessibilityLabel("Show Toolbar")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    isToolbarCollapsed = false
                }
        }
    }

    private func clampedHandlePosition(x: CGFloat, y: CGFloat, in size: CGSize, margin: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(margin, x), max(margin, size.width - margin)),
            y: min(max(margin, y), max(margin, size.height - margin))
        )
    }

    private func togglePointerMode() {
        inputMode = (inputMode == .trackpad) ? .directTouch : .trackpad
        showToast(inputMode == .trackpad ? "Trackpad Mode" : "Direct Touch Mode")
    }

    private func toggleScrollMode() {
        isScrollMode.toggle()
        showToast(isScrollMode
            ? "Scroll Mode on: drag to scroll, two fingers to pan"
            : "Scroll Mode off")
    }

    private func hudCircleIcon(systemName: String, isActive: Bool) -> some View {
        Image(systemName: systemName)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(
                isActive ? Color.accentColor : Color.white.opacity(0.16),
                in: Circle()
            )
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    // MARK: - Mac Modifier & Navigation Keys Bar (44pt minimum targets + Dismiss button)

    private var macModifierKeyBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    modifierChip("⌘", spokenName: "Command", keySym: RFBKeySym.macCommand)
                    modifierChip("⌥", spokenName: "Option", keySym: RFBKeySym.macOption)
                    modifierChip("⌃", spokenName: "Control", keySym: RFBKeySym.macControl)
                    modifierChip("⇧", spokenName: "Shift", keySym: RFBKeySym.macShift)

                    Divider()
                        .frame(height: 24)
                        .overlay(.white.opacity(0.25))

                    keyChip("Esc", spokenName: "Escape", keySym: RFBKeySym.escape)
                    keyChip("Tab", spokenName: "Tab", keySym: RFBKeySym.tab)
                    keyChip("⌫", spokenName: "Delete", keySym: RFBKeySym.backSpace)
                    keyChip("⏎", spokenName: "Return", keySym: RFBKeySym.returnKey)

                    Divider()
                        .frame(height: 24)
                        .overlay(.white.opacity(0.25))

                    keyChip("←", spokenName: "Left Arrow", keySym: RFBKeySym.leftArrow)
                    keyChip("↑", spokenName: "Up Arrow", keySym: RFBKeySym.upArrow)
                    keyChip("↓", spokenName: "Down Arrow", keySym: RFBKeySym.downArrow)
                    keyChip("→", spokenName: "Right Arrow", keySym: RFBKeySym.rightArrow)

                    Divider()
                        .frame(height: 24)
                        .overlay(.white.opacity(0.25))

                    comboChip("⌘C", spokenName: "Copy, Command C", key: 0x0063, mods: [RFBKeySym.macCommand])
                    comboChip("⌘V", spokenName: "Paste, Command V", key: 0x0076, mods: [RFBKeySym.macCommand])
                    comboChip("⌘Z", spokenName: "Undo, Command Z", key: 0x007A, mods: [RFBKeySym.macCommand])
                    comboChip("⌘Space", spokenName: "Spotlight, Command Space", key: RFBKeySym.space, mods: [RFBKeySym.macCommand])
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()
                .frame(height: 28)
                .overlay(.white.opacity(0.22))

            Button {
                showShortcutsSheet = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("All Mac Shortcuts")

            Button {
                canvasController.setKeyboardVisible(false)
                withOptionalAnimation {
                    showSpecialKeysBar = false
                }
            } label: {
                Image(systemName: isSoftwareKeyboardVisible ? "keyboard.chevron.compact.down" : "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(isSoftwareKeyboardVisible ? "Dismiss Keyboard" : "Hide Shortcuts Bar")
            .padding(.trailing, 4)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        )
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func modifierChip(_ title: String, spokenName: String, keySym: UInt32) -> some View {
        let isActive = stickyModifiers.contains(keySym)
        return Button {
            if isActive {
                stickyModifiers.remove(keySym)
            } else {
                stickyModifiers.insert(keySym)
            }
        } label: {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.white.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(spokenName)
        .accessibilityValue(isActive ? "Active" : "Inactive")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func keyChip(_ title: String, spokenName: String, keySym: UInt32) -> some View {
        Button {
            let mods = Array(stickyModifiers)
            client.sendKeyTap(keySym: keySym, modifiers: mods)
            stickyModifiers.removeAll()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(spokenName)
    }

    private func comboChip(_ title: String, spokenName: String, key: UInt32, mods: [UInt32]) -> some View {
        Button {
            client.sendKeyTap(keySym: key, modifiers: mods)
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(spokenName)
    }

    // MARK: - Connection Overlay

    private var connectionOverlay: some View {
        VStack(spacing: 16) {
            switch client.state {
            case .connecting, .authenticating, .idle:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(client.state.statusText)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(target.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))

            case .disconnected(let reason):
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Connection Ended")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(reason ?? "The remote Mac closed the session.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                ViewThatFits {
                    HStack(spacing: 12) {
                        overlayActionButtons
                    }
                    VStack(spacing: 10) {
                        overlayActionButtons
                    }
                }
                .padding(.top, 4)

            case .connected:
                EmptyView()
            }
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .padding(24)
    }

    @ViewBuilder
    private var overlayActionButtons: some View {
        if !target.isDemo {
            Button("Enter Credentials") {
                showCredentialsPrompt = true
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        Button("Reconnect") {
            startConnection(credentials: RFBCredentials(username: promptUsername, password: promptPassword))
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Sheets

    private var sessionInfoSheet: some View {
        SessionInfoSheet(client: client) {
            showSessionInfo = false
        }
    }

    private var credentialsPromptSheet: some View {
        NavigationStack {
            Form {
                Section("Sign In to \(target.title)") {
                    TextField("macOS Username (leave blank for VNC password)", text: $promptUsername)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                    SecureField("Password", text: $promptPassword)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            submitCredentialsRetry()
                        }
                }
                Section {
                    Text("Updated credentials are saved to Keychain only after authentication succeeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCredentialsPrompt = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        submitCredentialsRetry()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func submitCredentialsRetry() {
        showCredentialsPrompt = false
        let creds = RFBCredentials(
            username: promptUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: promptPassword
        )
        stagedCredentialsForPersistence = creds
        startConnection(credentials: creds)
    }

    // MARK: - Lifecycle Helpers

    private func wireCallbacks() {
        client.onServerCutText = { text in
            guard !text.isEmpty else { return }
            if autoCopyRemoteClipboard {
                UIPasteboard.general.string = text
                showToast("Synced clipboard from Mac")
            } else {
                showToast("Mac clipboard updated (copy via Actions menu)")
            }
        }
        client.onBell = {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func startConnection(credentials: RFBCredentials) {
        demoStartupTask?.cancel()
        demoStartupTask = nil
        demoServer?.stop()
        demoServer = nil

        if let pid = target.profileID {
            library.markConnected(profileID: pid)
        }

        if target.isDemo {
            let server = DemoMacVNCServer(width: 1280, height: 800, serverName: "Demo MacBook Pro", authMode: .none)
            demoServer = server
            demoStartupTask = Task {
                do {
                    let port = try await server.start()
                    guard !Task.isCancelled, demoServer === server else {
                        server.stop()
                        return
                    }
                    client.connect(
                        host: "127.0.0.1",
                        port: port,
                        credentials: credentials,
                        authPreference: .none
                    )
                } catch is CancellationError {
                    server.stop()
                } catch {
                    guard !Task.isCancelled else { return }
                    client.disconnect(reason: "Could not start Demo Mac server: \(error.localizedDescription)")
                }
            }
        } else if let endpoint = target.bonjourEndpoint {
            client.connect(
                endpoint: endpoint,
                credentials: credentials,
                authPreference: target.authPreference
            )
        } else if let host = target.host {
            client.connect(
                host: host,
                port: target.port,
                credentials: credentials,
                authPreference: target.authPreference
            )
        }
    }

    private func saveThumbnailIfNeeded() {
        guard let pid = target.profileID,
              client.stats.totalFrames > 0,
              let jpeg = client.captureThumbnailJPEG() else { return }
        library.saveThumbnail(jpeg, for: pid)
    }

    private func cleanupSession() {
        saveThumbnailIfNeeded()
        demoStartupTask?.cancel()
        demoStartupTask = nil
        client.disconnect()
        demoServer?.stop()
        demoServer = nil
    }

    private func disconnectAndClose() {
        cleanupSession()
        onClose()
    }

    private func withOptionalAnimation(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(.spring(duration: 0.25)) {
                body()
            }
        }
    }

    private func showToast(_ text: String) {
        withOptionalAnimation {
            toastMessage = text
        }
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withOptionalAnimation {
                if toastMessage == text {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - Isolated subviews (keep high-frequency updates away from the menu)

enum SessionMenuAction {
    case showAllShortcuts
    case toggleScrollMode
    case togglePointerMode
    case hideToolbar
    case findPointer
    case sendClipboardToMac
    case copyMacClipboard
    case keyTap(UInt32, [UInt32], String?)
    case fitToScreen
    case toggleZoom
    case refreshScreen
    case showSessionInfo
}

/// The ⋯ menu. Equatable on its displayed values only, so it is not rebuilt (which resets
/// the open menu's scroll position) when the session view re-renders for other reasons.
private struct SessionActionsMenu: View, @MainActor Equatable {
    let isConnected: Bool
    let isScrollMode: Bool
    let inputMode: PointerInputMode
    @Binding var scrollSpeed: ScrollSpeed
    @Binding var pointerSize: PointerSize
    @Binding var autoCopyRemoteClipboard: Bool
    let perform: (SessionMenuAction) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.isScrollMode == rhs.isScrollMode
            && lhs.inputMode == rhs.inputMode
            && lhs.scrollSpeed == rhs.scrollSpeed
            && lhs.pointerSize == rhs.pointerSize
            && lhs.autoCopyRemoteClipboard == rhs.autoCopyRemoteClipboard
    }

    var body: some View {
        Menu {
            Section("Clipboard") {
                Button {
                    perform(.sendClipboardToMac)
                } label: {
                    Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard")
                }
                Button {
                    perform(.copyMacClipboard)
                } label: {
                    Label("Copy Mac Clipboard", systemImage: "clipboard")
                }
                Toggle("Auto-Sync Mac Clipboard", isOn: $autoCopyRemoteClipboard)
            }

            Section("Controls") {
                Button {
                    perform(.showAllShortcuts)
                } label: {
                    Label("All Mac Shortcuts…", systemImage: "command")
                }
                Button {
                    perform(.toggleScrollMode)
                } label: {
                    Label(isScrollMode ? "Turn Off Scroll Mode" : "Turn On Scroll Mode", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                Button {
                    perform(.togglePointerMode)
                } label: {
                    Label(
                        inputMode == .trackpad ? "Switch to Direct Touch" : "Switch to Trackpad",
                        systemImage: inputMode == .trackpad ? PointerInputMode.directTouch.systemImage : PointerInputMode.trackpad.systemImage
                    )
                }
                if isConnected {
                    Button {
                        perform(.hideToolbar)
                    } label: {
                        Label("Hide Toolbar", systemImage: "chevron.up")
                    }
                }
            }

            Section("Mac Shortcuts") {
                Button {
                    perform(.keyTap(RFBKeySym.space, [RFBKeySym.macCommand], "Sent Spotlight (⌘Space)"))
                } label: {
                    Label("Spotlight (⌘ Space)", systemImage: "magnifyingglass")
                }
                Button {
                    perform(.keyTap(RFBKeySym.tab, [RFBKeySym.macCommand], nil))
                } label: {
                    Label("App Switcher (⌘ Tab)", systemImage: "rectangle.stack")
                }
                Button {
                    perform(.keyTap(RFBKeySym.upArrow, [RFBKeySym.macControl], nil))
                } label: {
                    Label("Mission Control (⌃ ↑)", systemImage: "macwindow.on.rectangle")
                }
                Button {
                    perform(.keyTap(RFBKeySym.escape, [RFBKeySym.macCommand, RFBKeySym.macOption], nil))
                } label: {
                    Label("Force Quit (⌘⌥ Esc)", systemImage: "exclamationmark.triangle")
                }
            }

            Section("Pointer & Scrolling") {
                Button {
                    perform(.findPointer)
                } label: {
                    Label("Find Pointer", systemImage: "cursorarrow.rays")
                }
                Picker(selection: $pointerSize) {
                    ForEach(PointerSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                } label: {
                    Label("Pointer Size", systemImage: "cursorarrow")
                }
                .pickerStyle(.menu)
                Picker(selection: $scrollSpeed) {
                    ForEach(ScrollSpeed.allCases) { speed in
                        Text(speed.displayName).tag(speed)
                    }
                } label: {
                    Label("Scroll Speed", systemImage: "gauge.with.dots.needle.67percent")
                }
                .pickerStyle(.menu)
            }

            Section("Display") {
                Button {
                    perform(.fitToScreen)
                } label: {
                    Label("Fit to Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button {
                    perform(.toggleZoom)
                } label: {
                    Label("Toggle Zoom", systemImage: "plus.magnifyingglass")
                }
                Button {
                    perform(.refreshScreen)
                } label: {
                    Label("Force Screen Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    perform(.showSessionInfo)
                } label: {
                    Label("Session Info", systemImage: "info.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.16), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel("Session Actions")
    }
}

/// Server name + live resolution/encoding. Reads `client.stats` so only this label re-renders.
private struct SessionTitleLabel: View {
    let client: RFBClient
    let fallbackTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(client.state.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(client.stats.serverName.isEmpty ? fallbackTitle : client.stats.serverName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if client.state.isConnected {
                Text("\(Int(client.stats.resolution.width))×\(Int(client.stats.resolution.height)) • \(client.stats.lastEncoding)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }
}

private struct SessionInfoSheet: View {
    let client: RFBClient
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Server Name", value: client.stats.serverName)
                LabeledContent("Protocol", value: client.stats.protocolVersion)
                LabeledContent("Authentication", value: client.stats.securityMethod)
                LabeledContent("Resolution", value: "\(Int(client.stats.resolution.width)) × \(Int(client.stats.resolution.height))")
                LabeledContent("Active Encoding", value: client.stats.lastEncoding)
                LabeledContent("Frame Rate", value: String(format: "%.1f fps", client.stats.framesPerSecond))
                LabeledContent("Frames Received", value: "\(client.stats.totalFrames)")
            }
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
