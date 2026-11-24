import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// High-performance 32-bpp BGRA framebuffer supporting all core RFB encodings
/// (Raw, CopyRect, RRE, Hextile, Zlib, ZRLE) with strict dimension bounds
/// and CoreGraphics image generation.
public final class RFBFramebuffer {
    public static let maxDimension = 16_384
    public static let maxPixelCount = 64_000_000

    public private(set) var width: Int
    public private(set) var height: Int
    /// Tightly packed BGRA bytes (4 bytes per pixel).
    public private(set) var pixels: [UInt8]

    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    public static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= maxDimension, height <= maxDimension,
              Int64(width) * Int64(height) <= Int64(maxPixelCount) else {
            throw RFBError.protocolError("Invalid framebuffer dimensions \(width)×\(height).")
        }
    }

    public func validateRect(_ rect: RFBRect) throws {
        guard rect.x >= 0, rect.y >= 0,
              rect.width >= 0, rect.height >= 0,
              rect.x + rect.width <= width,
              rect.y + rect.height <= height else {
            throw RFBError.protocolError("Rectangle (\(rect.x),\(rect.y) \(rect.width)×\(rect.height)) exceeds framebuffer \(width)×\(height).")
        }
    }

    public init(width: Int, height: Int) {
        let safeW = max(1, min(Self.maxDimension, width))
        let safeH = max(1, min(Self.maxDimension, height))
        self.width = safeW
        self.height = safeH
        self.pixels = [UInt8](repeating: 0, count: safeW * safeH * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 0xFF
        }
    }

    public func resize(width newWidth: Int, height newHeight: Int) throws {
        try Self.validateDimensions(width: newWidth, height: newHeight)
        guard newWidth != width || newHeight != height else { return }
        width = newWidth
        height = newHeight
        pixels = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 0xFF
        }
    }

    // MARK: - Core Blit Operations

    public func fillRect(x: Int, y: Int, width rw: Int, height rh: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) {
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + rw)
        let y1 = min(height, y + rh)
        guard x0 < x1, y0 < y1 else { return }

        let (b, g, r, a) = bgra
        let rowStride = width * 4
        pixels.withUnsafeMutableBufferPointer { buf in
            for row in y0..<y1 {
                var offset = row * rowStride + x0 * 4
                for _ in x0..<x1 {
                    buf[offset] = b
                    buf[offset + 1] = g
                    buf[offset + 2] = r
                    buf[offset + 3] = a
                    offset += 4
                }
            }
        }
    }

    public func blitRaw(rect: RFBRect, data: Data, pixelFormat: RFBPixelFormat) {
        let bpp = pixelFormat.bytesPerPixel
        guard bpp > 0, rect.width > 0, rect.height > 0 else { return }
        let expected = rect.width * rect.height * bpp
        guard data.count >= expected else { return }

        if pixelFormat.isNativeBGRA32 {
            let dstStride = width * 4
            let srcStride = rect.width * 4
            let copyW = min(rect.width, max(0, width - rect.x))
            let copyH = min(rect.height, max(0, height - rect.y))
            guard copyW > 0, copyH > 0, rect.x >= 0, rect.y >= 0 else { return }

            data.withUnsafeBytes { srcRaw in
                guard let srcBase = srcRaw.baseAddress else { return }
                pixels.withUnsafeMutableBytes { dstRaw in
                    guard let dstBase = dstRaw.baseAddress else { return }
                    let rowBytes = copyW * 4
                    for row in 0..<copyH {
                        let dstOffset = (rect.y + row) * dstStride + rect.x * 4
                        let srcOffset = row * srcStride
                        memcpy(dstBase + dstOffset, srcBase + srcOffset, rowBytes)
                    }
                }
            }
            return
        }

        let srcBytes = [UInt8](data)
        let rowStride = width * 4
        for row in 0..<rect.height {
            let dstY = rect.y + row
            guard dstY >= 0, dstY < height else { continue }
            for col in 0..<rect.width {
                let dstX = rect.x + col
                guard dstX >= 0, dstX < width else { continue }
                let srcIdx = (row * rect.width + col) * bpp
                let rawVal = Self.readPixelValue(from: srcBytes, at: srcIdx, format: pixelFormat)
                let (b, g, r, a) = pixelFormat.unpackToBGRA(rawVal)
                let dstIdx = dstY * rowStride + dstX * 4
                pixels[dstIdx] = b
                pixels[dstIdx + 1] = g
                pixels[dstIdx + 2] = r
                pixels[dstIdx + 3] = a
            }
        }
    }

    public func copyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, width rw: Int, height rh: Int) {
        guard rw > 0, rh > 0 else { return }
        let validW = min(rw, min(width - srcX, width - dstX))
        let validH = min(rh, min(height - srcY, height - dstY))
        guard validW > 0, validH > 0, srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0 else { return }

        let rowStride = width * 4
        let copyBytes = validW * 4

        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            if dstY > srcY {
                for row in stride(from: validH - 1, through: 0, by: -1) {
                    let srcOff = (srcY + row) * rowStride + srcX * 4
                    let dstOff = (dstY + row) * rowStride + dstX * 4
                    memmove(base + dstOff, base + srcOff, copyBytes)
                }
            } else {
                for row in 0..<validH {
                    let srcOff = (srcY + row) * rowStride + srcX * 4
                    let dstOff = (dstY + row) * rowStride + dstX * 4
                    memmove(base + dstOff, base + srcOff, copyBytes)
                }
            }
        }
    }

    // MARK: - ZRLE (Encoding 16) Decoder per RFC 6143 Section 7.7.6

    public func decodeZRLE(rect: RFBRect, decompressed: Data, pixelFormat: RFBPixelFormat) throws {
        let bytes = [UInt8](decompressed)
        var cursor = 0

        let isCpixel3Low = pixelFormat.trueColourFlag != 0 &&
            pixelFormat.bitsPerPixel == 32 &&
            pixelFormat.depth <= 24 &&
            (UInt32(pixelFormat.redMax) << UInt32(pixelFormat.redShift)) <= 0x00FF_FFFF &&
            (UInt32(pixelFormat.greenMax) << UInt32(pixelFormat.greenShift)) <= 0x00FF_FFFF &&
            (UInt32(pixelFormat.blueMax) << UInt32(pixelFormat.blueShift)) <= 0x00FF_FFFF

        let isCpixel3High = pixelFormat.trueColourFlag != 0 &&
            pixelFormat.bitsPerPixel == 32 &&
            pixelFormat.depth <= 24 &&
            pixelFormat.redShift >= 8 &&
            pixelFormat.greenShift >= 8 &&
            pixelFormat.blueShift >= 8

        let cpixelSize = (isCpixel3Low || isCpixel3High) ? 3 : pixelFormat.bytesPerPixel

        @inline(__always)
        func readCPixel() throws -> (UInt8, UInt8, UInt8, UInt8) {
            guard cursor + cpixelSize <= bytes.count else {
                throw RFBError.protocolError("Truncated ZRLE CPIXEL stream.")
            }
            if cpixelSize == 3 && pixelFormat.isNativeBGRA32 {
                let b = bytes[cursor]
                let g = bytes[cursor + 1]
                let r = bytes[cursor + 2]
                cursor += 3
                return (b, g, r, 0xFF)
            }
            var rawVal: UInt32 = 0
            if cpixelSize == 3 {
                if pixelFormat.bigEndianFlag != 0 {
                    rawVal = (UInt32(bytes[cursor]) << 16) | (UInt32(bytes[cursor + 1]) << 8) | UInt32(bytes[cursor + 2])
                } else {
                    rawVal = UInt32(bytes[cursor]) | (UInt32(bytes[cursor + 1]) << 8) | (UInt32(bytes[cursor + 2]) << 16)
                }
                if isCpixel3High {
                    rawVal <<= 8
                }
            } else {
                rawVal = Self.readPixelValue(from: bytes, at: cursor, format: pixelFormat)
            }
            cursor += cpixelSize
            return pixelFormat.unpackToBGRA(rawVal)
        }

        @inline(__always)
        func readRunLength() throws -> Int {
            var length = 1
            while true {
                guard cursor < bytes.count else {
                    throw RFBError.protocolError("Truncated ZRLE run length.")
                }
                let b = bytes[cursor]
                cursor += 1
                length += Int(b)
                if b != 255 { break }
            }
            return length
        }

        let rowStride = width * 4

        @inline(__always)
        func setPixel(x: Int, y: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let idx = y * rowStride + x * 4
            pixels[idx] = bgra.0
            pixels[idx + 1] = bgra.1
            pixels[idx + 2] = bgra.2
            pixels[idx + 3] = bgra.3
        }

        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileH = min(64, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileW = min(64, rect.x + rect.width - tileX)

                guard cursor < bytes.count else {
                    throw RFBError.protocolError("Truncated ZRLE tile header.")
                }
                let subencoding = bytes[cursor]
                cursor += 1

                let isRLE = (subencoding & 0x80) != 0
                let paletteSize = Int(subencoding & 0x7F)

                if !isRLE && paletteSize == 0 {
                    for ty in 0..<tileH {
                        for tx in 0..<tileW {
                            let bgra = try readCPixel()
                            setPixel(x: tileX + tx, y: tileY + ty, bgra: bgra)
                        }
                    }
                } else if !isRLE && paletteSize == 1 {
                    let bgra = try readCPixel()
                    fillRect(x: tileX, y: tileY, width: tileW, height: tileH, bgra: bgra)
                } else if !isRLE && paletteSize >= 2 && paletteSize <= 16 {
                    var palette: [(UInt8, UInt8, UInt8, UInt8)] = []
                    palette.reserveCapacity(paletteSize)
                    for _ in 0..<paletteSize {
                        palette.append(try readCPixel())
                    }
                    let bitsPerPixel: Int
                    if paletteSize == 2 {
                        bitsPerPixel = 1
                    } else if paletteSize <= 4 {
                        bitsPerPixel = 2
                    } else {
                        bitsPerPixel = 4
                    }
                    let mask: UInt8 = (1 << bitsPerPixel) - 1
                    let pixelsPerByte = 8 / bitsPerPixel

                    for ty in 0..<tileH {
                        var currentByte: UInt8 = 0
                        var bitsRemaining = 0
                        for tx in 0..<tileW {
                            if bitsRemaining == 0 {
                                guard cursor < bytes.count else {
                                    throw RFBError.protocolError("Truncated ZRLE packed palette data.")
                                }
                                currentByte = bytes[cursor]
                                cursor += 1
                                bitsRemaining = pixelsPerByte
                            }
                            let shift = (bitsRemaining - 1) * bitsPerPixel
                            let index = Int((currentByte >> shift) & mask)
                            bitsRemaining -= 1
                            if index < palette.count {
                                setPixel(x: tileX + tx, y: tileY + ty, bgra: palette[index])
                            }
                        }
                    }
                } else if isRLE && paletteSize == 0 {
                    let totalPixels = tileW * tileH
                    var pIdx = 0
                    while pIdx < totalPixels {
                        let bgra = try readCPixel()
                        let runLen = try readRunLength()
                        let end = min(totalPixels, pIdx + runLen)
                        while pIdx < end {
                            let ty = pIdx / tileW
                            let tx = pIdx % tileW
                            setPixel(x: tileX + tx, y: tileY + ty, bgra: bgra)
                            pIdx += 1
                        }
                    }
                } else if isRLE && paletteSize >= 2 && paletteSize <= 127 {
                    var palette: [(UInt8, UInt8, UInt8, UInt8)] = []
                    palette.reserveCapacity(paletteSize)
                    for _ in 0..<paletteSize {
                        palette.append(try readCPixel())
                    }
                    let totalPixels = tileW * tileH
                    var pIdx = 0
                    while pIdx < totalPixels {
                        guard cursor < bytes.count else {
                            throw RFBError.protocolError("Truncated ZRLE palette RLE stream.")
                        }
                        let entry = bytes[cursor]
                        cursor += 1
                        let index = Int(entry & 0x7F)
                        let runLen: Int
                        if (entry & 0x80) != 0 {
                            runLen = try readRunLength()
                        } else {
                            runLen = 1
                        }
                        let bgra = index < palette.count ? palette[index] : (0, 0, 0, 0xFF)
                        let end = min(totalPixels, pIdx + runLen)
                        while pIdx < end {
                            let ty = pIdx / tileW
                            let tx = pIdx % tileW
                            setPixel(x: tileX + tx, y: tileY + ty, bgra: bgra)
                            pIdx += 1
                        }
                    }
                } else {
                    throw RFBError.protocolError("Unsupported ZRLE subencoding byte: \(subencoding)")
                }

                tileX += 64
            }
            tileY += 64
        }
    }

    // MARK: - CoreGraphics Snapshots

    public func makeCGImage() -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    public static func makeCursorCGImage(from cursor: RFBCursor) -> CGImage? {
        guard cursor.width > 0, cursor.height > 0,
              cursor.bgraPixels.count == cursor.width * cursor.height * 4 else { return nil }
        let data = Data(cursor.bgraPixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: cursor.width,
            height: cursor.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cursor.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    #if canImport(UIKit)
    public static func makeThumbnailJPEG(from cgImage: CGImage, maxDimension: CGFloat = 640, quality: CGFloat = 0.72) -> Data? {
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let targetSize = CGSize(width: max(1, floor(srcW * scale)), height: max(1, floor(srcH * scale)))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let image = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return image.jpegData(compressionQuality: quality)
    }
    #endif

    // MARK: - Helpers

    @inline(__always)
    public static func readPixelValue(from bytes: [UInt8], at offset: Int, format: RFBPixelFormat) -> UInt32 {
        switch format.bitsPerPixel {
        case 8:
            return UInt32(bytes[offset])
        case 16:
            if format.bigEndianFlag != 0 {
                return (UInt32(bytes[offset]) << 8) | UInt32(bytes[offset + 1])
            } else {
                return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            }
        case 32:
            if format.bigEndianFlag != 0 {
                return (UInt32(bytes[offset]) << 24) |
                    (UInt32(bytes[offset + 1]) << 16) |
                    (UInt32(bytes[offset + 2]) << 8) |
                    UInt32(bytes[offset + 3])
            } else {
                return UInt32(bytes[offset]) |
                    (UInt32(bytes[offset + 1]) << 8) |
                    (UInt32(bytes[offset + 2]) << 16) |
                    (UInt32(bytes[offset + 3]) << 24)
            }
        default:
            return 0
        }
    }
}
