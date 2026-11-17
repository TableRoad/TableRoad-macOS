import Foundation
import Observation
import TableRoadCore

/// Saved connections, persisted as JSON. Secrets go to a `SecretStore`, never into the file.
@MainActor @Observable
public final class ConnectionStore {
    public private(set) var profiles: [ConnectionProfile] = []
    /// Folders for grouping connections on the Welcome window (one level, like TablePlus).
    public private(set) var groups: [ConnectionGroup] = []
    /// Set when the file exists but can't be read; the store then refuses to overwrite it.
    public private(set) var loadError: String?

    public let secrets: any SecretStore
    private let fileURL: URL

    struct FileFormat: Codable {
        var version = 2
        var connections: [ConnectionProfile]
        var groups: [ConnectionGroup] = []

        init(connections: [ConnectionProfile], groups: [ConnectionGroup]) {
            self.connections = connections
            self.groups = groups
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            connections = try container.decode([ConnectionProfile].self, forKey: .connections)
            groups = try container.decodeIfPresent([ConnectionGroup].self, forKey: .groups) ?? []
        }
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

    // MARK: - Groups

    public func group(id: UUID) -> ConnectionGroup? { groups.first { $0.id == id } }

    public func save(_ group: ConnectionGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        try persist()
    }

    /// Deletes a group; its connections move to the top level (they're never deleted with it).
    public func deleteGroup(_ id: UUID) throws {
        groups.removeAll { $0.id == id }
        for index in profiles.indices where profiles[index].groupID == id { profiles[index].groupID = nil }
        try persist()
    }

    /// Moves connections into a group (nil = top level).
    public func move(_ ids: Set<UUID>, to groupID: UUID?) throws {
        for index in profiles.indices where ids.contains(profiles[index].id) { profiles[index].groupID = groupID }
        try persist()
    }

    /// Adds imported groups and connections (new IDs, so nothing existing is overwritten) with their secrets.
    @discardableResult
    public func importBundle(_ bundle: ConnectionBundle) throws -> [ConnectionProfile] {
        var groupMap: [UUID: UUID] = [:]
        for group in bundle.groups {
            var copy = group
            copy.id = UUID()
            groupMap[group.id] = copy.id
            groups.append(copy)
        }
        var imported: [ConnectionProfile] = []
        for entry in bundle.connections {
            var profile = entry.profile
            profile.id = UUID()
            profile.groupID = profile.groupID.flatMap { groupMap[$0] }
            profile.modifiedAt = .now
            try secrets.setSecret(entry.password, .databasePassword, for: profile.id)
            try secrets.setSecret(entry.sshPassword, .sshPassword, for: profile.id)
            profiles.append(profile)
            imported.append(profile)
        }
        try persist()
        return imported
    }

    /// Connections (and the groups they're in) for exporting, optionally with their passwords.
    public func bundle(for ids: Set<UUID>?, includePasswords: Bool, includeSSHPasswords: Bool) -> ConnectionBundle {
        let chosen = profiles.filter { ids?.contains($0.id) ?? true }
        let groupIDs = Set(chosen.compactMap(\.groupID))
        return ConnectionBundle(
            groups: groups.filter { groupIDs.contains($0.id) },
            connections: chosen.map { profile in
                ConnectionBundle.Entry(
                    profile: profile, password: includePasswords ? password(for: profile.id) : nil,
                    sshPassword: includeSSHPasswords ? sshPassword(for: profile.id) : nil)
            })
    }

    public func delete(_ id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try secrets.removeAll(for: id)
        try persist()
    }

    public func password(for id: UUID) -> String? {
        try? secrets.secret(.databasePassword, for: id)
    }

    public func sshPassword(for id: UUID) -> String? {
        try? secrets.secret(.sshPassword, for: id)
    }

    /// Stores (or, with nil/empty, removes) the SSH password for a connection.
    public func setSSHPassword(_ password: String?, for id: UUID) throws {
        try secrets.setSecret(password, .sshPassword, for: id)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(FileFormat.self, from: Data(contentsOf: fileURL))
            profiles = file.connections
            groups = file.groups
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
        let data = try encoder.encode(FileFormat(connections: profiles, groups: groups))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
