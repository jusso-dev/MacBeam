import SwiftUI

struct HomeView: View {
    @Bindable var library: ConnectionLibraryStore
    @Bindable var discovery: BonjourMacDiscovery

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var cardIconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .title2) private var featureIconSize: CGFloat = 48

    @State private var searchText = ""
    @State private var activeSession: ActiveSessionTarget?
    @State private var showAddSheet = false
    @State private var editingProfile: MacConnectionProfile?
    @State private var profilePendingDeletion: MacConnectionProfile?
    @State private var showQuickConnect = false
    @State private var showSetupGuide = false

    // Quick Connect state
    @State private var quickHost = ""
    @State private var quickPort = "5900"
    @State private var quickUsername = ""
    @State private var quickPassword = ""

    // Bonjour credentials prompt before connecting
    @State private var pendingBonjourMac: DiscoveredMac?
    @State private var bonjourUsername = ""
    @State private var bonjourPassword = ""
    @State private var bonjourAuthPreference: MacAuthPreference = .auto

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16)
    ]

    private var filteredProfiles: [MacConnectionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.sortedProfiles }
        return library.sortedProfiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.displayAddress.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredNearbyMacs: [DiscoveredMac] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return discovery.discoveredMacs }
        return discovery.discoveredMacs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasSearchQuery && filteredProfiles.isEmpty && filteredNearbyMacs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if !hasSearchQuery || !filteredProfiles.isEmpty {
                                savedMacsSection
                            }
                            if !hasSearchQuery || !filteredNearbyMacs.isEmpty {
                                nearbyMacsSection
                            }
                            if !hasSearchQuery {
                                demoAndGuideSection
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MacBeam")
            .searchable(text: $searchText, prompt: "Search Macs")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSetupGuide = true
                    } label: {
                        Label("Setup Guide", systemImage: "questionmark.circle")
                    }
                    .keyboardShortcut("?", modifiers: [.command])

                    Button {
                        showQuickConnect = true
                    } label: {
                        Label("Quick Connect", systemImage: "bolt.horizontal.circle")
                    }
                    .keyboardShortcut("k", modifiers: [.command])

                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Mac", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command])
                }
            }
            .onAppear {
                discovery.startScanning()
            }
            .sheet(isPresented: $showAddSheet) {
                ConnectionEditorSheet { profile, password in
                    library.upsert(profile, password: password)
                }
            }
            .sheet(item: $editingProfile) { profile in
                ConnectionEditorSheet(
                    profile: profile,
                    existingPassword: library.password(for: profile)
                ) { updated, password in
                    library.upsert(updated, password: password)
                }
            }
            .sheet(isPresented: $showQuickConnect) {
                quickConnectSheet
            }
            .sheet(isPresented: $showSetupGuide) {
                SetupGuideSheet()
            }
            .sheet(item: $pendingBonjourMac) { mac in
                bonjourConnectSheet(for: mac)
            }
            .confirmationDialog(
                "Delete \(profilePendingDeletion?.name ?? "Mac")?",
                isPresented: Binding(
                    get: { profilePendingDeletion != nil },
                    set: { if !$0 { profilePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Mac", role: .destructive) {
                    if let target = profilePendingDeletion {
                        library.delete(target)
                    }
                    profilePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    profilePendingDeletion = nil
                }
            } message: {
                Text("This removes the saved connection and its Keychain password from this device.")
            }
            .fullScreenCover(item: $activeSession) { session in
                RemoteSessionView(target: session, library: library) {
                    activeSession = nil
                }
            }
        }
    }

    // MARK: - Saved Macs Grid

    private var savedMacsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved Macs")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !library.profiles.isEmpty {
                    Text("\(filteredProfiles.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .accessibilityLabel("\(filteredProfiles.count) saved Macs")
                }
            }

            if filteredProfiles.isEmpty {
                emptySavedCard
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredProfiles) { profile in
                        macCard(for: profile)
                    }
                }
            }
        }
    }

    private var emptySavedCard: some View {
        ContentUnavailableView {
            Label("No Saved Macs Yet", systemImage: "macbook.and.ipad")
        } description: {
            Text("Add your Mac by hostname or IP, or tap a Mac discovered automatically on your Wi-Fi network below.")
        } actions: {
            ViewThatFits {
                HStack(spacing: 12) {
                    emptyStateButtons
                }
                VStack(spacing: 10) {
                    emptyStateButtons
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var emptyStateButtons: some View {
        Button {
            showAddSheet = true
        } label: {
            Label("Add Mac", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)

        Button {
            showSetupGuide = true
        } label: {
            Label("Setup Guide", systemImage: "book")
        }
        .buttonStyle(.bordered)
    }

    private func macCard(for profile: MacConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                connectToProfile(profile)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    // Screen Preview Thumbnail
                    ZStack {
                        if let thumb = library.thumbnails[profile.id] {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                        } else {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.10, green: 0.16, blue: 0.34),
                                    Color(red: 0.19, green: 0.12, blue: 0.32)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: profile.icon.rawValue)
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.88))
                        }
                    }
                    .frame(height: 145)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if profile.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.yellow)
                                .padding(7)
                                .background(.black.opacity(0.5), in: Circle())
                                .padding(10)
                                .accessibilityHidden(true)
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: profile.icon.rawValue)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: cardIconSize, height: cardIconSize)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            Text(profile.displayAddress)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        }

                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 48)
                    .padding(.vertical, 14)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.name), \(profile.displayAddress)\(profile.isFavorite ? ", Favorite" : "")")
            .accessibilityHint("Connects to this Mac")
            .accessibilityActions {
                Button("Edit Mac") { editingProfile = profile }
                Button(profile.isFavorite ? "Remove Favorite" : "Favorite") { library.toggleFavorite(profile) }
                Button("Delete Mac", role: .destructive) { profilePendingDeletion = profile }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                cardMenuItems(for: profile)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("Options for \(profile.name)")
            .padding(.trailing, 4)
            .padding(.bottom, 6)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.75)
        )
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.06), radius: 8, y: 3)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hoverEffect(.lift)
        .contextMenu {
            cardMenuItems(for: profile)
        }
    }

    @ViewBuilder
    private func cardMenuItems(for profile: MacConnectionProfile) -> some View {
        Button {
            connectToProfile(profile)
        } label: {
            Label("Connect", systemImage: "play.fill")
        }
        Button {
            editingProfile = profile
        } label: {
            Label("Edit Mac", systemImage: "pencil")
        }
        Button {
            library.toggleFavorite(profile)
        } label: {
            Label(profile.isFavorite ? "Remove Favorite" : "Favorite", systemImage: profile.isFavorite ? "star.slash" : "star")
        }
        Divider()
        Button(role: .destructive) {
            profilePendingDeletion = profile
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func connectToProfile(_ profile: MacConnectionProfile) {
        let pwd = library.password(for: profile)
        activeSession = .profile(profile, password: pwd)
    }

    // MARK: - Bonjour Nearby Macs

    private var nearbyMacsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Nearby Macs")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if discovery.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Scanning for nearby Macs")
                }
                Spacer()
                Button("Rescan") {
                    discovery.startScanning()
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
                .keyboardShortcut("r", modifiers: [.command])
            }

            if filteredNearbyMacs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "bonjour")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning local network for Screen Sharing (_rfb._tcp)…")
                            .font(.subheadline.weight(.medium))
                        Text(discovery.statusMessage ?? "Turn on Screen Sharing in macOS System Settings to appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredNearbyMacs) { mac in
                        Button {
                            bonjourUsername = ""
                            bonjourPassword = ""
                            bonjourAuthPreference = .auto
                            pendingBonjourMac = mac
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                    .frame(width: cardIconSize, height: cardIconSize)
                                    .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    Text("Bonjour Screen Sharing (\(mac.domain))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                Text("Connect")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(14)
                            .frame(minHeight: 68)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .hoverEffect(.lift)
                    }
                }
            }
        }
    }

    // MARK: - Demo Sandbox & Quick Tips

    private var demoAndGuideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try & Learn")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: 14) {
                Button {
                    activeSession = .demoMac
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles.tv.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: featureIconSize, height: featureIconSize)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Launch Demo Mac")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Test live RFB 3.8 streaming, trackpad & keyboard right now.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16, style: .continuous))
                .hoverEffect(.lift)

                Button {
                    showSetupGuide = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "macwindow.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: featureIconSize, height: featureIconSize)
                            .background(Color.teal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable Mac Screen Sharing")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("3-step setup guide for macOS + iPad keyboard gestures.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16, style: .continuous))
                .hoverEffect(.lift)
            }
        }
    }

    // MARK: - Quick Connect & Bonjour Sheets

    private var quickConnectSheet: some View {
        NavigationStack {
            Form {
                Section("Quick Connect") {
                    TextField("Host or IP (e.g. studio.local or 100.64.0.5)", text: $quickHost)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Port") {
                        TextField("5900", text: $quickPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    TextField("macOS Username", text: $quickUsername)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $quickPassword)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Credentials (Optional)")
                } footer: {
                    Text("Use trusted local Wi-Fi or a VPN such as Tailscale when signing in with macOS credentials.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showQuickConnect = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let host = quickHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        let port = UInt16(quickPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5900
                        showQuickConnect = false
                        activeSession = ActiveSessionTarget(
                            id: "quick-\(host):\(port)-\(UUID().uuidString)",
                            title: host,
                            profileID: nil,
                            host: host,
                            port: port,
                            bonjourEndpoint: nil,
                            isDemo: false,
                            authPreference: .auto,
                            initialCredentials: RFBCredentials(
                                username: quickUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: quickPassword
                            ),
                            preferredInputMode: .trackpad
                        )
                    }
                    .fontWeight(.semibold)
                    .disabled(quickHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func bonjourConnectSheet(for mac: DiscoveredMac) -> some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Authentication", selection: $bonjourAuthPreference) {
                        ForEach(MacAuthPreference.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if bonjourAuthPreference == .auto || bonjourAuthPreference == .macOSAccount {
                        TextField("macOS Username (leave blank for VNC password)", text: $bonjourUsername)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if bonjourAuthPreference != .none {
                        SecureField("Password", text: $bonjourPassword)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Connect to \(mac.name)")
                } footer: {
                    Text("Verify this Bonjour Mac belongs to you before entering macOS account credentials.")
                }

                Section {
                    Button("Save to Library & Connect") {
                        let trimmedUser = bonjourUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                        let profile = MacConnectionProfile(
                            name: mac.name,
                            host: mac.name,
                            port: 5900,
                            bonjourServiceName: mac.name,
                            bonjourServiceDomain: mac.domain,
                            username: bonjourAuthPreference == .vncPassword ? "" : trimmedUser,
                            authPreference: bonjourAuthPreference
                        )
                        library.upsert(profile, password: bonjourAuthPreference == .none ? "" : bonjourPassword)
                        pendingBonjourMac = nil
                        activeSession = .bonjour(
                            mac,
                            profileID: profile.id,
                            credentials: RFBCredentials(
                                username: bonjourAuthPreference == .vncPassword ? "" : trimmedUser,
                                password: bonjourAuthPreference == .none ? "" : bonjourPassword
                            ),
                            authPreference: bonjourAuthPreference
                        )
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pendingBonjourMac = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let trimmedUser = bonjourUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                        let creds = RFBCredentials(
                            username: bonjourAuthPreference == .vncPassword ? "" : trimmedUser,
                            password: bonjourAuthPreference == .none ? "" : bonjourPassword
                        )
                        pendingBonjourMac = nil
                        activeSession = .bonjour(
                            mac,
                            credentials: creds,
                            authPreference: bonjourAuthPreference
                        )
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
