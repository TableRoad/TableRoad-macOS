import CommonCrypto
import CryptoKit
import Foundation
import TableRoadCore

/// A folder of connections on the Welcome window.
public struct ConnectionGroup: Codable, Sendable, Hashable, Identifiable {
    public enum Icon: Codable, Sendable, Hashable {
        /// An SF Symbol name.
        case symbol(String)
        /// A small image the user picked (PNG data, already resized).
        case image(Data)
    }

    public var id: UUID
    public var name: String
    public var icon: Icon
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, icon: Icon = .symbol("folder.fill"), isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
    }
}

/// Connections exported to a `.tableroad` file. SSH/TLS key files are referenced by path only, never embedded.
public struct ConnectionBundle: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var profile: ConnectionProfile
        public var password: String?
        public var sshPassword: String?
    }

    public var groups: [ConnectionGroup]
    public var connections: [Entry]

    public init(groups: [ConnectionGroup], connections: [Entry]) {
        self.groups = groups
        self.connections = connections
    }
}

public enum ConnectionFileError: Error, Equatable, CustomStringConvertible {
    case notATableRoadFile
    case passwordRequired
    case wrongPassword
    case newerVersion(Int)

    public var description: String {
        switch self {
        case .notATableRoadFile: "This isn't a TableRoad connections file."
        case .passwordRequired: "This file is protected. Enter its password."
        case .wrongPassword: "The password is wrong, or the file is damaged."
        case .newerVersion(let version): "This file was made by a newer TableRoad (format \(version))."
        }
    }
}

/// The `.tableroad` file: JSON, with the bundle encrypted (AES-256-GCM, key from PBKDF2-SHA256) when a password
/// is given. Passwords in the bundle are only ever written encrypted.
public enum ConnectionFile {
    static let format = "tableroad-connections"
    static let version = 1
    static let iterations: UInt32 = 310_000

    struct Envelope: Codable {
        var format: String
        var version: Int
        /// Plain bundle (no password).
        var bundle: ConnectionBundle?
        /// Encrypted bundle: salt + AES-GCM combined (nonce, ciphertext, tag), base64.
        var salt: Data?
        var sealed: Data?
    }

    public static func encode(_ bundle: ConnectionBundle, password: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var envelope = Envelope(format: format, version: version)
        if let password, !password.isEmpty {
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let key = try deriveKey(password, salt: salt)
            envelope.salt = salt
            envelope.sealed = try AES.GCM.seal(encoder.encode(bundle), using: key).combined
        } else {
            // Without a password, secrets are stripped so they can't leak in plain text.
            var stripped = bundle
            stripped.connections = bundle.connections.map {
                ConnectionBundle.Entry(profile: $0.profile, password: nil, sshPassword: nil)
            }
            envelope.bundle = stripped
        }
        return try encoder.encode(envelope)
    }

    /// Whether the file needs a password to open.
    public static func isEncrypted(_ data: Data) throws -> Bool {
        try envelope(data).sealed != nil
    }

    public static func decode(_ data: Data, password: String?) throws -> ConnectionBundle {
        let envelope = try envelope(data)
        if let bundle = envelope.bundle { return bundle }
        guard let sealed = envelope.sealed, let salt = envelope.salt else {
            throw ConnectionFileError.notATableRoadFile
        }
        guard let password, !password.isEmpty else { throw ConnectionFileError.passwordRequired }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: deriveKey(password, salt: salt))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConnectionBundle.self, from: plain)
        } catch {
            throw ConnectionFileError.wrongPassword
        }
    }

    private static func envelope(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.format == format else {
            throw ConnectionFileError.notATableRoadFile
        }
        guard envelope.version <= version else { throw ConnectionFileError.newerVersion(envelope.version) }
        return envelope
    }

    static func deriveKey(_ password: String, salt: Data) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, passwordBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations, &key, key.count)
        }
        guard status == kCCSuccess else { throw ConnectionFileError.wrongPassword }
        return SymmetricKey(data: key)
    }
}
