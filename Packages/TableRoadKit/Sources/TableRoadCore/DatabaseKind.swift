/// The database engines TableRoad can connect to.
public enum DatabaseKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case postgres
    case mysql
    case mariadb
    case redis

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .redis: "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql, .mariadb: 3306
        case .redis: 6379
        }
    }

    /// SQL engines get the table browser / SQL editor; Redis gets the key browser.
    public var isSQL: Bool { self != .redis }
}
