import Foundation
import Network

public enum MacAuthPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case macOSAccount = "macos"
    case vncPassword = "vnc"
    case none = "none"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .macOSAccount: return "macOS Username & Password"
        case .vncPassword: return "VNC Password Only"
        case .none: return "No Password"
        }
    }

    public var subtitle: String {
        switch self {
        case .auto: return "Selects Apple Screen Sharing or VNC auth based on provided credentials."
        case .macOSAccount: return "Strictly requires Apple Diffie-Hellman (macOS user login). No downgrade."
        case .vncPassword: return "Strictly requires standard RFB VNC password (truncated to 8 bytes by RFB spec)."
        case .none: return "Strictly connects without authentication."
        }
    }
}

/// On-screen size of the remote Mac pointer.
public enum PointerSize: String, CaseIterable, Identifiable, Sendable {
    case normal
    case large
    case extraLarge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    public var multiplier: CGFloat {
        switch self {
        case .normal: return 1.0
        case .large: return 1.35
        case .extraLarge: return 1.8
        }
    }
}

public enum PointerInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case trackpad = "trackpad"
    case directTouch = "directTouch"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .directTouch: return "Touch"
        }
    }

    public var systemImage: String {
        switch self {
        case .trackpad: return "rectangle.and.hand.point.up.left.filled"
        case .directTouch: return "hand.tap.fill"
        }
    }
}

public enum MacDeviceIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case macbook = "laptopcomputer"
    case imac = "desktopcomputer"
    case macMini = "macmini"
    case macStudio = "macstudio"
    case macPro = "macpro.gen3"
    case display = "display"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .macbook: return "MacBook"
        case .imac: return "iMac"
        case .macMini: return "Mac mini"
        case .macStudio: return "Mac Studio"
        case .macPro: return "Mac Pro"
        case .display: return "Display"
        }
    }
}

public struct MacConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var bonjourServiceName: String?
    public var bonjourServiceDomain: String?
    public var username: String
    public var authPreference: MacAuthPreference
    public var preferredInputMode: PointerInputMode
    public var icon: MacDeviceIcon
    public var isFavorite: Bool
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 5900,
        bonjourServiceName: String? = nil,
        bonjourServiceDomain: String? = nil,
        username: String = "",
        authPreference: MacAuthPreference = .auto,
        preferredInputMode: PointerInputMode = .trackpad,
        icon: MacDeviceIcon = .macbook,
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.bonjourServiceName = bonjourServiceName
        self.bonjourServiceDomain = bonjourServiceDomain
        self.username = username
        self.authPreference = authPreference
        self.preferredInputMode = preferredInputMode
        self.icon = icon
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
    }

    public var isBonjourProfile: Bool {
        if let service = bonjourServiceName, !service.isEmpty {
            return true
        }
        return false
    }

    public var bonjourEndpoint: NWEndpoint? {
        guard let service = bonjourServiceName, !service.isEmpty else { return nil }
        return NWEndpoint.service(
            name: service,
            type: "_rfb._tcp",
            domain: bonjourServiceDomain ?? "local.",
            interface: nil
        )
    }

    public var displayAddress: String {
        if let service = bonjourServiceName, !service.isEmpty {
            return "Bonjour • \(service)"
        }
        return port == 5900 ? host : "\(host):\(port)"
    }
}

/// Represents an active remote session target (saved profile, Bonjour Mac, or local Demo Mac).
public struct ActiveSessionTarget: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let profileID: UUID?
    public let host: String?
    public let port: UInt16
    public let bonjourEndpoint: NWEndpoint?
    public let isDemo: Bool
    public let authPreference: MacAuthPreference
    public let initialCredentials: RFBCredentials
    public let preferredInputMode: PointerInputMode

    public static func == (lhs: ActiveSessionTarget, rhs: ActiveSessionTarget) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.profileID == rhs.profileID &&
        lhs.host == rhs.host &&
        lhs.port == rhs.port &&
        lhs.isDemo == rhs.isDemo &&
        lhs.authPreference == rhs.authPreference &&
        lhs.initialCredentials == rhs.initialCredentials &&
        lhs.preferredInputMode == rhs.preferredInputMode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(profileID)
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(isDemo)
        hasher.combine(authPreference)
    }

    public static func profile(_ profile: MacConnectionProfile, password: String) -> ActiveSessionTarget {
        ActiveSessionTarget(
            id: profile.id.uuidString,
            title: profile.name,
            profileID: profile.id,
            host: profile.isBonjourProfile ? nil : profile.host,
            port: profile.port,
            bonjourEndpoint: profile.bonjourEndpoint,
            isDemo: false,
            authPreference: profile.authPreference,
            initialCredentials: RFBCredentials(
                username: profile.authPreference == .vncPassword ? "" : profile.username,
                password: profile.authPreference == .none ? "" : password
            ),
            preferredInputMode: profile.preferredInputMode
        )
    }

    public static func bonjour(
        _ mac: DiscoveredMac,
        profileID: UUID? = nil,
        credentials: RFBCredentials = RFBCredentials(),
        authPreference: MacAuthPreference = .auto
    ) -> ActiveSessionTarget {
        ActiveSessionTarget(
            id: profileID?.uuidString ?? "bonjour-\(mac.id)",
            title: mac.name,
            profileID: profileID,
            host: nil,
            port: 5900,
            bonjourEndpoint: mac.endpoint,
            isDemo: false,
            authPreference: authPreference,
            initialCredentials: credentials,
            preferredInputMode: .trackpad
        )
    }

    public static var demoMac: ActiveSessionTarget {
        ActiveSessionTarget(
            id: "local-demo-mac",
            title: "Demo MacBook Pro",
            profileID: nil,
            host: "127.0.0.1",
            port: 0,
            bonjourEndpoint: nil,
            isDemo: true,
            authPreference: .none,
            initialCredentials: RFBCredentials(),
            preferredInputMode: .trackpad
        )
    }
}
