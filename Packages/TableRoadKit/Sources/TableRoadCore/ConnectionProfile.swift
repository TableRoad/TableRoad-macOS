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
    /// Window/list colour, independent of the tag (the tag drives safety, the colour is cosmetic).
    public var statusColor: StatusColor
    /// Whether the database password is kept in the Keychain or asked for on each connect.
    public var passwordStorage: PasswordStorage
    /// SQL run on every new connection (e.g. `SET time_zone = '+00:00'`), split into statements.
    public var bootstrapSQL: String?
    /// Client certificate files for TLS.
    public var tlsFiles: TLSFiles

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
        groupID: UUID? = nil,
        statusColor: StatusColor = .none,
        passwordStorage: PasswordStorage = .keychain,
        bootstrapSQL: String? = nil,
        tlsFiles: TLSFiles = TLSFiles()
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
        self.statusColor = statusColor
        self.passwordStorage = passwordStorage
        self.bootstrapSQL = bootstrapSQL
        self.tlsFiles = tlsFiles
    }

    private enum CodingKeys: String, CodingKey {
        case id, modifiedAt, name, kind, host, port, username, database, tls, ssh, tag, safeMode, groupID
        case statusColor, passwordStorage, bootstrapSQL, tlsFiles
    }

    /// Fields added after v1 are optional on disk, so older connection files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .now
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DatabaseKind.self, forKey: .kind)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database)
        tls = try c.decodeIfPresent(TLSMode.self, forKey: .tls) ?? .prefer
        ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh)
        tag = try c.decodeIfPresent(ConnectionTag.self, forKey: .tag) ?? .none
        safeMode = try c.decodeIfPresent(SafeMode.self, forKey: .safeMode) ?? .off
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        statusColor = try c.decodeIfPresent(StatusColor.self, forKey: .statusColor) ?? .none
        passwordStorage = try c.decodeIfPresent(PasswordStorage.self, forKey: .passwordStorage) ?? .keychain
        bootstrapSQL = try c.decodeIfPresent(String.self, forKey: .bootstrapSQL)
        tlsFiles = try c.decodeIfPresent(TLSFiles.self, forKey: .tlsFiles) ?? TLSFiles()
    }
}

/// Window and list colour (TablePlus's "Status Color").
public enum StatusColor: String, Codable, Sendable, CaseIterable {
    case none, green, gray, blue, yellow, red
}

public enum PasswordStorage: String, Codable, Sendable, CaseIterable {
    /// Saved in the Keychain.
    case keychain
    /// Never saved; asked for when the connection opens.
    case askEachTime
}

/// Client certificate material for TLS, as file paths (direct build reads them directly).
public struct TLSFiles: Codable, Sendable, Hashable {
    public var clientKeyPath: String?
    public var clientCertPath: String?
    public var caCertPath: String?

    public init(clientKeyPath: String? = nil, clientCertPath: String? = nil, caCertPath: String? = nil) {
        self.clientKeyPath = clientKeyPath
        self.clientCertPath = clientCertPath
        self.caCertPath = caCertPath
    }

    public var isEmpty: Bool { clientKeyPath == nil && clientCertPath == nil && caCertPath == nil }
}

/// TLS levels, matching MySQL's `ssl-mode` names.
public enum TLSMode: String, Codable, Sendable, CaseIterable {
    /// DISABLED
    case disable
    /// PREFERRED: TLS if the server offers it.
    case prefer
    /// REQUIRED: TLS, certificate not checked.
    case require
    /// VERIFY_CA: TLS, certificate chain checked against the CA, hostname not checked.
    case verifyCA
    /// VERIFY_IDENTITY: TLS, chain and hostname checked.
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
