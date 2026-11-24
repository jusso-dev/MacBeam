import Foundation
import CommonCrypto
import CryptoKit
import Security

// MARK: - Arbitrary-Precision Unsigned Integer for Apple Diffie-Hellman (Type 30)

public struct BigUInt: Equatable, Comparable, Sendable {
    /// Little-endian 32-bit limbs (limbs[0] is least significant).
    private var limbs: [UInt32]

    public static let zero = BigUInt(limbs: [])
    public static let one = BigUInt(limbs: [1])

    public init(_ value: UInt64) {
        if value == 0 {
            self.limbs = []
        } else if value <= UInt64(UInt32.max) {
            self.limbs = [UInt32(value)]
        } else {
            self.limbs = [UInt32(truncatingIfNeeded: value), UInt32(value >> 32)]
        }
    }

    private init(limbs: [UInt32]) {
        var trimmed = limbs
        while let last = trimmed.last, last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    public init(bigEndianData data: Data) {
        var bytes = [UInt8](data)
        while bytes.first == 0 {
            bytes.removeFirst()
        }
        if bytes.isEmpty {
            self.init(limbs: [])
            return
        }
        var result: [UInt32] = []
        result.reserveCapacity((bytes.count + 3) / 4)
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var word: UInt32 = 0
            for idx in start..<i {
                word = (word << 8) | UInt32(bytes[idx])
            }
            result.append(word)
            i = start
        }
        self.init(limbs: result)
    }

    public func toBigEndianData(paddedTo byteCount: Int? = nil) -> Data {
        var bytes: [UInt8] = []
        if limbs.isEmpty {
            bytes = [0]
        } else {
            for limb in limbs.reversed() {
                bytes.append(UInt8((limb >> 24) & 0xFF))
                bytes.append(UInt8((limb >> 16) & 0xFF))
                bytes.append(UInt8((limb >> 8) & 0xFF))
                bytes.append(UInt8(limb & 0xFF))
            }
            while bytes.count > 1 && bytes.first == 0 {
                bytes.removeFirst()
            }
        }
        if let target = byteCount {
            if bytes.count < target {
                bytes = [UInt8](repeating: 0, count: target - bytes.count) + bytes
            } else if bytes.count > target {
                bytes = Array(bytes.suffix(target))
            }
        }
        return Data(bytes)
    }

    public var isZero: Bool { limbs.isEmpty }

    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    public var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    public func bit(at index: Int) -> Bool {
        let limbIndex = index / 32
        guard limbIndex < limbs.count else { return false }
        let bitOffset = index % 32
        return ((limbs[limbIndex] >> bitOffset) & 1) == 1
    }

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
        }
        return false
    }

    public static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        !(lhs < rhs)
    }

    /// Returns `self - rhs` when `self >= rhs`, otherwise `nil`.
    public func subtracting(_ rhs: BigUInt) -> BigUInt? {
        guard self >= rhs else { return nil }
        return BigUInt(limbs: BigUInt.subtract(self.limbs, rhs.limbs))
    }

    /// Assumes `a >= b`.
    private static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: a.count)
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let av = Int64(a[i])
            let bv = i < b.count ? Int64(b[i]) : 0
            var diff = av - bv - borrow
            if diff < 0 {
                diff += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out[i] = UInt32(diff)
        }
        while out.last == 0 { out.removeLast() }
        return out
    }

    private static func shiftLeftOne(_ a: [UInt32]) -> [UInt32] {
        if a.isEmpty { return [] }
        var out = [UInt32](repeating: 0, count: a.count + 1)
        var carry: UInt32 = 0
        for i in 0..<a.count {
            let v = a[i]
            out[i] = (v << 1) | carry
            carry = v >> 31
        }
        out[a.count] = carry
        while out.last == 0 { out.removeLast() }
        return out
    }

    private static func compareLimbs(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var ac = a.count
        while ac > 0 && a[ac - 1] == 0 { ac -= 1 }
        var bc = b.count
        while bc > 0 && b[bc - 1] == 0 { bc -= 1 }
        if ac != bc { return ac < bc ? -1 : 1 }
        for i in stride(from: ac - 1, through: 0, by: -1) {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        }
        return 0
    }

    public func modulo(_ modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "Modulo by zero")
        if self < modulus { return self }
        var rem: [UInt32] = []
        let modLimbs = modulus.limbs
        for bitIdx in stride(from: bitWidth - 1, through: 0, by: -1) {
            rem = BigUInt.shiftLeftOne(rem)
            if bit(at: bitIdx) {
                if rem.isEmpty {
                    rem = [1]
                } else {
                    rem[0] |= 1
                }
            }
            if BigUInt.compareLimbs(rem, modLimbs) >= 0 {
                rem = BigUInt.subtract(rem, modLimbs)
            }
        }
        return BigUInt(limbs: rem)
    }

    /// Computes `(self ^ exponent) mod modulus`.
    /// Uses CIOS Montgomery multiplication when `modulus` is odd (all DH primes),
    /// with a safe binary fallback for even moduli.
    public func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "Modulus must be non-zero")
        if modulus == .one { return .zero }
        if exponent.isZero { return .one }

        let baseReduced = self.modulo(modulus)
        if baseReduced.isZero { return .zero }

        if !modulus.isOdd {
            return modPowBinaryFallback(base: baseReduced, exponent: exponent, modulus: modulus)
        }

        let modLimbs = modulus.limbs
        let n = modLimbs.count

        // Compute -m[0]^(-1) mod 2^32 using Newton's method.
        let m0 = modLimbs[0]
        var inv: UInt32 = 1
        for _ in 0..<5 {
            inv = inv &* (2 &- m0 &* inv)
        }
        let n0Prime: UInt32 = 0 &- inv

        // Compute R^2 mod m by repeated doubling (2 * 32 * n steps).
        var r2: [UInt32] = [1]
        for _ in 0..<(2 * 32 * n) {
            r2 = BigUInt.shiftLeftOne(r2)
            if BigUInt.compareLimbs(r2, modLimbs) >= 0 {
                r2 = BigUInt.subtract(r2, modLimbs)
            }
        }

        func padded(_ arr: [UInt32]) -> [UInt32] {
            if arr.count >= n { return Array(arr.prefix(n)) }
            return arr + [UInt32](repeating: 0, count: n - arr.count)
        }

        func montMul(_ aIn: [UInt32], _ bIn: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0..<n {
                let ai = UInt64(aIn[i])
                var carry: UInt64 = 0
                for j in 0..<n {
                    let sum = UInt64(t[j]) + ai * UInt64(bIn[j]) + carry
                    t[j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                let s1 = UInt64(t[n]) + carry
                t[n] = UInt32(truncatingIfNeeded: s1)
                let s2 = UInt64(t[n + 1]) + (s1 >> 32)
                t[n + 1] = UInt32(truncatingIfNeeded: s2)

                let u = UInt64(t[0] &* n0Prime)
                var mCarry = (UInt64(t[0]) + u * UInt64(modLimbs[0])) >> 32
                for j in 1..<n {
                    let sum = UInt64(t[j]) + u * UInt64(modLimbs[j]) + mCarry
                    t[j - 1] = UInt32(truncatingIfNeeded: sum)
                    mCarry = sum >> 32
                }
                let m1 = UInt64(t[n]) + mCarry
                t[n - 1] = UInt32(truncatingIfNeeded: m1)
                t[n] = t[n + 1] &+ UInt32(m1 >> 32)
                t[n + 1] = 0
            }

            if t[n] != 0 || BigUInt.compareLimbs(Array(t[0..<n]), modLimbs) >= 0 {
                var borrow: Int64 = 0
                for i in 0..<n {
                    var diff = Int64(t[i]) - Int64(modLimbs[i]) - borrow
                    if diff < 0 {
                        diff += 1 << 32
                        borrow = 1
                    } else {
                        borrow = 0
                    }
                    t[i] = UInt32(diff)
                }
            }
            return Array(t[0..<n])
        }

        let r2Padded = padded(r2)
        let onePadded = padded([1])
        var montBase = montMul(padded(baseReduced.limbs), r2Padded)
        var montAcc = montMul(onePadded, r2Padded)

        for bitIdx in 0..<exponent.bitWidth {
            if exponent.bit(at: bitIdx) {
                montAcc = montMul(montAcc, montBase)
            }
            montBase = montMul(montBase, montBase)
        }

        let resultLimbs = montMul(montAcc, onePadded)
        return BigUInt(limbs: resultLimbs)
    }

    private func modPowBinaryFallback(base: BigUInt, exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var currentBase = base
        for bitIdx in 0..<exponent.bitWidth {
            if exponent.bit(at: bitIdx) {
                result = BigUInt.multiply(result, currentBase).modulo(modulus)
            }
            currentBase = BigUInt.multiply(currentBase, currentBase).modulo(modulus)
        }
        return result
    }

    private static func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return .zero }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let prod = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: prod)
                carry = prod >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }
}

// MARK: - VNC & Apple Screen Sharing Cryptography

public enum RFBCrypto {
    /// Allowed Apple DH key lengths (1024-bit to 4096-bit).
    public static let minDHKeyLength = 128
    public static let maxDHKeyLength = 512

    /// Reverses the bit order of a single byte (required by RFC 6143 VNC DES authentication).
    @inline(__always)
    public static func reverseBits(_ byte: UInt8) -> UInt8 {
        var b = byte
        b = ((b & 0xF0) >> 4) | ((b & 0x0F) << 4)
        b = ((b & 0xCC) >> 2) | ((b & 0x33) << 2)
        b = ((b & 0xAA) >> 1) | ((b & 0x55) << 1)
        return b
    }

    /// Truncates a UTF-8 string cleanly on Unicode scalar boundaries to at most `maxBytes`.
    public static func utf8PrefixSafe(_ string: String, maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(string.utf8.count, maxBytes))
        for scalar in string.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if out.count + bytes.count > maxBytes {
                break
            }
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// Encrypts the 16-byte RFB Security Type 2 (VNC Authentication) challenge using DES-ECB.
    public static func encryptVNCChallenge(_ challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16 else {
            throw RFBError.cryptoFailed("VNC challenge must be exactly 16 bytes.")
        }

        var keyBytes = [UInt8](repeating: 0, count: kCCKeySizeDES)
        let pwdBytes = Array(password.utf8)
        for i in 0..<min(pwdBytes.count, kCCKeySizeDES) {
            keyBytes[i] = reverseBits(pwdBytes[i])
        }

        var output = [UInt8](repeating: 0, count: 16)
        var numBytesEncrypted: size_t = 0

        let status = challenge.withUnsafeBytes { inPtr in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmDES),
                CCOptions(kCCOptionECBMode),
                keyBytes,
                kCCKeySizeDES,
                nil,
                inPtr.baseAddress,
                16,
                &output,
                output.count,
                &numBytesEncrypted
            )
        }

        guard status == kCCSuccess, numBytesEncrypted == 16 else {
            throw RFBError.cryptoFailed("DES-ECB encryption failed (status \(status)).")
        }

        return Data(output)
    }

    /// Computes the Apple Diffie-Hellman (Security Type 30) client payload:
    /// `AES-128-ECB(MD5(sharedSecret), username[64] + password[64]) + clientPublicKey[keyLength]`.
    /// Validates all untrusted server DH parameters before performing modular exponentiation.
    public static func appleDiffieHellmanPayload(
        generator: UInt16,
        primeData: Data,
        serverPublicKeyData: Data,
        username: String,
        password: String,
        privateKeyData: Data? = nil
    ) throws -> Data {
        let keyLength = primeData.count
        guard keyLength >= minDHKeyLength,
              keyLength <= maxDHKeyLength,
              serverPublicKeyData.count == keyLength else {
            throw RFBError.cryptoFailed("Server sent invalid Apple DH key length (\(keyLength) bytes).")
        }

        let p = BigUInt(bigEndianData: primeData)
        guard p.isOdd, p.bitWidth >= 1024, let pMinusOne = p.subtracting(.one) else {
            throw RFBError.cryptoFailed("Server sent an invalid or weak Apple DH prime modulus.")
        }

        let g = BigUInt(UInt64(generator))
        guard BigUInt.one < g, g < pMinusOne else {
            throw RFBError.cryptoFailed("Server sent an invalid Apple DH generator.")
        }

        let serverPub = BigUInt(bigEndianData: serverPublicKeyData)
        guard BigUInt.one < serverPub, serverPub < pMinusOne else {
            throw RFBError.cryptoFailed("Server sent an invalid Apple DH public key.")
        }

        let privBytes: Data
        if let provided = privateKeyData {
            privBytes = provided
        } else {
            privBytes = try randomBytes(count: keyLength)
        }
        var a = BigUInt(bigEndianData: privBytes)
        if a <= BigUInt.one {
            a = BigUInt(65537)
        }

        let clientPub = g.modPow(a, modulus: p)
        let sharedSecret = serverPub.modPow(a, modulus: p)
        guard BigUInt.one < sharedSecret, sharedSecret < pMinusOne else {
            throw RFBError.cryptoFailed("Derived Apple DH shared secret is degenerate.")
        }

        let clientPubData = clientPub.toBigEndianData(paddedTo: keyLength)
        let sharedSecretData = sharedSecret.toBigEndianData(paddedTo: keyLength)

        // Apple ARD derives the AES-128 key as MD5(sharedSecret).
        let aesKey = Array(Insecure.MD5.hash(data: sharedSecretData))

        // Build 128-byte credential buffer: 64 bytes username + 64 bytes password,
        // each null-terminated at a clean UTF-8 boundary and padded with random bytes after '\0'.
        var plain = [UInt8](try randomBytes(count: 128))
        let userBytes = utf8PrefixSafe(username, maxBytes: 63)
        for i in 0..<userBytes.count {
            plain[i] = userBytes[i]
        }
        plain[userBytes.count] = 0

        let passBytes = utf8PrefixSafe(password, maxBytes: 63)
        for i in 0..<passBytes.count {
            plain[64 + i] = passBytes[i]
        }
        plain[64 + passBytes.count] = 0

        var encrypted = [UInt8](repeating: 0, count: 128)
        var outLen: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionECBMode),
            aesKey,
            kCCKeySizeAES128,
            nil,
            plain,
            128,
            &encrypted,
            encrypted.count,
            &outLen
        )

        guard status == kCCSuccess, outLen == 128 else {
            throw RFBError.cryptoFailed("AES-128-ECB encryption failed (status \(status)).")
        }

        var payload = Data(capacity: 128 + keyLength)
        payload.append(contentsOf: encrypted)
        payload.append(clientPubData)
        return payload
    }

    public static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw RFBError.cryptoFailed("SecRandomCopyBytes failed (\(status)).")
        }
        return Data(bytes)
    }
}
