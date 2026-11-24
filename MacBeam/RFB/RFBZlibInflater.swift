import Foundation
import zlib

/// Stateful streaming zlib inflater for RFB `Zlib` (6) and `ZRLE` (16) encodings.
/// Heap-allocates `z_stream` so its memory address remains stable across calls
/// (required by zlib 1.2.9+ internal `state->strm == strm` invariants) and enforces
/// a strict output byte ceiling to defend against decompression bombs.
public final class RFBZlibInflater {
    private let streamPtr: UnsafeMutablePointer<z_stream>
    private var initialized = false

    public init() throws {
        streamPtr = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        streamPtr.initialize(to: z_stream())
        let result = inflateInit_(
            streamPtr,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard result == Z_OK else {
            streamPtr.deinitialize(count: 1)
            streamPtr.deallocate()
            throw RFBError.decompressionFailed(result)
        }
        initialized = true
    }

    deinit {
        if initialized {
            inflateEnd(streamPtr)
        }
        streamPtr.deinitialize(count: 1)
        streamPtr.deallocate()
    }

    /// Inflates a compressed chunk from the persistent stream with a hard upper bound on output bytes.
    public func decompress(
        _ compressed: Data,
        maxOutputBytes: Int = 64 * 1024 * 1024
    ) throws -> Data {
        guard initialized else {
            throw RFBError.decompressionFailed(Z_STREAM_ERROR)
        }
        if compressed.isEmpty {
            return Data()
        }

        var output = Data()
        output.reserveCapacity(min(max(compressed.count * 2, 4096), min(maxOutputBytes, 1_048_576)))

        let chunkSize = 32_768
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try compressed.withUnsafeBytes { rawIn in
            guard let basePtr = rawIn.bindMemory(to: Bytef.self).baseAddress else { return }
            streamPtr.pointee.next_in = UnsafeMutablePointer(mutating: basePtr)
            streamPtr.pointee.avail_in = uInt(compressed.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { rawOut in
                    streamPtr.pointee.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    streamPtr.pointee.avail_out = uInt(chunkSize)
                    return inflate(streamPtr, Z_SYNC_FLUSH)
                }

                let produced = chunkSize - Int(streamPtr.pointee.avail_out)
                if produced > 0 {
                    if output.count + produced > maxOutputBytes {
                        throw RFBError.protocolError("Decompressed rectangle exceeded maximum allowed size (\(maxOutputBytes) bytes).")
                    }
                    output.append(buffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                } else if status == Z_OK {
                    if streamPtr.pointee.avail_in == 0 && streamPtr.pointee.avail_out > 0 {
                        break
                    }
                } else if status == Z_BUF_ERROR {
                    if streamPtr.pointee.avail_in == 0 {
                        break
                    }
                    throw RFBError.decompressionFailed(status)
                } else {
                    throw RFBError.decompressionFailed(status)
                }
            }
        }

        return output
    }
}

/// Stateful streaming zlib deflater with heap-pinned `z_stream` (used by tests and DemoMacVNCServer).
public final class RFBZlibDeflater {
    private let streamPtr: UnsafeMutablePointer<z_stream>
    private var initialized = false

    public init(level: Int32 = Z_DEFAULT_COMPRESSION) throws {
        streamPtr = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        streamPtr.initialize(to: z_stream())
        let result = deflateInit_(
            streamPtr,
            level,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard result == Z_OK else {
            streamPtr.deinitialize(count: 1)
            streamPtr.deallocate()
            throw RFBError.decompressionFailed(result)
        }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(streamPtr)
        }
        streamPtr.deinitialize(count: 1)
        streamPtr.deallocate()
    }

    public func compress(_ input: Data) throws -> Data {
        guard initialized else {
            throw RFBError.decompressionFailed(Z_STREAM_ERROR)
        }
        var output = Data()
        let chunkSize = 32_768
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { rawIn in
            guard let basePtr = rawIn.bindMemory(to: Bytef.self).baseAddress else { return }
            streamPtr.pointee.next_in = UnsafeMutablePointer(mutating: basePtr)
            streamPtr.pointee.avail_in = uInt(input.count)

            repeat {
                let status: Int32 = buffer.withUnsafeMutableBytes { rawOut in
                    streamPtr.pointee.next_out = rawOut.bindMemory(to: Bytef.self).baseAddress
                    streamPtr.pointee.avail_out = uInt(chunkSize)
                    return deflate(streamPtr, Z_SYNC_FLUSH)
                }
                guard status == Z_OK || status == Z_BUF_ERROR else {
                    throw RFBError.decompressionFailed(status)
                }
                let produced = chunkSize - Int(streamPtr.pointee.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while streamPtr.pointee.avail_out == 0
        }

        return output
    }
}
