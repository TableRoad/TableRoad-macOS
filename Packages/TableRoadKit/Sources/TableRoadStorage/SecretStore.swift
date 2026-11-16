import Foundation
import Security

/// Which secret belongs to a connection.
public enum SecretKind: String, Sendable, CaseIterable {
    case databasePassword
    case sshPassword
    case sshKeyPassphrase
}

/// Stores connection secrets. Never persisted in `ConnectionProfile`.
public protocol SecretStore: Sendable {
    func secret(_ kind: SecretKind, for connection: UUID) throws -> String?
    func setSecret(_ value: String?, _ kind: SecretKind, for connection: UUID) throws
    func removeAll(for connection: UUID) throws
}

public struct SecretStoreError: Error, LocalizedError, Hashable {
    public var status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Local (non-synchronising) Keychain storage: one generic-password item per connection and secret kind.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    /// The data-protection keychain needs a team-signed app; ad-hoc dev builds must use the login keychain.
    public let useDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: Keychain service name, normally `<bundle id>.connections`.
    ///   - useDataProtectionKeychain: Turn on once builds are signed with the Developer ID team.
    public init(service: String, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func baseQuery(_ kind: SecretKind, _ connection: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(connection.uuidString).\(kind.rawValue)",
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
    }

    public func secret(_ kind: SecretKind, for connection: UUID) throws -> String? {
        var query = baseQuery(kind, connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, _ kind: SecretKind, for connection: UUID) throws {
        let query = baseQuery(kind, connection)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(status: status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "TableRoad connection secret"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        } else if update != errSecSuccess {
            throw SecretStoreError(status: update)
        }
    }

    public func removeAll(for connection: UUID) throws {
        for kind in SecretKind.allCases { try setSecret(nil, kind, for: connection) }
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(_ kind: SecretKind, for connection: UUID) throws -> String? {
        lock.withLock { values["\(connection).\(kind)"] }
    }

    public func setSecret(_ value: String?, _ kind: SecretKind, for connection: UUID) throws {
        lock.withLock { values["\(connection).\(kind)"] = value }
    }

    public func removeAll(for connection: UUID) throws {
        lock.withLock { values = values.filter { !$0.key.hasPrefix(connection.uuidString) } }
    }
}
