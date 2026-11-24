import Foundation
import Network
import Observation

public struct DiscoveredMac: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let domain: String
    public let endpoint: NWEndpoint

    public static func == (lhs: DiscoveredMac, rhs: DiscoveredMac) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Discovers Macs advertising macOS Screen Sharing / VNC (`_rfb._tcp`) on the local network via Bonjour.
@MainActor
@Observable
public final class BonjourMacDiscovery {
    public private(set) var discoveredMacs: [DiscoveredMac] = []
    public private(set) var isScanning = false
    public private(set) var statusMessage: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.macbeam.bonjour", qos: .utility)

    public init() {}

    public func startScanning() {
        stopScanning()
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_rfb._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: params)
        self.browser = newBrowser
        self.isScanning = true
        self.statusMessage = nil

        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            Task { @MainActor [weak self] in
                // Ignore late callbacks from previously cancelled browsers.
                guard let self, let active = newBrowser, self.browser === active else { return }
                switch state {
                case .ready:
                    self.isScanning = true
                    self.statusMessage = nil
                case .failed(let err):
                    self.isScanning = false
                    self.statusMessage = err.localizedDescription
                case .waiting(let err):
                    self.statusMessage = "Waiting for local network permission (\(err.localizedDescription))"
                case .cancelled:
                    self.isScanning = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self, weak newBrowser] results, _ in
            var found: [DiscoveredMac] = []
            for result in results {
                if case let .service(name, type, domain, _) = result.endpoint {
                    let id = "\(name).\(type).\(domain)"
                    found.append(DiscoveredMac(
                        id: id,
                        name: name,
                        domain: domain,
                        endpoint: result.endpoint
                    ))
                }
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self, let active = newBrowser, self.browser === active else { return }
                self.discoveredMacs = found
            }
        }

        newBrowser.start(queue: queue)
    }

    public func stopScanning() {
        let old = browser
        browser = nil
        old?.stateUpdateHandler = nil
        old?.browseResultsChangedHandler = nil
        old?.cancel()
        isScanning = false
    }
}
