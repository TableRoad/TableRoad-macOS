import TableRoadCore

/// Everything needed to open a MySQL/MariaDB session. Built from a `ConnectionProfile` plus its
/// Keychain secret; the host/port may point at a local SSH forward (Phase 3).
public struct MySQLConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String?
    public var tls: TLSMode

    public init(
        host: String, port: Int = 3306, username: String, password: String?, database: String? = nil,
        tls: TLSMode = .prefer
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            database: profile.database.flatMap { $0.isEmpty ? nil : $0 }, tls: profile.tls
        )
    }
}
