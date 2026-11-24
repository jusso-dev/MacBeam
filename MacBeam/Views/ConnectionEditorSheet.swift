import SwiftUI

struct ConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title3) private var iconTileSize: CGFloat = 46

    private enum Field: Hashable {
        case name, host, port, username, password
    }
    @FocusState private var focusedField: Field?

    let existingProfile: MacConnectionProfile?
    let onSave: (MacConnectionProfile, String) -> Void

    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var authPreference: MacAuthPreference
    @State private var inputMode: PointerInputMode
    @State private var icon: MacDeviceIcon
    @State private var isFavorite: Bool

    init(
        profile: MacConnectionProfile? = nil,
        prefillName: String = "",
        prefillHost: String = "",
        existingPassword: String = "",
        onSave: @escaping (MacConnectionProfile, String) -> Void
    ) {
        self.existingProfile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? prefillName)
        _host = State(initialValue: profile?.host ?? prefillHost)
        _portText = State(initialValue: String(profile?.port ?? 5900))
        _username = State(initialValue: profile?.username ?? "")
        _password = State(initialValue: existingPassword)
        _authPreference = State(initialValue: profile?.authPreference ?? .auto)
        _inputMode = State(initialValue: profile?.preferredInputMode ?? .trackpad)
        _icon = State(initialValue: profile?.icon ?? .macbook)
        _isFavorite = State(initialValue: profile?.isFavorite ?? false)
    }

    private var isBonjourOnly: Bool {
        existingProfile?.isBonjourProfile ?? false
    }

    private var canSave: Bool {
        if isBonjourOnly {
            return true
        }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac Details") {
                    TextField("Display Name (e.g. Studio MacBook Pro)", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = isBonjourOnly ? .username : .host }

                    if isBonjourOnly, let service = existingProfile?.bonjourServiceName {
                        LabeledContent("Bonjour Service", value: service)
                    } else {
                        TextField("Hostname or IP (e.g. my-mac.local or 192.168.1.25)", text: $host)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .port }

                        LabeledContent("Port") {
                            TextField("5900", text: $portText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .port)
                        }
                    }

                    Toggle("Pin to Favorites", isOn: $isFavorite)
                }

                Section {
                    Picker("Authentication", selection: $authPreference) {
                        ForEach(MacAuthPreference.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    if authPreference == .auto || authPreference == .macOSAccount {
                        TextField("macOS Username (optional for VNC password)", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }

                    if authPreference != .none {
                        SecureField("Password (saved in Keychain)", text: $password)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .password)
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authPreference.subtitle)
                        if authPreference == .vncPassword && password.utf8.count > 8 {
                            Text("Note: Standard VNC DES authentication only uses the first 8 bytes of the password.")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Controls") {
                    Picker("Default Pointer Mode", selection: $inputMode) {
                        ForEach(PointerInputMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                }

                Section("Device Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(MacDeviceIcon.allCases) { item in
                                Button {
                                    icon = item
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: item.rawValue)
                                            .font(.title3)
                                            .frame(width: iconTileSize, height: iconTileSize)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .fill(icon == item ? Color.accentColor : Color.secondary.opacity(0.14))
                                            )
                                            .foregroundStyle(icon == item ? .white : .primary)
                                        Text(item.label)
                                            .font(.caption2)
                                            .foregroundStyle(icon == item ? Color.accentColor : .secondary)
                                    }
                                    .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                .accessibilityLabel("\(item.label) icon")
                                .accessibilityAddTraits(icon == item ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existingProfile == nil ? "Add Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5900
                        let profile = MacConnectionProfile(
                            id: existingProfile?.id ?? UUID(),
                            name: trimmedName.isEmpty ? (existingProfile?.bonjourServiceName ?? trimmedHost) : trimmedName,
                            host: trimmedHost,
                            port: port,
                            bonjourServiceName: existingProfile?.bonjourServiceName,
                            bonjourServiceDomain: existingProfile?.bonjourServiceDomain,
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            authPreference: authPreference,
                            preferredInputMode: inputMode,
                            icon: icon,
                            isFavorite: isFavorite,
                            lastConnectedAt: existingProfile?.lastConnectedAt
                        )
                        onSave(profile, password)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }
}
