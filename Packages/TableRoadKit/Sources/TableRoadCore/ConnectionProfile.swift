import Foundation

/// A saved connection. Secrets (passwords, passphrases, imported keys) are never stored here;
/// they live in the Keychain keyed by `id`.
public struct ConnectionProfile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Used for import conflict handling and (later) sync.
    public var modifiedAt: Date
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var username: String
    /// Database name for SQL engines; database index ("0"…"15") for Redis.
    public var database: String?
    public var tls: TLSMode
    /// `nil` means connect directly.
    public var ssh: SSHConfig?
    public var tag: ConnectionTag
    public var safeMode: SafeMode
    public var groupID: UUID?

    public init(
        id: UUID = UUID(),
        modifiedAt: Date = .now,
        name: String,
        kind: DatabaseKind,
        host: String = "127.0.0.1",
        port: Int? = nil,
        username: String = "",
        database: String? = nil,
        tls: TLSMode = .prefer,
        ssh: SSHConfig? = nil,
        tag: ConnectionTag = .none,
        safeMode: SafeMode = .off,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.database = database
        self.tls = tls
        self.ssh = ssh
        self.tag = tag
        self.safeMode = safeMode
        self.groupID = groupID
    }
}

public enum TLSMode: String, Codable, Sendable, CaseIterable {
    case disable
    case prefer
    case require
    /// Require TLS and verify the certificate chain and hostname.
    case verifyFull
}

/// Colour tag shown on the connection and window, as in TablePlus.
public enum ConnectionTag: String, Codable, Sendable, CaseIterable {
    case none, local, development, testing, staging, production
}

public enum SafeMode: String, Codable, Sendable, CaseIterable {
    /// No confirmation.
    case off
    /// Ask before committing any write.
    case confirmWrites
    /// Block all writes.
    case readOnly
}

public struct SSHConfig: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SSHAuth

    public init(host: String, port: Int = 22, username: String, auth: SSHAuth) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}

public enum SSHAuth: Codable, Sendable, Hashable {
    /// Password stored in Keychain.
    case password
    /// Private key; passphrase (if any) stored in Keychain.
    case privateKey(KeyReference)
    /// Use an SSH agent (`SSH_AUTH_SOCK`, or an explicit socket path such as 1Password's).
    case agent(socketPath: String?)
}

public enum KeyReference: Codable, Sendable, Hashable {
    /// A key file on disk (direct build: plain path, e.g. `~/.ssh/id_ed25519`).
    case file(path: String)
    /// Key material imported into TableRoad's Keychain.
    case imported(id: UUID)
}
