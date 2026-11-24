import Foundation
import Network

/// Abstract byte-stream transport used by `RFBClient`.
public protocol RFBTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receiveChunk(maxBytes: Int) async throws -> Data
    func close()
}

/// High-performance `Network.framework` TCP transport with `TCP_NODELAY`,
/// cancellation-safe continuations, and a hard connection timeout.
public final class RFBTCPTransport: RFBTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.macbeam.rfb.tcp", qos: .userInteractive)
    private let stateLock = NSLock()
    private var isClosed = false
    private var pendingConnectContinuation: CheckedContinuation<Void, Error>?
    private let connectTimeoutSeconds: TimeInterval

    public init(host: String, port: UInt16, connectTimeoutSeconds: TimeInterval = 15) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RFBError.invalidAddress
        }
        self.connectTimeoutSeconds = connectTimeoutSeconds
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.connectionTimeout = Int(connectTimeoutSeconds)

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
    }

    public init(endpoint: NWEndpoint, connectTimeoutSeconds: TimeInterval = 15) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.connectionTimeout = Int(connectTimeoutSeconds)

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        self.connection = NWConnection(to: endpoint, using: params)
    }

    public func connect() async throws {
        let timeoutTask = Task { [weak self, connectTimeoutSeconds] in
            try? await Task.sleep(for: .seconds(connectTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.failConnectAndClose(error: RFBError.connectionTimedOut)
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateLock.lock()
                if isClosed {
                    stateLock.unlock()
                    continuation.resume(throwing: RFBError.connectionClosed)
                    return
                }
                pendingConnectContinuation = continuation
                stateLock.unlock()

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.resumePendingConnect(with: .success(()))
                    case .failed(let err):
                        self.failConnectAndClose(error: RFBError.connectionFailed(err.localizedDescription))
                    case .waiting(let err):
                        if case .posix(let code) = err {
                            switch code {
                            case .ECONNREFUSED:
                                self.failConnectAndClose(error: RFBError.connectionFailed("Connection refused. Make sure Screen Sharing is enabled on your Mac."))
                            case .EHOSTUNREACH, .ENETUNREACH, .ETIMEDOUT:
                                self.failConnectAndClose(error: RFBError.connectionTimedOut)
                            default:
                                break
                            }
                        }
                    case .cancelled:
                        self.resumePendingConnect(with: .failure(RFBError.connectionClosed))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [weak self] in
            self?.close()
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveChunk(maxBytes: Int = 65_536) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: RFBError.connectionFailed(error.localizedDescription))
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    if isComplete {
                        continuation.resume(throwing: RFBError.connectionClosed)
                        return
                    }
                    continuation.resume(throwing: RFBError.connectionClosed)
                }
            }
        } onCancel: { [weak self] in
            self?.close()
        }
    }

    public func close() {
        failConnectAndClose(error: RFBError.connectionClosed)
    }

    private func resumePendingConnect(with result: Result<Void, Error>) {
        stateLock.lock()
        let cont = pendingConnectContinuation
        pendingConnectContinuation = nil
        stateLock.unlock()
        cont?.resume(with: result)
    }

    private func failConnectAndClose(error: Error) {
        stateLock.lock()
        let cont = pendingConnectContinuation
        pendingConnectContinuation = nil
        let shouldCancel = !isClosed
        isClosed = true
        stateLock.unlock()

        cont?.resume(throwing: error)
        if shouldCancel {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}

/// Buffered reader/writer wrapping an `RFBTransport` for exact-length RFB wire framing.
public final class RFBStream: @unchecked Sendable {
    private let transport: RFBTransport
    private var buffer = Data()
    private var readOffset = 0

    public init(transport: RFBTransport) {
        self.transport = transport
    }

    public func connect() async throws {
        try await transport.connect()
    }

    public func close() {
        transport.close()
    }

    public func write(_ data: Data) async throws {
        try await transport.send(data)
    }

    public func readExact(_ count: Int) async throws -> Data {
        guard count >= 0 else {
            throw RFBError.protocolError("Negative read length requested.")
        }
        guard count > 0 else { return Data() }

        while buffer.count - readOffset < count {
            if readOffset > 0 && readOffset >= 32_768 {
                buffer.removeSubrange(0..<readOffset)
                readOffset = 0
            }
            let chunk = try await transport.receiveChunk(maxBytes: 65_536)
            if chunk.isEmpty {
                throw RFBError.connectionClosed
            }
            buffer.append(chunk)
        }

        let start = readOffset
        let end = start + count
        let slice = Data(buffer[start..<end])
        readOffset = end
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        return slice
    }

    public func readUInt8() async throws -> UInt8 {
        let data = try await readExact(1)
        return data[data.startIndex]
    }

    public func readUInt16BE() async throws -> UInt16 {
        let d = try await readExact(2)
        return (UInt16(d[0]) << 8) | UInt16(d[1])
    }

    public func readUInt32BE() async throws -> UInt32 {
        let d = try await readExact(4)
        return (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
    }

    public func readInt32BE() async throws -> Int32 {
        Int32(bitPattern: try await readUInt32BE())
    }
}
