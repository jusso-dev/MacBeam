import Foundation
import CoreGraphics
import Network
#if canImport(UIKit)
import UIKit
#endif

/// A real, RFC 6143-compliant local loopback VNC server running on `127.0.0.1`.
/// Lets users immediately try MacBeam's live RFB streaming, trackpad cursor,
/// keyboard typing, and macOS desktop interactions without needing a Mac nearby,
/// and powers automated end-to-end RFB protocol tests.
public final class DemoMacVNCServer: @unchecked Sendable {
    public enum AuthMode: Sendable {
        case none
        case vncPassword(String)
    }

    public private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.macbeam.demo.vnc.server", qos: .userInitiated)
    private let authMode: AuthMode
    private let width: Int
    private let height: Int
    private let serverName: String
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var pendingStartContinuation: CheckedContinuation<UInt16, Error>?

    public init(
        width: Int = 1280,
        height: Int = 800,
        serverName: String = "Demo MacBook Pro",
        authMode: AuthMode = .none
    ) {
        self.width = width
        self.height = height
        self.serverName = serverName
        self.authMode = authMode
    }

    public func start() async throws -> UInt16 {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let newListener = try NWListener(using: params)
        self.listener = newListener

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pendingStartContinuation = continuation
                lock.unlock()

                newListener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let boundPort = newListener.port?.rawValue ?? 0
                        self.port = boundPort
                        self.resumeStart(with: .success(boundPort))
                    case .failed(let error):
                        self.resumeStart(with: .failure(error))
                    case .cancelled:
                        self.resumeStart(with: .failure(CancellationError()))
                    default:
                        break
                    }
                }

                newListener.newConnectionHandler = { [weak self] conn in
                    self?.handleNewConnection(conn)
                }

                newListener.start(queue: queue)
            }
        } onCancel: { [weak self] in
            self?.stop()
        }
    }

    public func stop() {
        resumeStart(with: .failure(CancellationError()))
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        lock.lock()
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        lock.unlock()
        for c in conns {
            c.cancel()
        }
    }

    private func resumeStart(with result: Result<UInt16, Error>) {
        lock.lock()
        let cont = pendingStartContinuation
        pendingStartContinuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        lock.lock()
        activeConnections[key] = connection
        lock.unlock()

        let session = DemoMacSession(
            connection: connection,
            width: width,
            height: height,
            serverName: serverName,
            authMode: authMode,
            queue: queue,
            onClosed: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.activeConnections.removeValue(forKey: key)
                self.lock.unlock()
            }
        )
        session.start()
    }
}

private final class DemoMacSession: @unchecked Sendable {
    private let connection: NWConnection
    private let width: Int
    private let height: Int
    private let serverName: String
    private let authMode: DemoMacVNCServer.AuthMode
    private let queue: DispatchQueue
    private let onClosed: @Sendable () -> Void

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    private var pointerX: Int
    private var pointerY: Int
    private var typedText: String = "Hello from MacBeam on iOS & iPadOS!"
    private var windowX: Int = 220
    private var windowY: Int = 130
    private var isDraggingWindow = false
    private var dragOffsetX = 0
    private var dragOffsetY = 0
    private var clickCount = 0
    private var supportsZlib = false
    private var zlibDeflater: RFBZlibDeflater?
    private var activeWallpaperIndex = 0
    private var needsRender = true

    init(
        connection: NWConnection,
        width: Int,
        height: Int,
        serverName: String,
        authMode: DemoMacVNCServer.AuthMode,
        queue: DispatchQueue,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.width = width
        self.height = height
        self.serverName = serverName
        self.authMode = authMode
        self.queue = queue
        self.onClosed = onClosed
        self.pointerX = width / 2
        self.pointerY = height / 2
    }

    func start() {
        connection.start(queue: queue)
        Task.detached {
            defer {
                self.connection.cancel()
                self.onClosed()
            }
            do {
                try await self.run()
            } catch {
                // Connection ended cleanly or errored.
            }
        }
    }

    private func run() async throws {
        // 1. Send Server ProtocolVersion
        try await send(RFBVersion.v3_8.wireData)
        _ = try await readExact(12)

        // 2. Security Types
        switch authMode {
        case .none:
            try await send(Data([1, RFBSecurityType.none.rawValue]))
            let chosen = try await readExact(1)[0]
            guard chosen == RFBSecurityType.none.rawValue else {
                try await send(Data([0, 0, 0, 1]))
                return
            }
            try await send(Data([0, 0, 0, 0]))

        case .vncPassword(let expectedPassword):
            try await send(Data([1, RFBSecurityType.vncAuthentication.rawValue]))
            let chosen = try await readExact(1)[0]
            guard chosen == RFBSecurityType.vncAuthentication.rawValue else {
                try await send(Data([0, 0, 0, 1]))
                return
            }
            let challenge = try RFBCrypto.randomBytes(count: 16)
            try await send(challenge)
            let clientResp = try await readExact(16)
            let expectedResp = try RFBCrypto.encryptVNCChallenge(challenge, password: expectedPassword)
            if clientResp == expectedResp {
                try await send(Data([0, 0, 0, 0]))
            } else {
                let reason = Data("Invalid VNC password".utf8)
                var fail = Data([0, 0, 0, 1])
                let len = UInt32(reason.count)
                fail.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
                fail.append(reason)
                try await send(fail)
                return
            }
        }

        // 3. ClientInit
        _ = try await readExact(1)

        // 4. ServerInit
        var serverInit = Data()
        let w = UInt16(width)
        let h = UInt16(height)
        serverInit.append(contentsOf: [UInt8(w >> 8), UInt8(w & 0xFF)])
        serverInit.append(contentsOf: [UInt8(h >> 8), UInt8(h & 0xFF)])
        serverInit.append(RFBPixelFormat.bgra32.wireData)
        let nameData = Data(serverName.utf8)
        let nameLen = UInt32(nameData.count)
        serverInit.append(contentsOf: [
            UInt8((nameLen >> 24) & 0xFF),
            UInt8((nameLen >> 16) & 0xFF),
            UInt8((nameLen >> 8) & 0xFF),
            UInt8(nameLen & 0xFF)
        ])
        serverInit.append(nameData)
        try await send(serverInit)

        zlibDeflater = try? RFBZlibDeflater(level: 1)

        // 5. Client-to-Server message loop
        while true {
            let msgType = try await readExact(1)[0]
            switch msgType {
            case 0: // SetPixelFormat
                _ = try await readExact(19)

            case 2: // SetEncodings
                _ = try await readExact(1)
                let countBytes = try await readExact(2)
                let count = Int((UInt16(countBytes[0]) << 8) | UInt16(countBytes[1]))
                let encData = try await readExact(count * 4)
                for i in 0..<count {
                    let off = i * 4
                    let raw = Int32(bitPattern:
                        (UInt32(encData[off]) << 24) |
                        (UInt32(encData[off + 1]) << 16) |
                        (UInt32(encData[off + 2]) << 8) |
                        UInt32(encData[off + 3])
                    )
                    if raw == RFBEncoding.zlib.rawValue { supportsZlib = true }
                }

            case 3: // FramebufferUpdateRequest
                let body = try await readExact(9)
                let incremental = body[0] != 0
                if incremental && !needsRender {
                    try await Task.sleep(for: .milliseconds(33))
                }
                needsRender = false
                try await sendRenderedFrame()

            case 4: // KeyEvent
                let body = try await readExact(7)
                let down = body[0] != 0
                let keySym = (UInt32(body[3]) << 24) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 8) | UInt32(body[6])
                if down {
                    handleKeyPress(keySym)
                    needsRender = true
                }

            case 5: // PointerEvent
                let body = try await readExact(5)
                let mask = RFBPointerButton(rawValue: body[0])
                let x = Int((UInt16(body[1]) << 8) | UInt16(body[2]))
                let y = Int((UInt16(body[3]) << 8) | UInt16(body[4]))
                handlePointer(x: x, y: y, mask: mask)
                needsRender = true

            case 6: // ClientCutText
                _ = try await readExact(3)
                let lenBytes = try await readExact(4)
                let len = Int((UInt32(lenBytes[0]) << 24) | (UInt32(lenBytes[1]) << 16) | (UInt32(lenBytes[2]) << 8) | UInt32(lenBytes[3]))
                if len > 0 && len <= RFBClient.maxCutTextLength {
                    let clipData = try await readExact(len)
                    if let str = String(data: clipData, encoding: .isoLatin1) ?? String(data: clipData, encoding: .utf8) {
                        typedText = str
                        needsRender = true
                    }
                }

            default:
                return
            }
        }
    }

    private func handleKeyPress(_ keySym: UInt32) {
        if keySym == RFBKeySym.backSpace {
            if !typedText.isEmpty { typedText.removeLast() }
        } else if keySym == RFBKeySym.returnKey {
            typedText.append("\n")
        } else if keySym >= 0x20 && keySym <= 0x7E, let scalar = UnicodeScalar(keySym) {
            typedText.append(Character(scalar))
            if typedText.count > 120 {
                typedText = String(typedText.suffix(120))
            }
        }
    }

    private func handlePointer(x: Int, y: Int, mask: RFBPointerButton) {
        pointerX = max(0, min(width - 1, x))
        pointerY = max(0, min(height - 1, y))

        let titleBarRect = CGRect(x: windowX, y: windowY, width: 760, height: 38)
        let wallpaperButtonRect = CGRect(x: windowX + 28, y: windowY + 370, width: 185, height: 36)

        if mask.contains(.left) {
            if !isDraggingWindow && titleBarRect.contains(CGPoint(x: pointerX, y: pointerY)) {
                isDraggingWindow = true
                dragOffsetX = pointerX - windowX
                dragOffsetY = pointerY - windowY
            } else if isDraggingWindow {
                windowX = max(16, min(width - 780, pointerX - dragOffsetX))
                windowY = max(36, min(height - 480, pointerY - dragOffsetY))
            } else if wallpaperButtonRect.contains(CGPoint(x: pointerX, y: pointerY)) {
                activeWallpaperIndex = (activeWallpaperIndex + 1) % 3
                clickCount += 1
            } else {
                clickCount += 1
            }
        } else {
            isDraggingWindow = false
        }
    }

    private func sendRenderedFrame() async throws {
        let rawBGRA = renderDesktopBGRA()

        var packet = Data()
        packet.append(0) // FramebufferUpdate
        packet.append(0) // padding
        packet.append(contentsOf: [0, 1]) // 1 rectangle
        let uw = UInt16(width)
        let uh = UInt16(height)
        packet.append(contentsOf: [0, 0, 0, 0])
        packet.append(contentsOf: [UInt8(uw >> 8), UInt8(uw & 0xFF)])
        packet.append(contentsOf: [UInt8(uh >> 8), UInt8(uh & 0xFF)])

        if supportsZlib, let deflater = zlibDeflater, let compressed = try? deflater.compress(rawBGRA) {
            let enc = UInt32(bitPattern: RFBEncoding.zlib.rawValue)
            packet.append(contentsOf: [UInt8(enc >> 24), UInt8((enc >> 16) & 0xFF), UInt8((enc >> 8) & 0xFF), UInt8(enc & 0xFF)])
            let len = UInt32(compressed.count)
            packet.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            packet.append(compressed)
        } else {
            let enc = UInt32(bitPattern: RFBEncoding.raw.rawValue)
            packet.append(contentsOf: [UInt8(enc >> 24), UInt8((enc >> 16) & 0xFF), UInt8((enc >> 8) & 0xFF), UInt8(enc & 0xFF)])
            packet.append(rawBGRA)
        }

        try await send(packet)
    }

    private func renderDesktopBGRA() -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        bytes.withUnsafeMutableBytes { rawBuf in
            guard let ctx = CGContext(
                data: rawBuf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return }

            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)

            let palettes: [[CGColor]] = [
                [CGColor(red: 0.08, green: 0.14, blue: 0.30, alpha: 1), CGColor(red: 0.24, green: 0.11, blue: 0.38, alpha: 1)],
                [CGColor(red: 0.05, green: 0.24, blue: 0.28, alpha: 1), CGColor(red: 0.09, green: 0.12, blue: 0.24, alpha: 1)],
                [CGColor(red: 0.28, green: 0.13, blue: 0.14, alpha: 1), CGColor(red: 0.13, green: 0.09, blue: 0.24, alpha: 1)]
            ]
            let colors = palettes[activeWallpaperIndex % palettes.count] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                    options: []
                )
            }

            // macOS Menu Bar
            ctx.setFillColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 0.85)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: 28))

            // Demo macOS Window
            let wx = CGFloat(windowX)
            let wy = CGFloat(windowY)
            let winRect = CGRect(x: wx, y: wy, width: 760, height: 430)
            let winPath = CGPath(roundedRect: winRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 32, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 0.96)
            ctx.addPath(winPath)
            ctx.fillPath()
            ctx.restoreGState()

            let titleRect = CGRect(x: wx, y: wy, width: 760, height: 38)
            ctx.setFillColor(red: 0.18, green: 0.19, blue: 0.23, alpha: 1)
            ctx.fill(titleRect)

            let dots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (wx + 20, 1.0, 0.37, 0.34),
                (wx + 40, 1.0, 0.74, 0.18),
                (wx + 60, 0.16, 0.79, 0.25)
            ]
            for (cx, r, g, b) in dots {
                ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
                ctx.fillEllipse(in: CGRect(x: cx - 6, y: wy + 13, width: 12, height: 12))
            }

            let notesBox = CGRect(x: wx + 28, y: wy + 72, width: 704, height: 270)
            ctx.setFillColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
            ctx.addPath(CGPath(roundedRect: notesBox, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()

            let btnRect = CGRect(x: wx + 28, y: wy + 370, width: 185, height: 36)
            ctx.setFillColor(red: 0.04, green: 0.48, blue: 1.0, alpha: 1)
            ctx.addPath(CGPath(roundedRect: btnRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()

            #if canImport(UIKit)
            UIGraphicsPushContext(ctx)
            let clockText = Self.clockFormatter.string(from: Date())

            let menuAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            NSString(string: "  Finder   File   Edit   View   Window   Help").draw(at: CGPoint(x: 16, y: 6), withAttributes: menuAttrs)
            NSString(string: "VNC Loopback  •  \(clockText)").draw(at: CGPoint(x: CGFloat(width) - 245, y: 6), withAttributes: menuAttrs)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor(white: 0.92, alpha: 1)
            ]
            NSString(string: "Demo MacBook Pro — Interactive VNC Sandbox (Drag this title bar)").draw(
                at: CGPoint(x: wx + 90, y: wy + 10),
                withAttributes: titleAttrs
            )

            let headingAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            NSString(string: "Live RFB 3.8 Session Active").draw(
                at: CGPoint(x: wx + 46, y: wy + 92),
                withAttributes: headingAttrs
            )

            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .foregroundColor: UIColor(red: 0.52, green: 0.88, blue: 1.0, alpha: 1)
            ]
            let infoText = """
            Pointer: (\(pointerX), \(pointerY))  •  Clicks: \(clickCount)
            Transport: Real TCP RFB 3.8 + Zlib Compression
            Try moving the cursor, dragging the title bar, or typing:

            > \(typedText)_
            """
            NSString(string: infoText).draw(
                in: CGRect(x: wx + 46, y: wy + 132, width: 668, height: 195),
                withAttributes: bodyAttrs
            )

            let btnAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            NSString(string: "Switch Wallpaper").draw(at: CGPoint(x: wx + 60, y: wy + 379), withAttributes: btnAttrs)
            UIGraphicsPopContext()
            #endif

            let dockW: CGFloat = 420
            let dockRect = CGRect(x: (CGFloat(width) - dockW) / 2, y: CGFloat(height) - 74, width: dockW, height: 58)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.16)
            ctx.addPath(CGPath(roundedRect: dockRect, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.fillPath()

            let dockColors: [(CGFloat, CGFloat, CGFloat)] = [
                (0.18, 0.58, 0.98), (0.98, 0.36, 0.34), (0.20, 0.80, 0.45),
                (0.99, 0.72, 0.16), (0.64, 0.40, 0.96), (0.28, 0.82, 0.85)
            ]
            for (idx, c) in dockColors.enumerated() {
                let ix = dockRect.minX + 24 + CGFloat(idx) * 64
                let iy = dockRect.minY + 9
                ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                ctx.addPath(CGPath(roundedRect: CGRect(x: ix, y: iy, width: 42, height: 42), cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.fillPath()
            }

            let cx = CGFloat(pointerX)
            let cy = CGFloat(pointerY)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 20))
            ctx.addLine(to: CGPoint(x: cx + 5, y: cy + 15))
            ctx.addLine(to: CGPoint(x: cx + 10, y: cy + 23))
            ctx.addLine(to: CGPoint(x: cx + 13, y: cy + 21))
            ctx.addLine(to: CGPoint(x: cx + 8, y: cy + 13))
            ctx.addLine(to: CGPoint(x: cx + 15, y: cy + 13))
            ctx.closePath()
            ctx.setFillColor(gray: 0.05, alpha: 1)
            ctx.setStrokeColor(gray: 1.0, alpha: 1)
            ctx.setLineWidth(1.8)
            ctx.drawPath(using: .fillStroke)
        }

        return Data(bytes)
    }

    private var rxBuffer = Data()

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while rxBuffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: RFBError.connectionClosed)
                    } else {
                        continuation.resume(throwing: RFBError.connectionClosed)
                    }
                }
            }
            rxBuffer.append(chunk)
        }
        let slice = Data(rxBuffer.prefix(count))
        rxBuffer.removeFirst(count)
        return slice
    }
}
