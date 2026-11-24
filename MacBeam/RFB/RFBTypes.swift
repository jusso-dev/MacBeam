import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Protocol Version

public struct RFBVersion: Equatable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int

    public static let v3_3 = RFBVersion(major: 3, minor: 3)
    public static let v3_7 = RFBVersion(major: 3, minor: 7)
    public static let v3_8 = RFBVersion(major: 3, minor: 8)
    public static let apple3_889 = RFBVersion(major: 3, minor: 889)

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(handshakeString: String) {
        guard handshakeString.count == 12,
              handshakeString.hasPrefix("RFB "),
              handshakeString.hasSuffix("\n") else {
            return nil
        }
        let body = handshakeString.dropFirst(4).dropLast(1)
        let parts = body.split(separator: ".")
        guard parts.count == 2,
              let maj = Int(parts[0]),
              let min = Int(parts[1]) else {
            return nil
        }
        self.major = maj
        self.minor = min
    }

    public var wireData: Data {
        let formatted = String(format: "RFB %03d.%03d\n", major, minor)
        return Data(formatted.utf8)
    }

    public var description: String {
        "\(major).\(minor)"
    }
}

// MARK: - Security Types

public enum RFBSecurityType: UInt8, CaseIterable, Sendable, CustomStringConvertible {
    case invalid = 0
    case none = 1
    case vncAuthentication = 2
    case appleDiffieHellman = 30
    case appleRemoteDesktop = 35

    public var description: String {
        switch self {
        case .invalid: return "Invalid"
        case .none: return "None"
        case .vncAuthentication: return "VNC Password"
        case .appleDiffieHellman: return "macOS Sign-In (Apple DH)"
        case .appleRemoteDesktop: return "Apple Remote Desktop"
        }
    }
}

// MARK: - Encodings

public enum RFBEncoding: Int32, Sendable, CustomStringConvertible {
    case raw = 0
    case copyRect = 1
    case rre = 2
    case hextile = 5
    case zlib = 6
    case zrle = 16
    case cursor = -239
    case desktopSize = -223
    case lastRect = -224
    case extendedDesktopSize = -308

    public var description: String {
        switch self {
        case .raw: return "Raw"
        case .copyRect: return "CopyRect"
        case .rre: return "RRE"
        case .hextile: return "Hextile"
        case .zlib: return "Zlib"
        case .zrle: return "ZRLE"
        case .cursor: return "Rich Cursor"
        case .desktopSize: return "DesktopSize"
        case .lastRect: return "LastRect"
        case .extendedDesktopSize: return "ExtendedDesktopSize"
        }
    }
}

// MARK: - Pixel Format

public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndianFlag: UInt8
    public var trueColourFlag: UInt8
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    /// Native 32-bpp BGRA little-endian format matching CoreGraphics `noneSkipFirst | byteOrder32Little`.
    public static let bgra32 = RFBPixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndianFlag: 0,
        trueColourFlag: 1,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    public var bytesPerPixel: Int {
        Int(bitsPerPixel) / 8
    }

    public var isNativeBGRA32: Bool {
        bitsPerPixel == 32 &&
        bigEndianFlag == 0 &&
        trueColourFlag == 1 &&
        redMax == 255 && greenMax == 255 && blueMax == 255 &&
        redShift == 16 && greenShift == 8 && blueShift == 0
    }

    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndianFlag: UInt8,
        trueColourFlag: UInt8,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndianFlag = bigEndianFlag
        self.trueColourFlag = trueColourFlag
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    public init?(data: Data) {
        guard data.count >= 16 else { return nil }
        let b = [UInt8](data.prefix(16))
        self.bitsPerPixel = b[0]
        self.depth = b[1]
        self.bigEndianFlag = b[2]
        self.trueColourFlag = b[3]
        self.redMax = (UInt16(b[4]) << 8) | UInt16(b[5])
        self.greenMax = (UInt16(b[6]) << 8) | UInt16(b[7])
        self.blueMax = (UInt16(b[8]) << 8) | UInt16(b[9])
        self.redShift = b[10]
        self.greenShift = b[11]
        self.blueShift = b[12]
    }

    public var wireData: Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = bitsPerPixel
        bytes[1] = depth
        bytes[2] = bigEndianFlag
        bytes[3] = trueColourFlag
        bytes[4] = UInt8(redMax >> 8)
        bytes[5] = UInt8(redMax & 0xFF)
        bytes[6] = UInt8(greenMax >> 8)
        bytes[7] = UInt8(greenMax & 0xFF)
        bytes[8] = UInt8(blueMax >> 8)
        bytes[9] = UInt8(blueMax & 0xFF)
        bytes[10] = redShift
        bytes[11] = greenShift
        bytes[12] = blueShift
        return Data(bytes)
    }

    /// Converts a pixel value from this wire pixel format into packed BGRA (B, G, R, A).
    @inline(__always)
    public func unpackToBGRA(_ rawValue: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        if isNativeBGRA32 {
            let b = UInt8(rawValue & 0xFF)
            let g = UInt8((rawValue >> 8) & 0xFF)
            let r = UInt8((rawValue >> 16) & 0xFF)
            return (b, g, r, 0xFF)
        }
        let rRaw = (rawValue >> UInt32(redShift)) & UInt32(redMax)
        let gRaw = (rawValue >> UInt32(greenShift)) & UInt32(greenMax)
        let bRaw = (rawValue >> UInt32(blueShift)) & UInt32(blueMax)
        let r = redMax == 255 ? UInt8(rRaw) : (redMax > 0 ? UInt8((rRaw * 255) / UInt32(redMax)) : 0)
        let g = greenMax == 255 ? UInt8(gRaw) : (greenMax > 0 ? UInt8((gRaw * 255) / UInt32(greenMax)) : 0)
        let b = blueMax == 255 ? UInt8(bRaw) : (blueMax > 0 ? UInt8((bRaw * 255) / UInt32(blueMax)) : 0)
        return (b, g, r, 0xFF)
    }
}

// MARK: - Server Init, Rectangles & Cursor

public struct RFBServerInit: Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: RFBPixelFormat
    public let name: String
}

public struct RFBRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RFBCursor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let bgraPixels: [UInt8]
}

// MARK: - Pointer & Keyboard

public struct RFBPointerButton: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = RFBPointerButton(rawValue: 1 << 0)
    public static let middle = RFBPointerButton(rawValue: 1 << 1)
    public static let right = RFBPointerButton(rawValue: 1 << 2)
    public static let scrollUp = RFBPointerButton(rawValue: 1 << 3)
    public static let scrollDown = RFBPointerButton(rawValue: 1 << 4)
    public static let scrollLeft = RFBPointerButton(rawValue: 1 << 5)
    public static let scrollRight = RFBPointerButton(rawValue: 1 << 6)
}

public enum RFBKeySym {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let leftArrow: UInt32 = 0xFF51
    public static let upArrow: UInt32 = 0xFF52
    public static let rightArrow: UInt32 = 0xFF53
    public static let downArrow: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let delete: UInt32 = 0xFFFF

    public static let f1: UInt32 = 0xFFBE
    public static let f2: UInt32 = 0xFFBF
    public static let f3: UInt32 = 0xFFC0
    public static let f4: UInt32 = 0xFFC1
    public static let f5: UInt32 = 0xFFC2
    public static let f6: UInt32 = 0xFFC3
    public static let f7: UInt32 = 0xFFC4
    public static let f8: UInt32 = 0xFFC5
    public static let f9: UInt32 = 0xFFC6
    public static let f10: UInt32 = 0xFFC7
    public static let f11: UInt32 = 0xFFC8
    public static let f12: UInt32 = 0xFFC9

    public static let shiftLeft: UInt32 = 0xFFE1
    public static let shiftRight: UInt32 = 0xFFE2
    public static let controlLeft: UInt32 = 0xFFE3
    public static let controlRight: UInt32 = 0xFFE4
    public static let metaLeft: UInt32 = 0xFFE7
    public static let altLeft: UInt32 = 0xFFE9
    public static let altRight: UInt32 = 0xFFEA
    public static let superLeft: UInt32 = 0xFFEB
    public static let superRight: UInt32 = 0xFFEC

    /// Apple Screen Sharing maps Super_L (0xFFEB) to Command (⌘).
    public static let macCommand: UInt32 = 0xFFEB
    public static let macOption: UInt32 = 0xFFE9
    public static let macControl: UInt32 = 0xFFE3
    public static let macShift: UInt32 = 0xFFE1

    public static let space: UInt32 = 0x0020

    public static func from(character: Character) -> UInt32? {
        switch character {
        case "\n", "\r": return returnKey
        case "\t": return tab
        case "\u{08}", "\u{7F}": return backSpace
        default:
            guard let scalar = character.unicodeScalars.first else { return nil }
            let val = scalar.value
            // Reject non-printable C0/C1 control characters rather than emitting invalid Unicode keysyms.
            if val < 0x20 || (val >= 0x7F && val < 0xA0) {
                return nil
            }
            if val <= 0x7E || val <= 0xFF {
                return val
            }
            return 0x0100_0000 | val
        }
    }

    #if canImport(UIKit)
    /// Maps a hardware `UIKey` into a stable X11 keysym.
    /// When Command, Control, or Option modifiers are active (or when mapping base shortcut keys),
    /// prefers `charactersIgnoringModifiers` so macOS receives the expected base key (e.g. `c` for ⌘C)
    /// and never sends transformed control/Option characters.
    @MainActor
    public static func from(key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return returnKey
        case .keyboardEscape: return escape
        case .keyboardDeleteOrBackspace: return backSpace
        case .keyboardDeleteForward: return delete
        case .keyboardTab: return tab
        case .keyboardSpacebar: return space
        case .keyboardLeftArrow: return leftArrow
        case .keyboardRightArrow: return rightArrow
        case .keyboardUpArrow: return upArrow
        case .keyboardDownArrow: return downArrow
        case .keyboardHome: return home
        case .keyboardEnd: return end
        case .keyboardPageUp: return pageUp
        case .keyboardPageDown: return pageDown
        case .keyboardF1: return f1
        case .keyboardF2: return f2
        case .keyboardF3: return f3
        case .keyboardF4: return f4
        case .keyboardF5: return f5
        case .keyboardF6: return f6
        case .keyboardF7: return f7
        case .keyboardF8: return f8
        case .keyboardF9: return f9
        case .keyboardF10: return f10
        case .keyboardF11: return f11
        case .keyboardF12: return f12
        case .keyboardLeftShift: return shiftLeft
        case .keyboardRightShift: return shiftRight
        case .keyboardLeftControl: return controlLeft
        case .keyboardRightControl: return controlRight
        case .keyboardLeftAlt: return altLeft
        case .keyboardRightAlt: return altRight
        case .keyboardLeftGUI: return superLeft
        case .keyboardRightGUI: return superRight
        default:
            let hasShortcutModifier = !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
            let preferredSource = hasShortcutModifier ? key.charactersIgnoringModifiers : key.characters
            if let ch = preferredSource.first, let sym = from(character: ch) {
                return sym
            }
            if let ch = key.charactersIgnoringModifiers.first, let sym = from(character: ch) {
                return sym
            }
            return nil
        }
    }
    #endif
}

// MARK: - Errors

public enum RFBError: LocalizedError, Sendable {
    case invalidAddress
    case connectionFailed(String)
    case connectionTimedOut
    case connectionClosed
    case invalidHandshake(String)
    case unsupportedSecurityTypes([UInt32])
    case preferredSecurityUnavailable(required: String, offered: [UInt8])
    case credentialsRequired(needsUsername: Bool)
    case authenticationFailed(String)
    case protocolError(String)
    case decompressionFailed(Int32)
    case cryptoFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Invalid host address or port."
        case .connectionFailed(let msg):
            return "Could not connect to Mac: \(msg)"
        case .connectionTimedOut:
            return "Connection timed out. Make sure your Mac is awake and Screen Sharing is enabled."
        case .connectionClosed:
            return "The remote Mac closed the connection."
        case .invalidHandshake(let detail):
            return "Invalid VNC handshake: \(detail)"
        case .unsupportedSecurityTypes(let types):
            return "No compatible authentication method offered by server (types: \(types)). Enable VNC password or macOS Screen Sharing."
        case .preferredSecurityUnavailable(let required, let offered):
            return "This profile requires \(required), which the Mac did not offer (server offered types: \(offered))."
        case .credentialsRequired(let needsUsername):
            return needsUsername
                ? "This Mac requires a macOS username and password to connect."
                : "This Mac requires a VNC password to connect."
        case .authenticationFailed(let reason):
            return reason.isEmpty ? "Authentication failed. Check your username or password." : "Authentication failed: \(reason)"
        case .protocolError(let detail):
            return "Protocol error: \(detail)"
        case .decompressionFailed(let code):
            return "Failed to decompress screen update (zlib error \(code))."
        case .cryptoFailed(let detail):
            return "Encryption error: \(detail)"
        }
    }
}
