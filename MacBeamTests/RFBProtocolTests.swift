import XCTest
import CommonCrypto
import CryptoKit
@testable import MacBeam

final class RFBProtocolTests: XCTestCase {

    // RFC 2409 Oakley Group 2 (1024-bit safe prime)
    private let oakleyGroup2PrimeHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
        "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
        "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381" +
        "FFFFFFFFFFFFFFFF"

    // MARK: - Protocol Version & Pixel Format

    func testRFBVersionParsingAndWireEncoding() {
        XCTAssertEqual(RFBVersion(handshakeString: "RFB 003.008\n"), .v3_8)
        XCTAssertEqual(RFBVersion(handshakeString: "RFB 003.889\n"), .apple3_889)
        XCTAssertEqual(RFBVersion(handshakeString: "RFB 003.003\n"), .v3_3)
        XCTAssertNil(RFBVersion(handshakeString: "HTTP/1.1 200"))
        XCTAssertEqual(String(data: RFBVersion.v3_8.wireData, encoding: .ascii), "RFB 003.008\n")
    }

    func testPixelFormatRoundTripAndUnpack() {
        let pf = RFBPixelFormat.bgra32
        let decoded = RFBPixelFormat(data: pf.wireData)
        XCTAssertEqual(decoded, pf)
        XCTAssertTrue(pf.isNativeBGRA32)

        let (b, g, r, a) = pf.unpackToBGRA(0x0012_3456)
        XCTAssertEqual(r, 0x12)
        XCTAssertEqual(g, 0x34)
        XCTAssertEqual(b, 0x56)
        XCTAssertEqual(a, 0xFF)

        let rgb565 = RFBPixelFormat(
            bitsPerPixel: 16,
            depth: 16,
            bigEndianFlag: 0,
            trueColourFlag: 1,
            redMax: 31,
            greenMax: 63,
            blueMax: 31,
            redShift: 11,
            greenShift: 5,
            blueShift: 0
        )
        let pureRed = rgb565.unpackToBGRA(31 << 11)
        XCTAssertEqual(pureRed.2, 255)
        XCTAssertEqual(pureRed.1, 0)
        XCTAssertEqual(pureRed.0, 0)
    }

    // MARK: - VNC DES Independent Known-Answer Vector & Apple DH Crypto

    func testVNCDESKnownAnswerVectorFromOpenSSL() throws {
        // Independent OpenSSL vector:
        // challenge = 000102030405060708090a0b0c0d0e0f, password = "secret"
        // bit-reversed DES key = cea6c64ea62e0000
        // openssl enc -des-ecb -nopad -K cea6c64ea62e0000 => ee22539f33a5983ec12f9c2edbc995dd
        let challenge = Data((0..<16).map { UInt8($0) })
        let actual = try RFBCrypto.encryptVNCChallenge(challenge, password: "secret")
        let expected = try hexToData("ee22539f33a5983ec12f9c2edbc995dd")
        XCTAssertEqual(actual, expected)

        // Verify RFC 6143 8-byte password truncation
        let respLong = try RFBCrypto.encryptVNCChallenge(challenge, password: "macpassword123")
        let resp8 = try RFBCrypto.encryptVNCChallenge(challenge, password: "macpassw")
        XCTAssertEqual(respLong, resp8)
    }

    func testBigUIntModularExponentiationSmallAnd1024BitDH() throws {
        let small = BigUInt(4).modPow(BigUInt(13), modulus: BigUInt(497))
        XCTAssertEqual(small, BigUInt(445))

        let primeData = try hexToData(oakleyGroup2PrimeHex)
        let p = BigUInt(bigEndianData: primeData)
        let g = BigUInt(2)
        let a = BigUInt(bigEndianData: try RFBCrypto.randomBytes(count: 128))
        let b = BigUInt(bigEndianData: try RFBCrypto.randomBytes(count: 128))

        let clientPub = g.modPow(a, modulus: p)
        let serverPub = g.modPow(b, modulus: p)
        XCTAssertEqual(serverPub.modPow(a, modulus: p), clientPub.modPow(b, modulus: p))
    }

    func testAppleDiffieHellmanRoundTripAndMalformedParameterRejection() throws {
        let primeData = try hexToData(oakleyGroup2PrimeHex)
        let p = BigUInt(bigEndianData: primeData)
        let g = BigUInt(2)
        let serverPriv = BigUInt(bigEndianData: Data(repeating: 0x37, count: 128))
        let serverPubData = g.modPow(serverPriv, modulus: p).toBigEndianData(paddedTo: 128)
        let deterministicClientPriv = Data(repeating: 0x5A, count: 128)

        let payload = try RFBCrypto.appleDiffieHellmanPayload(
            generator: 2,
            primeData: primeData,
            serverPublicKeyData: serverPubData,
            username: "justin",
            password: "super-secret-mac-pass",
            privateKeyData: deterministicClientPriv
        )

        XCTAssertEqual(payload.count, 256)
        let encryptedCreds = Data(payload.prefix(128))
        let clientPubData = Data(payload.suffix(128))

        let clientPub = BigUInt(bigEndianData: clientPubData)
        let serverSharedData = clientPub.modPow(serverPriv, modulus: p).toBigEndianData(paddedTo: 128)
        let aesKey = Array(Insecure.MD5.hash(data: serverSharedData))

        var decrypted = [UInt8](repeating: 0, count: 128)
        var outLen: size_t = 0
        let status = encryptedCreds.withUnsafeBytes { inPtr in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionECBMode),
                aesKey,
                kCCKeySizeAES128,
                nil,
                inPtr.baseAddress,
                128,
                &decrypted,
                decrypted.count,
                &outLen
            )
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        XCTAssertEqual(outLen, 128)

        let userSlice = decrypted[0..<64].prefix { $0 != 0 }
        let passSlice = decrypted[64..<128].prefix { $0 != 0 }
        XCTAssertEqual(String(bytes: userSlice, encoding: .utf8), "justin")
        XCTAssertEqual(String(bytes: passSlice, encoding: .utf8), "super-secret-mac-pass")

        // C1 Malformed DH parameter rejections (must throw, NEVER trap)
        XCTAssertThrowsError(try RFBCrypto.appleDiffieHellmanPayload(
            generator: 2,
            primeData: Data([0x00]),
            serverPublicKeyData: Data([0x01]),
            username: "u",
            password: "p"
        ))
        XCTAssertThrowsError(try RFBCrypto.appleDiffieHellmanPayload(
            generator: 1, // invalid generator <= 1
            primeData: primeData,
            serverPublicKeyData: serverPubData,
            username: "u",
            password: "p"
        ))
        XCTAssertThrowsError(try RFBCrypto.appleDiffieHellmanPayload(
            generator: 2,
            primeData: primeData,
            serverPublicKeyData: Data(repeating: 0, count: 127) + Data([1]), // serverPub == 1
            username: "u",
            password: "p"
        ))

        // Multi-byte UTF-8 boundary-safe truncation
        let emojiString = String(repeating: "😀", count: 20) // 80 UTF-8 bytes
        let safePrefix = RFBCrypto.utf8PrefixSafe(emojiString, maxBytes: 63)
        XCTAssertEqual(safePrefix.count, 60) // 15 complete 4-byte scalars, never split mid-character
        XCTAssertNotNil(String(bytes: safePrefix, encoding: .utf8))
    }

    // MARK: - Auth Policy Enforcement (No Silent Downgrades)

    func testAuthPreferenceStrictEnforcement() throws {
        let creds = RFBCredentials(username: "justin", password: "secret")

        // Explicit macOS account refuses downgrade to None or VNC DES
        XCTAssertThrowsError(try RFBClient.selectSecurityType(
            offered: [RFBSecurityType.none.rawValue, RFBSecurityType.vncAuthentication.rawValue],
            credentials: creds,
            preference: .macOSAccount
        ))

        // Explicit VNC password refuses downgrade to None or Apple DH
        XCTAssertThrowsError(try RFBClient.selectSecurityType(
            offered: [RFBSecurityType.none.rawValue, RFBSecurityType.appleDiffieHellman.rawValue],
            credentials: creds,
            preference: .vncPassword
        ))

        // Explicit macOS account succeeds when Type 30 is offered
        let chosen = try RFBClient.selectSecurityType(
            offered: [RFBSecurityType.vncAuthentication.rawValue, RFBSecurityType.appleDiffieHellman.rawValue],
            credentials: creds,
            preference: .macOSAccount
        )
        XCTAssertEqual(chosen, .appleDiffieHellman)

        // Missing credentials checked before replying
        XCTAssertThrowsError(try RFBClient.selectSecurityType(
            offered: [RFBSecurityType.vncAuthentication.rawValue],
            credentials: RFBCredentials(),
            preference: .auto
        ))
    }

    // MARK: - Streaming Zlib, Zip-Bomb Ceiling, Framebuffer Bounds & Encodings

    func testPersistentZlibStreamAndOutputCap() throws {
        let deflater = try RFBZlibDeflater()
        let inflater = try RFBZlibInflater()

        let chunk1 = Data("First framebuffer rectangle payload!".utf8)
        let chunk2 = Data(repeating: 0xAB, count: 8192)

        let comp1 = try deflater.compress(chunk1)
        let comp2 = try deflater.compress(chunk2)

        XCTAssertEqual(try inflater.decompress(comp1, maxOutputBytes: 1024), chunk1)
        // Zip-bomb ceiling must reject output larger than maxOutputBytes
        XCTAssertThrowsError(try inflater.decompress(comp2, maxOutputBytes: 1024))
    }

    func testFramebufferBoundsValidationCopyRectZRLEAndCursor() throws {
        XCTAssertThrowsError(try RFBFramebuffer.validateDimensions(width: 65535, height: 65535))
        XCTAssertThrowsError(try RFBFramebuffer.validateDimensions(width: 0, height: 100))

        let fb = RFBFramebuffer(width: 8, height: 8)
        XCTAssertThrowsError(try fb.validateRect(RFBRect(x: 5, y: 0, width: 4, height: 4)))

        // CopyRect
        fb.fillRect(x: 0, y: 0, width: 4, height: 4, bgra: (10, 20, 30, 255))
        fb.copyRect(srcX: 0, srcY: 0, dstX: 4, dstY: 4, width: 4, height: 4)
        let idx = (5 * 8 + 5) * 4
        XCTAssertEqual(fb.pixels[idx], 10)
        XCTAssertEqual(fb.pixels[idx + 1], 20)
        XCTAssertEqual(fb.pixels[idx + 2], 30)

        // ZRLE Solid Tile (subencoding = 1)
        let zrleSolid = Data([1, 0x11, 0x22, 0x33])
        try fb.decodeZRLE(rect: RFBRect(x: 0, y: 0, width: 4, height: 4), decompressed: zrleSolid, pixelFormat: .bgra32)
        XCTAssertEqual(fb.pixels[0], 0x11)
        XCTAssertEqual(fb.pixels[1], 0x22)
        XCTAssertEqual(fb.pixels[2], 0x33)

        // ZRLE Packed Palette Tile (subencoding = 2 -> 1 bit/pixel, 2 colors) for 2x2 rect
        // Palette: index 0 = (1,2,3), index 1 = (9,8,7); Row 0: 10 -> 0x80; Row 1: 01 -> 0x40
        let zrlePacked = Data([2, 1, 2, 3, 9, 8, 7, 0x80, 0x40])
        try fb.decodeZRLE(rect: RFBRect(x: 0, y: 0, width: 2, height: 2), decompressed: zrlePacked, pixelFormat: .bgra32)
        XCTAssertEqual(fb.pixels[0], 9) // (0,0) = index 1
        XCTAssertEqual(fb.pixels[4], 1) // (1,0) = index 0
        XCTAssertEqual(fb.pixels[8 * 4], 1) // (0,1) = index 0
        XCTAssertEqual(fb.pixels[8 * 4 + 4], 9) // (1,1) = index 1

        // ZRLE Palette RLE Tile (subencoding = 0x82 -> RLE with 2-color palette) for 2x2 rect
        // Palette: index 0 = (5,6,7), index 1 = (15,16,17)
        // Run 1: index 1 with length 2 (0x81, 0x01); Run 2: single index 0 (0x00); Run 3: single index 1 (0x01)
        let zrlePaletteRLE = Data([0x82, 5, 6, 7, 15, 16, 17, 0x81, 0x01, 0x00, 0x01])
        try fb.decodeZRLE(rect: RFBRect(x: 2, y: 0, width: 2, height: 2), decompressed: zrlePaletteRLE, pixelFormat: .bgra32)
        XCTAssertEqual(fb.pixels[2 * 4], 15) // (2,0)
        XCTAssertEqual(fb.pixels[3 * 4], 15) // (3,0)
        XCTAssertEqual(fb.pixels[(8 + 2) * 4], 5) // (2,1)
        XCTAssertEqual(fb.pixels[(8 + 3) * 4], 15) // (3,1)

        // Cursor CGImage generation
        let cursor = RFBCursor(width: 2, height: 2, hotspotX: 0, hotspotY: 0, bgraPixels: [UInt8](repeating: 0xFF, count: 16))
        XCTAssertNotNil(RFBFramebuffer.makeCursorCGImage(from: cursor))
        XCTAssertNotNil(fb.makeCGImage())
    }

    // MARK: - Input Sanitization & Profile Sort Transitivity

    func testLatin1CutTextAndControlKeySymFiltering() {
        let encoded = RFBClient.encodeLatin1CutText("Hello café 🚀")
        let decoded = String(data: encoded, encoding: .isoLatin1)
        XCTAssertEqual(decoded, "Hello café ?")

        XCTAssertNil(RFBKeySym.from(character: "\u{01}"))
        XCTAssertEqual(RFBKeySym.from(character: "\n"), RFBKeySym.returnKey)
        XCTAssertEqual(RFBKeySym.from(character: "A"), 0x41)
    }

    func testProfileSortingIsStrictlyTransitive() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)
        let a = MacConnectionProfile(name: "Alpha", host: "a.local", lastConnectedAt: nil)
        let b = MacConnectionProfile(name: "Beta", host: "b.local", lastConnectedAt: earlier)
        let c = MacConnectionProfile(name: "Gamma", host: "c.local", lastConnectedAt: now)
        let fav = MacConnectionProfile(name: "Zulu", host: "z.local", isFavorite: true, lastConnectedAt: nil)

        let sorted = ConnectionLibraryStore.sortProfiles([a, b, c, fav])
        XCTAssertEqual(sorted.map(\.name), ["Zulu", "Gamma", "Beta", "Alpha"])
    }

    // MARK: - Live Loopback RFB 3.8 Integration Test (VNC Auth + Reconnect Isolation)

    @MainActor
    func testEndToEndRFBClientConnectsReceivesFramesAndHandlesReconnect() async throws {
        let server = DemoMacVNCServer(
            width: 320,
            height: 200,
            serverName: "Test Studio Mac",
            authMode: .vncPassword("testpass")
        )
        let port = try await server.start()
        defer { server.stop() }

        let client = RFBClient()
        defer { client.disconnect() }

        let frameExp = expectation(description: "Receive first framebuffer image")
        var fulfilled = false
        client.onFrameUpdated = { _ in
            if !fulfilled {
                fulfilled = true
                frameExp.fulfill()
            }
        }

        client.connect(
            host: "127.0.0.1",
            port: port,
            credentials: RFBCredentials(username: "", password: "testpass"),
            authPreference: .vncPassword
        )

        await fulfillment(of: [frameExp], timeout: 5.0)

        XCTAssertTrue(client.state.isConnected)
        XCTAssertEqual(client.stats.serverName, "Test Studio Mac")
        XCTAssertEqual(client.stats.resolution, CGSize(width: 320, height: 200))
        XCTAssertEqual(client.currentImage?.width, 320)
        XCTAssertEqual(client.currentImage?.height, 200)

        client.sendPointerEvent(x: 120, y: 80, buttons: .left)
        client.sendScroll(x: 120, y: 80, button: .scrollDown)
        client.sendPointerEvent(x: 120, y: 80, buttons: [])
        client.sendText("Hi")

        // Verify immediate reconnect while connected does NOT get killed by the dying prior session (H2)
        let reconnectExp = expectation(description: "Receive frame on reconnected session")
        var reconnected = false
        client.onFrameUpdated = { _ in
            if !reconnected {
                reconnected = true
                reconnectExp.fulfill()
            }
        }
        client.connect(
            host: "127.0.0.1",
            port: port,
            credentials: RFBCredentials(username: "", password: "testpass"),
            authPreference: .vncPassword
        )
        await fulfillment(of: [reconnectExp], timeout: 5.0)
        XCTAssertTrue(client.state.isConnected)
    }

    // MARK: - Helpers

    private func hexToData(_ hex: String) throws -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteStr = hex[index..<nextIndex]
            guard let byte = UInt8(byteStr, radix: 16) else {
                throw NSError(domain: "HexError", code: 1)
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
