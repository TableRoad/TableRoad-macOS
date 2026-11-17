/// CREATE / DROP DATABASE statements (MySQL & MariaDB).
extension MySQLDialect {
    /// `CREATE DATABASE `name` [CHARACTER SET x] [COLLATE y]`. Character set and collation must be plain names
    /// (letters, digits, underscores); anything else is rejected rather than spliced into SQL.
    public func createDatabaseSQL(_ name: String, characterSet: String? = nil, collation: String? = nil) throws
        -> String
    {
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
