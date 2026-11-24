import Foundation
import CoreGraphics
import Network
import Observation

public enum RFBConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case connected
    case disconnected(String?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var statusText: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .connected: return "Connected"
        case .disconnected(let reason):
            return reason ?? "Disconnected"
        }
    }
}

public struct RFBCredentials: Equatable, Hashable, Sendable {
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }
}

public struct RFBSessionStats: Equatable, Sendable {
    public var serverName: String = ""
    public var protocolVersion: String = ""
    public var securityMethod: String = ""
    public var lastEncoding: String = "—"
    public var resolution: CGSize = .zero
    public var framesPerSecond: Double = 0
    public var totalFrames: Int = 0
}

/// Complete native Swift RFB / VNC client supporting standard VNC (RFB 3.3 / 3.7 / 3.8)
/// and Apple Screen Sharing (RFB 3.889 + Apple Diffie-Hellman Auth Type 30).
/// All socket I/O, decompression, cryptography, and framebuffer decoding execute off the main thread.
@MainActor
@Observable
public final class RFBClient {
    public nonisolated static let maxStringLength = 65_536
    public nonisolated static let maxCutTextLength = 1_048_576
    public nonisolated static let maxCompressedRectLength = 64 * 1024 * 1024
    public nonisolated static let maxCursorDimension = 512

    public private(set) var state: RFBConnectionState = .idle
    public private(set) var stats = RFBSessionStats()
    public private(set) var currentImage: CGImage?
    public private(set) var remoteCursor: RFBCursor?
    public private(set) var hasServerCursorUpdate = false
    public private(set) var cursorGeneration: UInt64 = 0
    public private(set) var remoteClipboard: String = ""
    public private(set) var lastBellTimestamp: Date?

    /// Incremented whenever `currentImage` updates, allowing fast UIKit/CALayer redraws.
    public private(set) var frameGeneration: UInt64 = 0

    public var onFrameUpdated: ((CGImage) -> Void)?
    public var onServerCutText: ((String) -> Void)?
    public var onBell: (() -> Void)?

    private var sessionGeneration: UInt64 = 0
    private var sessionTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var writeContinuation: AsyncStream<Data>.Continuation?
    private var activeStream: RFBStream?
    private var currentFramebufferWidth: Int = 1
    private var currentFramebufferHeight: Int = 1
    private var heldPointerButtons: RFBPointerButton = []

    public init() {}

    // MARK: - Connection Lifecycle

    public func connect(
        host: String,
        port: UInt16 = 5900,
        credentials: RFBCredentials,
        authPreference: MacAuthPreference = .auto
    ) {
        disconnect()
        do {
            let transport = try RFBTCPTransport(host: host, port: port)
            startSession(transport: transport, credentials: credentials, authPreference: authPreference)
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    public func connect(
        endpoint: NWEndpoint,
        credentials: RFBCredentials,
        authPreference: MacAuthPreference = .auto
    ) {
        disconnect()
        let transport = RFBTCPTransport(endpoint: endpoint)
        startSession(transport: transport, credentials: credentials, authPreference: authPreference)
    }

    public func connect(
        transport: RFBTransport,
        credentials: RFBCredentials,
        authPreference: MacAuthPreference = .auto
    ) {
        disconnect()
        startSession(transport: transport, credentials: credentials, authPreference: authPreference)
    }

    public func disconnect(reason: String? = nil) {
        sessionGeneration &+= 1
        sessionTask?.cancel()
        sessionTask = nil
        writeContinuation?.finish()
        writeContinuation = nil
        writerTask?.cancel()
        writerTask = nil
        activeStream?.close()
        activeStream = nil
        heldPointerButtons = []
        state = reason != nil ? .disconnected(reason) : .idle
    }

    public func captureThumbnailJPEG(maxDimension: CGFloat = 640) -> Data? {
        #if canImport(UIKit)
        guard let img = currentImage else { return nil }
        return RFBFramebuffer.makeThumbnailJPEG(from: img, maxDimension: maxDimension)
        #else
        return nil
        #endif
    }

    // MARK: - Input Messages (strict FIFO order)

    public func sendPointerEvent(x: Int, y: Int, buttons: RFBPointerButton) {
        guard state.isConnected else { return }
        heldPointerButtons = buttons.subtracting([.scrollUp, .scrollDown, .scrollLeft, .scrollRight])
        enqueueWrite(Self.makePointerEventPacket(
            x: x,
            y: y,
            maxWidth: currentFramebufferWidth,
            maxHeight: currentFramebufferHeight,
            buttons: buttons
        ))
    }

    public func sendScroll(x: Int, y: Int, button: RFBPointerButton) {
        guard state.isConnected else { return }
        let pressed = heldPointerButtons.union(button)
        enqueueWrite(Self.makePointerEventPacket(
            x: x,
            y: y,
            maxWidth: currentFramebufferWidth,
            maxHeight: currentFramebufferHeight,
            buttons: pressed
        ))
        enqueueWrite(Self.makePointerEventPacket(
            x: x,
            y: y,
            maxWidth: currentFramebufferWidth,
            maxHeight: currentFramebufferHeight,
            buttons: heldPointerButtons
        ))
    }

    public func sendKeyEvent(keySym: UInt32, down: Bool) {
        guard state.isConnected else { return }
        var payload = Data(capacity: 8)
        payload.append(4) // KeyEvent
        payload.append(down ? 1 : 0)
        payload.append(0)
        payload.append(0)
        payload.append(UInt8((keySym >> 24) & 0xFF))
        payload.append(UInt8((keySym >> 16) & 0xFF))
        payload.append(UInt8((keySym >> 8) & 0xFF))
        payload.append(UInt8(keySym & 0xFF))
        enqueueWrite(payload)
    }

    public func sendKeyTap(keySym: UInt32, modifiers: [UInt32] = []) {
        for mod in modifiers {
            sendKeyEvent(keySym: mod, down: true)
        }
        sendKeyEvent(keySym: keySym, down: true)
        sendKeyEvent(keySym: keySym, down: false)
        for mod in modifiers.reversed() {
            sendKeyEvent(keySym: mod, down: false)
        }
    }

    public func sendText(_ text: String) {
        for char in text {
            if let sym = RFBKeySym.from(character: char) {
                sendKeyTap(keySym: sym)
            }
        }
    }

    /// Sends clipboard text per RFC 6143 (ISO-8859-1). Characters outside Latin-1
    /// are lossily substituted with `?` instead of sending invalid UTF-8 bytes.
    public func sendClientCutText(_ text: String) {
        guard state.isConnected else { return }
        let encoded = Self.encodeLatin1CutText(text)
        let length = UInt32(encoded.count)
        var payload = Data(capacity: 8 + encoded.count)
        payload.append(6) // ClientCutText
        payload.append(contentsOf: [0, 0, 0])
        payload.append(UInt8((length >> 24) & 0xFF))
        payload.append(UInt8((length >> 16) & 0xFF))
        payload.append(UInt8((length >> 8) & 0xFF))
        payload.append(UInt8(length & 0xFF))
        payload.append(encoded)
        enqueueWrite(payload)
    }

    public func requestFullRefresh() {
        guard state.isConnected else { return }
        enqueueWrite(Self.makeFramebufferUpdateRequest(
            incremental: false,
            x: 0,
            y: 0,
            width: currentFramebufferWidth,
            height: currentFramebufferHeight
        ))
    }

    // MARK: - Private Session Wiring

    private func startSession(
        transport: RFBTransport,
        credentials: RFBCredentials,
        authPreference: MacAuthPreference
    ) {
        sessionGeneration &+= 1
        let gen = sessionGeneration

        let newStream = RFBStream(transport: transport)
        self.activeStream = newStream
        self.state = .connecting
        self.stats = RFBSessionStats()
        self.currentImage = nil
        self.remoteCursor = nil
        self.hasServerCursorUpdate = false
        self.cursorGeneration &+= 1
        self.heldPointerButtons = []
        self.currentFramebufferWidth = 1
        self.currentFramebufferHeight = 1

        // Single FIFO AsyncStream guarantees exact wire order for all outbound packets.
        let (outboundStream, continuation) = AsyncStream<Data>.makeStream()
        self.writeContinuation = continuation
        self.writerTask = Task.detached(priority: .high) {
            for await packet in outboundStream {
                if Task.isCancelled { break }
                do {
                    try await newStream.write(packet)
                } catch {
                    newStream.close()
                    break
                }
            }
        }

        // All protocol I/O, crypto, zlib decompression, and framebuffer decoding run off MainActor.
        self.sessionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let worker = RFBSessionWorker(
                stream: newStream,
                credentials: credentials,
                authPreference: authPreference,
                enqueuePacket: { packet in
                    continuation.yield(packet)
                },
                onEvent: { [weak self] event in
                    await MainActor.run {
                        guard let self, self.sessionGeneration == gen else { return }
                        self.handleWorkerEvent(event)
                    }
                }
            )

            do {
                try await worker.run()
            } catch is CancellationError {
                // Clean disconnect.
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self, self.sessionGeneration == gen else { return }
                    self.writeContinuation?.finish()
                    self.writeContinuation = nil
                    self.writerTask?.cancel()
                    self.writerTask = nil
                    self.activeStream?.close()
                    self.activeStream = nil
                    self.state = .disconnected(message)
                }
            }
        }
    }

    private func handleWorkerEvent(_ event: RFBWorkerEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .metadataUpdated(let updatedStats, let fbWidth, let fbHeight):
            stats = updatedStats
            currentFramebufferWidth = fbWidth
            currentFramebufferHeight = fbHeight
        case .frameReady(let image, let updatedStats, let fbWidth, let fbHeight):
            currentFramebufferWidth = fbWidth
            currentFramebufferHeight = fbHeight
            currentImage = image
            frameGeneration &+= 1
            stats = updatedStats
            onFrameUpdated?(image)
        case .cursorUpdated(let cursor):
            remoteCursor = cursor
            hasServerCursorUpdate = true
            cursorGeneration &+= 1
        case .bell:
            lastBellTimestamp = Date()
            onBell?()
        case .serverCutText(let text):
            remoteClipboard = text
            onServerCutText?(text)
        }
    }

    private func enqueueWrite(_ data: Data) {
        writeContinuation?.yield(data)
    }

    // MARK: - Wire Packet Builders (Public for Testing)

    public nonisolated static func makePointerEventPacket(
        x: Int,
        y: Int,
        maxWidth: Int,
        maxHeight: Int,
        buttons: RFBPointerButton
    ) -> Data {
        let clampedX = UInt16(clamping: max(0, min(max(1, maxWidth) - 1, x)))
        let clampedY = UInt16(clamping: max(0, min(max(1, maxHeight) - 1, y)))
        var payload = Data(capacity: 6)
        payload.append(5) // PointerEvent
        payload.append(buttons.rawValue)
        payload.append(UInt8(clampedX >> 8))
        payload.append(UInt8(clampedX & 0xFF))
        payload.append(UInt8(clampedY >> 8))
        payload.append(UInt8(clampedY & 0xFF))
        return payload
    }

    public nonisolated static func makeFramebufferUpdateRequest(
        incremental: Bool,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Data {
        let ux = UInt16(clamping: x)
        let uy = UInt16(clamping: y)
        let uw = UInt16(clamping: width)
        let uh = UInt16(clamping: height)
        var data = Data(capacity: 10)
        data.append(3) // FramebufferUpdateRequest
        data.append(incremental ? 1 : 0)
        data.append(UInt8(ux >> 8))
        data.append(UInt8(ux & 0xFF))
        data.append(UInt8(uy >> 8))
        data.append(UInt8(uy & 0xFF))
        data.append(UInt8(uw >> 8))
        data.append(UInt8(uw & 0xFF))
        data.append(UInt8(uh >> 8))
        data.append(UInt8(uh & 0xFF))
        return data
    }

    public nonisolated static func encodeLatin1CutText(_ text: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(text.utf8.count, maxCutTextLength))
        for scalar in text.unicodeScalars {
            if bytes.count >= maxCutTextLength { break }
            if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            } else {
                bytes.append(0x3F) // '?'
            }
        }
        return Data(bytes)
    }

    /// Selects a security type obeying the user's explicit `MacAuthPreference` policy
    /// (preventing silent security downgrades) and validating credential presence before replying.
    public nonisolated static func selectSecurityType(
        offered: [UInt8],
        credentials: RFBCredentials,
        preference: MacAuthPreference
    ) throws -> RFBSecurityType {
        let hasUserAndPass = !credentials.username.isEmpty && !credentials.password.isEmpty
        let hasPass = !credentials.password.isEmpty

        switch preference {
        case .macOSAccount:
            guard offered.contains(RFBSecurityType.appleDiffieHellman.rawValue) else {
                throw RFBError.preferredSecurityUnavailable(required: preference.displayName, offered: offered)
            }
            guard hasUserAndPass else {
                throw RFBError.credentialsRequired(needsUsername: true)
            }
            return .appleDiffieHellman

        case .vncPassword:
            guard offered.contains(RFBSecurityType.vncAuthentication.rawValue) else {
                throw RFBError.preferredSecurityUnavailable(required: preference.displayName, offered: offered)
            }
            guard hasPass else {
                throw RFBError.credentialsRequired(needsUsername: false)
            }
            return .vncAuthentication

        case .none:
            guard offered.contains(RFBSecurityType.none.rawValue) else {
                throw RFBError.preferredSecurityUnavailable(required: preference.displayName, offered: offered)
            }
            return .none

        case .auto:
            if hasUserAndPass && offered.contains(RFBSecurityType.appleDiffieHellman.rawValue) {
                return .appleDiffieHellman
            }
            if hasPass && offered.contains(RFBSecurityType.vncAuthentication.rawValue) {
                return .vncAuthentication
            }
            if offered.contains(RFBSecurityType.none.rawValue) {
                return .none
            }
            if offered.contains(RFBSecurityType.appleDiffieHellman.rawValue) {
                throw RFBError.credentialsRequired(needsUsername: true)
            }
            if offered.contains(RFBSecurityType.vncAuthentication.rawValue) {
                throw RFBError.credentialsRequired(needsUsername: false)
            }
            throw RFBError.unsupportedSecurityTypes(offered.map { UInt32($0) })
        }
    }
}

// MARK: - Background RFB Session Worker

private enum RFBWorkerEvent: Sendable {
    case stateChanged(RFBConnectionState)
    case metadataUpdated(RFBSessionStats, Int, Int)
    case frameReady(CGImage, RFBSessionStats, Int, Int)
    case cursorUpdated(RFBCursor?)
    case bell
    case serverCutText(String)
}

private final class RFBSessionWorker {
    private let stream: RFBStream
    private let credentials: RFBCredentials
    private let authPreference: MacAuthPreference
    private let enqueuePacket: @Sendable (Data) -> Void
    private let onEvent: @Sendable (RFBWorkerEvent) async -> Void

    private var framebuffer = RFBFramebuffer(width: 1, height: 1)
    private let activePixelFormat = RFBPixelFormat.bgra32
    private var stats = RFBSessionStats()
    private var frameCounterWindowStart = Date()
    private var framesInWindow = 0

    init(
        stream: RFBStream,
        credentials: RFBCredentials,
        authPreference: MacAuthPreference,
        enqueuePacket: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (RFBWorkerEvent) async -> Void
    ) {
        self.stream = stream
        self.credentials = credentials
        self.authPreference = authPreference
        self.enqueuePacket = enqueuePacket
        self.onEvent = onEvent
    }

    func run() async throws {
        try await stream.connect()
        try Task.checkCancellation()

        // 1. ProtocolVersion Handshake (12 bytes: "RFB XXX.YYY\n")
        let versionData = try await stream.readExact(12)
        guard let versionString = String(data: versionData, encoding: .ascii),
              let serverVersion = RFBVersion(handshakeString: versionString) else {
            throw RFBError.invalidHandshake("Unexpected server version header.")
        }

        let clientVersion: RFBVersion
        if serverVersion.major == 3 && serverVersion.minor < 7 {
            clientVersion = .v3_3
        } else if serverVersion.major == 3 && serverVersion.minor == 7 {
            clientVersion = .v3_7
        } else {
            clientVersion = .v3_8
        }

        enqueuePacket(clientVersion.wireData)
        stats.protocolVersion = "RFB \(clientVersion) (server \(serverVersion))"
        await onEvent(.stateChanged(.authenticating))

        // 2. Security Negotiation (strictly enforcing authPreference & validating credentials before replying)
        let selectedSecurity: RFBSecurityType
        if clientVersion == .v3_3 {
            let secTypeRaw = try await stream.readUInt32BE()
            if secTypeRaw == 0 {
                let reason = try await readRFBString(maxLength: RFBClient.maxStringLength)
                throw RFBError.authenticationFailed(reason)
            }
            guard secTypeRaw <= UInt32(UInt8.max),
                  let parsed = RFBSecurityType(rawValue: UInt8(secTypeRaw)) else {
                throw RFBError.unsupportedSecurityTypes([secTypeRaw])
            }
            selectedSecurity = try RFBClient.selectSecurityType(
                offered: [parsed.rawValue],
                credentials: credentials,
                preference: authPreference
            )
        } else {
            let numTypes = Int(try await stream.readUInt8())
            if numTypes == 0 {
                let reason = try await readRFBString(maxLength: RFBClient.maxStringLength)
                throw RFBError.authenticationFailed(reason)
            }
            let offeredBytes = [UInt8](try await stream.readExact(numTypes))
            selectedSecurity = try RFBClient.selectSecurityType(
                offered: offeredBytes,
                credentials: credentials,
                preference: authPreference
            )
            enqueuePacket(Data([selectedSecurity.rawValue]))
        }

        stats.securityMethod = selectedSecurity.description

        // 3. Perform Security Handshake
        switch selectedSecurity {
        case .none:
            if clientVersion == .v3_8 {
                try await verifySecurityResult(version: clientVersion)
            }

        case .vncAuthentication:
            let challenge = try await stream.readExact(16)
            let response = try RFBCrypto.encryptVNCChallenge(challenge, password: credentials.password)
            enqueuePacket(response)
            try await verifySecurityResult(version: clientVersion)

        case .appleDiffieHellman:
            let generator = try await stream.readUInt16BE()
            let keyLength = Int(try await stream.readUInt16BE())
            guard keyLength >= RFBCrypto.minDHKeyLength, keyLength <= RFBCrypto.maxDHKeyLength else {
                throw RFBError.cryptoFailed("Server sent invalid Apple DH key length (\(keyLength) bytes).")
            }
            let primeData = try await stream.readExact(keyLength)
            let serverPubKey = try await stream.readExact(keyLength)
            let dhPayload = try RFBCrypto.appleDiffieHellmanPayload(
                generator: generator,
                primeData: primeData,
                serverPublicKeyData: serverPubKey,
                username: credentials.username,
                password: credentials.password
            )
            enqueuePacket(dhPayload)
            try await verifySecurityResult(version: clientVersion)

        default:
            throw RFBError.unsupportedSecurityTypes([UInt32(selectedSecurity.rawValue)])
        }

        // 4. ClientInit (shared = 1)
        enqueuePacket(Data([1]))

        // 5. ServerInit
        let initWidth = Int(try await stream.readUInt16BE())
        let initHeight = Int(try await stream.readUInt16BE())
        try RFBFramebuffer.validateDimensions(width: initWidth, height: initHeight)
        let serverPFData = try await stream.readExact(16)
        guard RFBPixelFormat(data: serverPFData) != nil else {
            throw RFBError.protocolError("Invalid ServerInit pixel format.")
        }
        let desktopName = try await readRFBString(maxLength: RFBClient.maxStringLength)

        framebuffer = RFBFramebuffer(width: initWidth, height: initHeight)
        stats.serverName = desktopName.isEmpty ? "Remote Mac" : desktopName
        stats.resolution = CGSize(width: initWidth, height: initHeight)

        // 6. SetPixelFormat -> Request native 32-bpp BGRA
        var setPF = Data(capacity: 20)
        setPF.append(0) // SetPixelFormat
        setPF.append(contentsOf: [0, 0, 0])
        setPF.append(RFBPixelFormat.bgra32.wireData)
        enqueuePacket(setPF)

        // 7. SetEncodings
        let encodings: [RFBEncoding] = [
            .zrle,
            .zlib,
            .copyRect,
            .hextile,
            .rre,
            .raw,
            .desktopSize,
            .extendedDesktopSize,
            .cursor,
            .lastRect
        ]
        var setEnc = Data(capacity: 4 + encodings.count * 4)
        setEnc.append(2) // SetEncodings
        setEnc.append(0)
        let encCount = UInt16(encodings.count)
        setEnc.append(UInt8(encCount >> 8))
        setEnc.append(UInt8(encCount & 0xFF))
        for enc in encodings {
            let bits = UInt32(bitPattern: enc.rawValue)
            setEnc.append(UInt8((bits >> 24) & 0xFF))
            setEnc.append(UInt8((bits >> 16) & 0xFF))
            setEnc.append(UInt8((bits >> 8) & 0xFF))
            setEnc.append(UInt8(bits & 0xFF))
        }
        enqueuePacket(setEnc)

        await onEvent(.metadataUpdated(stats, framebuffer.width, framebuffer.height))
        await onEvent(.stateChanged(.connected))

        // Request initial full frame
        enqueuePacket(RFBClient.makeFramebufferUpdateRequest(
            incremental: false,
            x: 0,
            y: 0,
            width: framebuffer.width,
            height: framebuffer.height
        ))

        let zlibInflater = try RFBZlibInflater()
        let zrleInflater = try RFBZlibInflater()

        // 8. Main Server-to-Client Message Loop
        while !Task.isCancelled {
            let msgType = try await stream.readUInt8()
            switch msgType {
            case 0:
                // FramebufferUpdate
                _ = try await stream.readUInt8()
                let rectCount = Int(try await stream.readUInt16BE())
                var frameChanged = false
                var resizeOccurred = false
                var lastEncodingName = stats.lastEncoding

                for _ in 0..<rectCount {
                    let x = Int(try await stream.readUInt16BE())
                    let y = Int(try await stream.readUInt16BE())
                    let w = Int(try await stream.readUInt16BE())
                    let h = Int(try await stream.readUInt16BE())
                    let encRaw = try await stream.readInt32BE()
                    let rect = RFBRect(x: x, y: y, width: w, height: h)

                    guard let encoding = RFBEncoding(rawValue: encRaw) else {
                        throw RFBError.protocolError("Server sent unsupported encoding type \(encRaw).")
                    }

                    if encoding == .lastRect {
                        break
                    }

                    switch encoding {
                    case .raw:
                        try framebuffer.validateRect(rect)
                        let byteCount = w * h * activePixelFormat.bytesPerPixel
                        let rawPixels = try await stream.readExact(byteCount)
                        framebuffer.blitRaw(rect: rect, data: rawPixels, pixelFormat: activePixelFormat)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .copyRect:
                        try framebuffer.validateRect(rect)
                        let srcX = Int(try await stream.readUInt16BE())
                        let srcY = Int(try await stream.readUInt16BE())
                        try framebuffer.validateRect(RFBRect(x: srcX, y: srcY, width: w, height: h))
                        framebuffer.copyRect(srcX: srcX, srcY: srcY, dstX: x, dstY: y, width: w, height: h)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .rre:
                        try framebuffer.validateRect(rect)
                        try await decodeRRERectangle(rect: rect)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .hextile:
                        try framebuffer.validateRect(rect)
                        try await decodeHextileRectangle(rect: rect)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .zlib:
                        try framebuffer.validateRect(rect)
                        let compressedLen = Int(try await stream.readUInt32BE())
                        guard compressedLen <= RFBClient.maxCompressedRectLength else {
                            throw RFBError.protocolError("Zlib rectangle length \(compressedLen) exceeds limit.")
                        }
                        let compressed = try await stream.readExact(compressedLen)
                        let expectedBytes = w * h * activePixelFormat.bytesPerPixel
                        let rawPixels = try zlibInflater.decompress(compressed, maxOutputBytes: expectedBytes)
                        guard rawPixels.count == expectedBytes else {
                            throw RFBError.protocolError("Zlib rectangle decompressed to \(rawPixels.count) bytes, expected \(expectedBytes).")
                        }
                        framebuffer.blitRaw(rect: rect, data: rawPixels, pixelFormat: activePixelFormat)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .zrle:
                        try framebuffer.validateRect(rect)
                        let compressedLen = Int(try await stream.readUInt32BE())
                        guard compressedLen <= RFBClient.maxCompressedRectLength else {
                            throw RFBError.protocolError("ZRLE rectangle length \(compressedLen) exceeds limit.")
                        }
                        let compressed = try await stream.readExact(compressedLen)
                        let tilesX = (w + 63) / 64
                        let tilesY = (h + 63) / 64
                        // Worst-case ZRLE uncompressed payload: 1 header byte per tile + raw pixels.
                        let maxZRLEOutput = (tilesX * tilesY) + (w * h * activePixelFormat.bytesPerPixel) + 1024
                        let decompressed = try zrleInflater.decompress(compressed, maxOutputBytes: maxZRLEOutput)
                        try framebuffer.decodeZRLE(rect: rect, decompressed: decompressed, pixelFormat: activePixelFormat)
                        lastEncodingName = encoding.description
                        frameChanged = true

                    case .desktopSize:
                        try framebuffer.resize(width: w, height: h)
                        stats.resolution = CGSize(width: w, height: h)
                        resizeOccurred = true

                    case .extendedDesktopSize:
                        let screenCount = Int(try await stream.readUInt8())
                        _ = try await stream.readExact(3)
                        if screenCount > 0 {
                            _ = try await stream.readExact(screenCount * 16)
                        }
                        try framebuffer.resize(width: w, height: h)
                        stats.resolution = CGSize(width: w, height: h)
                        resizeOccurred = true

                    case .cursor:
                        let cursor = try await decodeCursorPseudoEncoding(rect: rect)
                        await onEvent(.cursorUpdated(cursor))

                    case .lastRect:
                        break
                    }
                }

                stats.lastEncoding = lastEncodingName
                if frameChanged, let cgImage = framebuffer.makeCGImage() {
                    stats.totalFrames += 1
                    framesInWindow += 1
                    let now = Date()
                    let elapsed = now.timeIntervalSince(frameCounterWindowStart)
                    if elapsed >= 1.0 {
                        stats.framesPerSecond = Double(framesInWindow) / elapsed
                        framesInWindow = 0
                        frameCounterWindowStart = now
                    }
                    await onEvent(.frameReady(cgImage, stats, framebuffer.width, framebuffer.height))
                } else if resizeOccurred {
                    await onEvent(.metadataUpdated(stats, framebuffer.width, framebuffer.height))
                }

                enqueuePacket(RFBClient.makeFramebufferUpdateRequest(
                    incremental: !resizeOccurred,
                    x: 0,
                    y: 0,
                    width: framebuffer.width,
                    height: framebuffer.height
                ))

            case 1:
                // SetColourMapEntries
                _ = try await stream.readUInt8()
                _ = try await stream.readUInt16BE()
                let numColours = Int(try await stream.readUInt16BE())
                _ = try await stream.readExact(numColours * 6)

            case 2:
                // Bell
                await onEvent(.bell)

            case 3:
                // ServerCutText
                _ = try await stream.readExact(3)
                let length = Int(try await stream.readUInt32BE())
                guard length <= RFBClient.maxCutTextLength else {
                    throw RFBError.protocolError("ServerCutText length \(length) exceeds maximum allowed size.")
                }
                let textData = try await stream.readExact(length)
                let text = String(data: textData, encoding: .utf8)
                    ?? String(data: textData, encoding: .isoLatin1)
                    ?? ""
                await onEvent(.serverCutText(text))

            default:
                throw RFBError.protocolError("Unknown RFB server message type: \(msgType)")
            }
        }
    }

    private func verifySecurityResult(version: RFBVersion) async throws {
        let result = try await stream.readUInt32BE()
        if result == 0 { return }
        if version == .v3_8 {
            let reason = try await readRFBString(maxLength: RFBClient.maxStringLength)
            throw RFBError.authenticationFailed(reason)
        } else {
            throw RFBError.authenticationFailed("Server rejected credentials.")
        }
    }

    private func readRFBString(maxLength: Int) async throws -> String {
        let len = Int(try await stream.readUInt32BE())
        guard len <= maxLength else {
            throw RFBError.protocolError("Server string length \(len) exceeds maximum (\(maxLength)).")
        }
        guard len > 0 else { return "" }
        let data = try await stream.readExact(len)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
    }

    private func decodeRRERectangle(rect: RFBRect) async throws {
        let bpp = activePixelFormat.bytesPerPixel
        let numSubrects = Int(try await stream.readUInt32BE())
        guard numSubrects <= 1_000_000 else {
            throw RFBError.protocolError("Excessive RRE subrectangle count (\(numSubrects)).")
        }
        let bgData = try await stream.readExact(bpp)
        let bgVal = RFBFramebuffer.readPixelValue(from: [UInt8](bgData), at: 0, format: activePixelFormat)
        let bgBGRA = activePixelFormat.unpackToBGRA(bgVal)
        framebuffer.fillRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height, bgra: bgBGRA)

        for _ in 0..<numSubrects {
            let entry = [UInt8](try await stream.readExact(bpp + 8))
            let cVal = RFBFramebuffer.readPixelValue(from: entry, at: 0, format: activePixelFormat)
            let sx = Int((UInt16(entry[bpp]) << 8) | UInt16(entry[bpp + 1]))
            let sy = Int((UInt16(entry[bpp + 2]) << 8) | UInt16(entry[bpp + 3]))
            let sw = Int((UInt16(entry[bpp + 4]) << 8) | UInt16(entry[bpp + 5]))
            let sh = Int((UInt16(entry[bpp + 6]) << 8) | UInt16(entry[bpp + 7]))
            let bgra = activePixelFormat.unpackToBGRA(cVal)
            framebuffer.fillRect(x: rect.x + sx, y: rect.y + sy, width: sw, height: sh, bgra: bgra)
        }
    }

    private func decodeHextileRectangle(rect: RFBRect) async throws {
        let bpp = activePixelFormat.bytesPerPixel
        var bgColor: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0xFF)
        var fgColor: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 0xFF)

        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileH = min(16, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileW = min(16, rect.x + rect.width - tileX)
                let subencoding = try await stream.readUInt8()

                if (subencoding & 1) != 0 {
                    let raw = try await stream.readExact(tileW * tileH * bpp)
                    framebuffer.blitRaw(
                        rect: RFBRect(x: tileX, y: tileY, width: tileW, height: tileH),
                        data: raw,
                        pixelFormat: activePixelFormat
                    )
                } else {
                    if (subencoding & 2) != 0 {
                        let d = try await stream.readExact(bpp)
                        let v = RFBFramebuffer.readPixelValue(from: [UInt8](d), at: 0, format: activePixelFormat)
                        bgColor = activePixelFormat.unpackToBGRA(v)
                    }
                    framebuffer.fillRect(x: tileX, y: tileY, width: tileW, height: tileH, bgra: bgColor)

                    if (subencoding & 4) != 0 {
                        let d = try await stream.readExact(bpp)
                        let v = RFBFramebuffer.readPixelValue(from: [UInt8](d), at: 0, format: activePixelFormat)
                        fgColor = activePixelFormat.unpackToBGRA(v)
                    }

                    if (subencoding & 8) != 0 {
                        let subrectCount = Int(try await stream.readUInt8())
                        let subrectsColoured = (subencoding & 16) != 0
                        let recordSize = subrectsColoured ? (bpp + 2) : 2
                        let payload = [UInt8](try await stream.readExact(subrectCount * recordSize))
                        var offset = 0
                        for _ in 0..<subrectCount {
                            var color = fgColor
                            if subrectsColoured {
                                let v = RFBFramebuffer.readPixelValue(from: payload, at: offset, format: activePixelFormat)
                                color = activePixelFormat.unpackToBGRA(v)
                                offset += bpp
                            }
                            let xy = payload[offset]
                            let wh = payload[offset + 1]
                            offset += 2
                            let sx = Int((xy >> 4) & 0x0F)
                            let sy = Int(xy & 0x0F)
                            let sw = Int((wh >> 4) & 0x0F) + 1
                            let sh = Int(wh & 0x0F) + 1
                            framebuffer.fillRect(x: tileX + sx, y: tileY + sy, width: sw, height: sh, bgra: color)
                        }
                    }
                }
                tileX += 16
            }
            tileY += 16
        }
    }

    private func decodeCursorPseudoEncoding(rect: RFBRect) async throws -> RFBCursor? {
        let w = rect.width
        let h = rect.height
        guard w <= RFBClient.maxCursorDimension, h <= RFBClient.maxCursorDimension else {
            throw RFBError.protocolError("Cursor dimensions \(w)×\(h) exceed maximum (\(RFBClient.maxCursorDimension)).")
        }
        let bpp = activePixelFormat.bytesPerPixel
        let pixelByteCount = w * h * bpp
        let maskStride = (w + 7) / 8
        let maskByteCount = maskStride * h

        let pixelData = try await stream.readExact(pixelByteCount)
        let maskData = try await stream.readExact(maskByteCount)

        guard w > 0, h > 0 else {
            return nil
        }

        let srcBytes = [UInt8](pixelData)
        let maskBytes = [UInt8](maskData)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)

        for row in 0..<h {
            for col in 0..<w {
                let maskByte = maskBytes[row * maskStride + (col / 8)]
                let maskBit = (maskByte >> (7 - (col % 8))) & 1
                let dstIdx = (row * w + col) * 4
                if maskBit == 0 {
                    bgra[dstIdx] = 0
                    bgra[dstIdx + 1] = 0
                    bgra[dstIdx + 2] = 0
                    bgra[dstIdx + 3] = 0
                } else {
                    let srcIdx = (row * w + col) * bpp
                    let rawVal = RFBFramebuffer.readPixelValue(from: srcBytes, at: srcIdx, format: activePixelFormat)
                    let (b, g, r, _) = activePixelFormat.unpackToBGRA(rawVal)
                    bgra[dstIdx] = b
                    bgra[dstIdx + 1] = g
                    bgra[dstIdx + 2] = r
                    bgra[dstIdx + 3] = 0xFF
                }
            }
        }

        return RFBCursor(
            width: w,
            height: h,
            hotspotX: rect.x,
            hotspotY: rect.y,
            bgraPixels: bgra
        )
    }
}
