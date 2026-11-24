import Foundation
import Observation
import UIKit

/// Manages saved Mac connections and their last-seen screen thumbnails.
@MainActor
@Observable
public final class ConnectionLibraryStore {
    public private(set) var profiles: [MacConnectionProfile] = []
    public private(set) var thumbnails: [UUID: UIImage] = [:]

    private let fileManager = FileManager.default
    private let profilesURL: URL
    private let thumbnailsDir: URL

    public init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let rootDir = appSupport.appendingPathComponent("MacBeam", isDirectory: true)
        self.profilesURL = rootDir.appendingPathComponent("connections.json")
        self.thumbnailsDir = rootDir.appendingPathComponent("Thumbnails", isDirectory: true)

        try? fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        load()
    }

    /// Strict weak ordering (transitive) comparator for saved profiles:
    /// Favorites first, then most recently connected, then display name, then UUID.
    public nonisolated static func sortProfiles(_ list: [MacConnectionProfile]) -> [MacConnectionProfile] {
        list.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            let lDate = lhs.lastConnectedAt ?? .distantPast
            let rDate = rhs.lastConnectedAt ?? .distantPast
            if lDate != rDate {
                return lDate > rDate
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public var sortedProfiles: [MacConnectionProfile] {
        Self.sortProfiles(profiles)
    }

    public func upsert(_ profile: MacConnectionProfile, password: String?) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        if let password {
            KeychainStore.savePassword(password, for: profile.id)
        }
        persist()
    }

    public func updateCredentialsAfterSuccess(profileID: UUID, username: String, password: String) {
        if let idx = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[idx].username = username
            persist()
        }
        KeychainStore.savePassword(password, for: profileID)
    }

    public func delete(_ profile: MacConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        thumbnails.removeValue(forKey: profile.id)
        KeychainStore.deletePassword(for: profile.id)
        let thumbURL = thumbnailsDir.appendingPathComponent("\(profile.id.uuidString).jpg")
        try? fileManager.removeItem(at: thumbURL)
        persist()
    }

    public func toggleFavorite(_ profile: MacConnectionProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].isFavorite.toggle()
        persist()
    }

    public func markConnected(profileID: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].lastConnectedAt = Date()
        persist()
    }

    public func saveThumbnail(_ jpegData: Data, for profileID: UUID) {
        let url = thumbnailsDir.appendingPathComponent("\(profileID.uuidString).jpg")
        try? jpegData.write(to: url, options: .atomic)
        if let img = UIImage(data: jpegData) {
            thumbnails[profileID] = img
        }
    }

    public func password(for profile: MacConnectionProfile) -> String {
        KeychainStore.loadPassword(for: profile.id)
    }

    private func load() {
        if let data = try? Data(contentsOf: profilesURL),
           let decoded = try? JSONDecoder().decode([MacConnectionProfile].self, from: data) {
            profiles = decoded
        }
        for profile in profiles {
            let thumbURL = thumbnailsDir.appendingPathComponent("\(profile.id.uuidString).jpg")
            if let data = try? Data(contentsOf: thumbURL), let img = UIImage(data: data) {
                thumbnails[profile.id] = img
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
    }
}
