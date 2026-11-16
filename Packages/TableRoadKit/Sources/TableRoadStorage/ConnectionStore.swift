import Foundation
import Observation
import TableRoadCore

/// Saved connections, persisted as JSON. Secrets go to a `SecretStore`, never into the file.
@MainActor @Observable
public final class ConnectionStore {
    public private(set) var profiles: [ConnectionProfile] = []
    /// Set when the file exists but can't be read; the store then refuses to overwrite it.
    public private(set) var loadError: String?

    public let secrets: any SecretStore
    private let fileURL: URL

    struct FileFormat: Codable {
        var version = 1
        var connections: [ConnectionProfile]
    }

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        load()
    }

    /// `~/Library/Application Support/TableRoad/connections.json`.
    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "TableRoad/connections.json")
    }

    public func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    /// Inserts or replaces a profile, and stores (or clears) its database password.
    public func save(_ profile: ConnectionProfile, password: String?) throws {
        var profile = profile
        profile.modifiedAt = .now
        try secrets.setSecret(password, .databasePassword, for: profile.id)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    public func duplicate(_ profile: ConnectionProfile) throws -> ConnectionProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) copy"
        try save(copy, password: try secrets.secret(.databasePassword, for: profile.id))
        return copy
    }

    public func delete(_ id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try secrets.removeAll(for: id)
        try persist()
    }

    public func password(for id: UUID) -> String? {
        try? secrets.secret(.databasePassword, for: id)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode(FileFormat.self, from: Data(contentsOf: fileURL)).connections
        } catch {
            loadError = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func persist() throws {
        guard loadError == nil else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: loadError!])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(connections: profiles))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
