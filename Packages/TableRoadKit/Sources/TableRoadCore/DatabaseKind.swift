/// Database engines TableRoad knows about. Raw values are persisted in connection files, so never rename one.
public enum DatabaseKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case postgres
    case redshift
    case mysql
    case mariadb
    case singlestore
    case sqlserver
    case cassandra
    case clickhouse
    case bigquery
    case dynamodb
    case athena
    case influxdb
    case elasticsearch
    case libsql
    case d1
    case mongodb
    case snowflake
    case redis
    case sqlite
    case duckdb
    case oracle
    case cockroach
    case greenplum
    case vertica

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .redshift: "Amazon Redshift"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .singlestore: "SingleStore"
        case .sqlserver: "Microsoft SQL Server"
        case .cassandra: "Cassandra"
        case .clickhouse: "ClickHouse"
        case .bigquery: "BigQuery"
        case .dynamodb: "DynamoDB"
        case .athena: "Amazon Athena"
        case .influxdb: "InfluxDB"
        case .elasticsearch: "Elasticsearch"
        case .libsql: "LibSQL"
        case .d1: "Cloudflare D1"
        case .mongodb: "MongoDB"
        case .snowflake: "Snowflake"
        case .redis: "Redis"
        case .sqlite: "SQLite"
        case .duckdb: "DuckDB"
        case .oracle: "Oracle"
        case .cockroach: "CockroachDB"
        case .greenplum: "Greenplum"
        case .vertica: "Vertica"
        }
    }

    /// Two-letter badge, as in TablePlus's engine picker.
    public var badge: String {
        switch self {
        case .postgres: "Pg"
        case .redshift: "Rs"
        case .mysql: "Ms"
        case .mariadb: "Ma"
        case .singlestore: "S2"
        case .sqlserver: "Ss"
        case .cassandra: "Cs"
        case .clickhouse: "Ch"
        case .bigquery: "Bq"
        case .dynamodb: "Dn"
        case .athena: "At"
        case .influxdb: "In"
        case .elasticsearch: "Es"
        case .libsql: "Ls"
        case .d1: "D1"
        case .mongodb: "Mg"
        case .snowflake: "Sf"
        case .redis: "Re"
        case .sqlite: "Sl"
        case .duckdb: "Du"
        case .oracle: "Oc"
        case .cockroach: "Cr"
        case .greenplum: "Gp"
        case .vertica: "Ve"
        }
    }

    /// Badge colour (sRGB hex).
    public var badgeColor: UInt32 {
        switch self {
        case .postgres: 0x336791
        case .redshift: 0x205B97
        case .mysql: 0xE48E00
        case .mariadb: 0x4E8A99
        case .singlestore: 0x7A3FD1
        case .sqlserver: 0xA0A3A8
        case .cassandra: 0x2B2B2B
        case .clickhouse: 0xD9C300
        case .bigquery: 0x4386FA
        case .dynamodb: 0x2E4D9B
        case .athena: 0xE8892F
        case .influxdb: 0x22174E
        case .elasticsearch: 0x3EBEB0
        case .libsql: 0x4FBF8A
        case .d1: 0xF38020
        case .mongodb: 0x3F7E44
        case .snowflake: 0x29B5E8
        case .redis: 0xA41E11
        case .sqlite: 0x8F2BE2
        case .duckdb: 0x111111
        case .oracle: 0xE5332A
        case .cockroach: 0x2E9E3E
        case .greenplum: 0x7AB648
        case .vertica: 0x1A2F5A
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres, .redshift, .greenplum: self == .redshift ? 5439 : 5432
        case .cockroach: 26257
        case .mysql, .mariadb, .singlestore: 3306
        case .sqlserver: 1433
        case .cassandra: 9042
        case .clickhouse: 8123
        case .influxdb: 8086
        case .elasticsearch: 9200
        case .mongodb: 27017
        case .redis: 6379
        case .oracle: 1521
        case .vertica: 5433
        case .libsql: 8080
        case .bigquery, .dynamodb, .athena, .d1, .snowflake, .sqlite, .duckdb: 443
        }
    }

    /// Engines that share a wire protocol (and so a driver).
    public enum Family: Sendable {
        case mysql, postgres, sqlite, redis, http, other
    }

    public var family: Family {
        switch self {
        case .mysql, .mariadb, .singlestore: .mysql
        case .postgres, .redshift, .cockroach, .greenplum: .postgres
        case .sqlite: .sqlite
        case .redis: .redis
        case .clickhouse, .elasticsearch, .influxdb, .libsql, .d1: .http
        default: .other
        }
    }

    /// A local file instead of a server (the connection form asks for a path).
    public var isFileBased: Bool { self == .sqlite || self == .duckdb }

    /// SQL engines get the table browser / SQL editor; Redis and MongoDB get their own browsers.
    public var isSQL: Bool {
        switch self {
        case .redis, .mongodb, .dynamodb, .elasticsearch: false
        default: true
        }
    }
}
