import CommonCrypto
import CryptoKit
import Foundation
import TableRoadCore

/// O5LOGON: the server sends its half of a session key encrypted with a key derived from the password verifier;
/// the client decrypts it, sends its own half encrypted the same way, and both derive a combined key that encrypts
/// the password. 12c verifiers use PBKDF2-SHA512; 11g verifiers use salted SHA-1.
enum OracleAuth {
    static let verifier11g1: UInt32 = 0xb152
    static let verifier11g2: UInt32 = 0x1b25
    static let verifier12c: UInt32 = 0x4815

    /// The phase-two values sent back to the server.
    struct Response {
        var sessionKey: String
        var speedyKey: String?
        var encodedPassword: String
    }

    static func respond(
        password: String, verifierType: UInt32, session: [String: String], randomBytes: (Int) -> [UInt8] = random
    ) throws -> Response {
        guard let verifierData = session["AUTH_VFR_DATA"].flatMap(hexBytes),
            let serverKey = session["AUTH_SESSKEY"].flatMap(hexBytes)
        else { throw OracleProtocolError("the server's logon challenge is incomplete") }
        let passwordBytes = Array(password.utf8)

        let keyLength: Int
        let passwordHash: [UInt8]
        var passwordKey: [UInt8] = []
        switch verifierType {
        case verifier12c:
            keyLength = 32
            guard let iterations = session["AUTH_PBKDF2_VGEN_COUNT"].flatMap({ Int($0) }) else {
                throw OracleProtocolError("missing AUTH_PBKDF2_VGEN_COUNT")
            }
            passwordKey = pbkdf2SHA512(
                passwordBytes, salt: verifierData + Array("AUTH_PBKDF2_SPEEDY_KEY".utf8), length: 64,
                iterations: iterations)
            passwordHash = Array(SHA512.hash(data: passwordKey + verifierData)).prefix(32).map { $0 }
        case verifier11g1, verifier11g2:
            keyLength = 24
            passwordHash = Array(Insecure.SHA1.hash(data: passwordBytes + verifierData)) + [0, 0, 0, 0]
        default:
            throw DatabaseError(
                .authentication,
                "This account's password verifier (type 0x\(String(verifierType, radix: 16))) isn't supported. "
                    + "Oracle 10g verifiers need the password to be reset on a current server.")
        }

        // Server half of the session key, then our half encrypted the same way.
        let serverHalf = try aesCBC(decrypt: true, key: passwordHash, data: serverKey)
        let clientHalf = randomBytes(serverHalf.count)
        let encodedClientHalf = try aesCBC(decrypt: false, key: passwordHash, data: pad(clientHalf))

        let sessionKey: String
        let comboKey: [UInt8]
        if serverHalf.count == 48 {
            // 11g: MD5 of the XOR of both halves (bytes 16..<40).
            sessionKey = String(hex(encodedClientHalf).prefix(96))
            let mixed = (16..<40).map { serverHalf[$0] ^ clientHalf[$0] }
            let part1 = Array(Insecure.MD5.hash(data: mixed[0..<16]))
            let part2 = Array(Insecure.MD5.hash(data: mixed[16...]))
            comboKey = Array((part1 + part2).prefix(keyLength))
        } else {
            sessionKey = String(hex(encodedClientHalf).prefix(64))
            guard let salt = session["AUTH_PBKDF2_CSK_SALT"].flatMap(hexBytes),
                let iterations = session["AUTH_PBKDF2_SDER_COUNT"].flatMap({ Int($0) })
            else { throw OracleProtocolError("missing AUTH_PBKDF2_CSK_SALT") }
            let temp = Array(clientHalf.prefix(keyLength)) + Array(serverHalf.prefix(keyLength))
            comboKey = pbkdf2SHA512(Array(hex(temp).utf8), salt: salt, length: keyLength, iterations: iterations)
        }

        var speedyKey: String?
        if verifierType == verifier12c {
            let encrypted = try aesCBC(decrypt: false, key: comboKey, data: pad(randomBytes(16) + passwordKey))
            speedyKey = hex(Array(encrypted.prefix(80)))
        }
        let encryptedPassword = try aesCBC(decrypt: false, key: comboKey, data: pad(randomBytes(16) + passwordBytes))
        return Response(sessionKey: sessionKey, speedyKey: speedyKey, encodedPassword: hex(encryptedPassword))
    }

    /// Padding as the server expects: always 1–16 bytes, each holding the pad length.
    static func pad(_ data: [UInt8]) -> [UInt8] {
        let n = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(n), count: n)
    }

    static func aesCBC(decrypt: Bool, key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let outputCount = output.count
        let status = CCCrypt(
            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), key,
            key.count, iv, data, data.count, &output, outputCount, &moved)
        guard status == kCCSuccess else { throw OracleProtocolError("AES failed (\(status))") }
        return Array(output.prefix(moved))
    }

    static func pbkdf2SHA512(_ password: [UInt8], salt: [UInt8], length: Int, iterations: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: length)
        _ = password.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: Int8.self) { passwordChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, password.count, salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations), &derived, length)
            }
        }
        return derived
    }

    static func random(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func hexBytes(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(decoding: chars[index..<(index + 2)], as: UTF8.self), radix: 16) else {
                return nil
            }
            result.append(byte)
            index += 2
        }
        return result
    }
}
