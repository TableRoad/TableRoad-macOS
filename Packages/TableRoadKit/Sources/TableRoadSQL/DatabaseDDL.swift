/// CREATE / DROP DATABASE statements (MySQL & MariaDB).
import Foundation

extension MySQLDialect {
    /// `CREATE DATABASE `name` [CHARACTER SET x] [COLLATE y]`. Character set and collation must be plain names
    /// (letters, digits, underscores); anything else is rejected rather than spliced into SQL.
    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DDLError.emptyName }
        guard trimmed.count <= 64 else { throw DDLError.nameTooLong }
        var sql = "CREATE DATABASE \(quoteIdentifier(trimmed))"
        if let characterSet, !characterSet.isEmpty {
            guard Self.isPlainName(characterSet) else { throw DDLError.invalidOption(characterSet) }
            sql += " CHARACTER SET \(characterSet)"
        }
        if let collation, !collation.isEmpty {
            guard Self.isPlainName(collation) else { throw DDLError.invalidOption(collation) }
            sql += " COLLATE \(collation)"
        }
        return sql
    }

    public func dropDatabaseSQL(_ name: String) -> String {
        "DROP DATABASE \(quoteIdentifier(name))"
    }

    public func booleanLiteral(_ value: Bool) -> String { value ? "1" : "0" }

    public func useDatabaseSQL(_ name: String) -> String? { "USE \(quoteIdentifier(name))" }

    public var dumpPreamble: [String] {
        [
            "SET NAMES utf8mb4",
            "SET @OLD_FOREIGN_KEY_CHECKS = @@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS = 0",
            "SET @OLD_UNIQUE_CHECKS = @@UNIQUE_CHECKS, UNIQUE_CHECKS = 0",
            "SET @OLD_SQL_MODE = @@SQL_MODE, SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO'",
            "SET @OLD_TIME_ZONE = @@TIME_ZONE, TIME_ZONE = '+00:00'",
        ]
    }

    public var dumpPostamble: [String] {
        [
            "SET TIME_ZONE = @OLD_TIME_ZONE", "SET SQL_MODE = @OLD_SQL_MODE",
            "SET UNIQUE_CHECKS = @OLD_UNIQUE_CHECKS", "SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS",
        ]
    }

    /// Read temporal values in UTC to match the dump's TIME_ZONE = '+00:00'.
    public var exportSessionSetup: [String] { ["SET SESSION time_zone = '+00:00'"] }

    static func isPlainName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

public enum DDLError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case nameTooLong
    case invalidOption(String)

    public var description: String {
        switch self {
        case .emptyName: "Enter a database name."
        case .nameTooLong: "Database names can be at most 64 characters."
        case .invalidOption(let value): "“\(value)” isn't a valid character set or collation name."
        }
    }
}
