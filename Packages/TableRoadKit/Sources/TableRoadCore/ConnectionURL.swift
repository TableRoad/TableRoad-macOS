import Foundation

/// Parses connection URLs such as `postgres://user:pass@host:5432/db?sslmode=require`,
/// `mysql://…`, `mariadb://…`, `redis://:pass@host:6379/0` and `rediss://…` (TLS).
public enum ConnectionURL {
    public struct Parsed: Sendable, Equatable {
        public var profile: ConnectionProfile
        /// The password from the URL, if any. Callers store it in the Keychain, never in the profile.
        public var password: String?
    }

    public enum ParseError: Error, Equatable {
        case invalidURL
        case unsupportedScheme(String)
        case missingHost
        case invalidRedisDatabase(String)
    }

    /// A URL for the connection, without its password (for "Copy as URL" and sharing).
    public static func string(for profile: ConnectionProfile) -> String {
        if profile.kind.isFileBased { return "file://" + profile.host }
        var components = URLComponents()
        components.scheme = profile.kind == .postgres ? "postgresql" : profile.kind.rawValue
        components.host = profile.host
        if profile.port != profile.kind.defaultPort { components.port = profile.port }
        if !profile.username.isEmpty { components.user = profile.username }
        if let database = profile.database, !database.isEmpty { components.path = "/" + database }
        return components.string ?? ""
    }

    public static func parse(_ string: String) throws -> Parsed {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased()
        else { throw ParseError.invalidURL }

        let kind: DatabaseKind
        var tls: TLSMode = .prefer
        switch scheme {
        case "postgres", "postgresql": kind = .postgres
        case "redshift": kind = .redshift
        case "cockroachdb", "cockroach": kind = .cockroach
        case "singlestore", "memsql": kind = .singlestore
        case "clickhouse": kind = .clickhouse
        case "libsql": kind = .libsql
        case "mysql": kind = .mysql
        case "mariadb": kind = .mariadb
        case "redis": kind = .redis; tls = .disable
        case "rediss": kind = .redis; tls = .require
        default: throw ParseError.unsupportedScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else { throw ParseError.missingHost }

        let path = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var database: String? = path.isEmpty ? nil : path.removingPercentEncoding ?? path
        if kind == .redis, let db = database {
            guard let index = Int(db), (0...15).contains(index) else { throw ParseError.invalidRedisDatabase(db) }
            database = String(index)
        }

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        if let mode = query["sslmode"] ?? query["ssl-mode"] {
            tls = Self.tlsMode(from: mode) ?? tls
        }

        let user = components.user?.removingPercentEncoding ?? components.user ?? ""
        let password = components.password.map { $0.removingPercentEncoding ?? $0 }

        let profile = ConnectionProfile(
            name: database.map { "\(host)/\($0)" } ?? host,
            kind: kind,
            host: host,
            port: components.port,
            username: user,
            database: database,
            tls: tls
        )
        return Parsed(profile: profile, password: password)
    }

    static func tlsMode(from value: String) -> TLSMode? {
        switch value.lowercased() {
        case "disable", "disabled", "false": .disable
        case "allow", "prefer", "preferred": .prefer
        case "require", "required", "true": .require
        case "verify-ca", "verify_ca": .verifyCA
        case "verify-full", "verify_identity", "verify-identity": .verifyFull
        default: nil
        }
    }
}
