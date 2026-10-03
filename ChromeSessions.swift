import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3
import WebKit

enum ChromeSessions {
    enum ImportError: LocalizedError {
        case keyUnavailable
        case databaseUnavailable
        var errorDescription: String? {
            switch self {
            case .keyUnavailable: "Chrome's Safe Storage key could not be read from your macOS Keychain. Allow access when macOS asks, then retry."
            case .databaseUnavailable: "Chrome's cookie database could not be read. Quit Chrome and try again."
            }
        }
    }

    static func encryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data else { throw ImportError.keyUnavailable }
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                "saltysalt".utf8CString.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                                        password.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                                        9, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                        keyBytes.bindMemory(to: UInt8.self).baseAddress, 16)
                }
            }
        }
        guard status == kCCSuccess else { throw ImportError.keyUnavailable }
        return key
    }

    static func readCookies(from source: ChromeProfileSource, key: Data) throws -> [HTTPCookie] {
        let file = source.url.appendingPathComponent("Cookies")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeCookies-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("Cookies")
        do { try FileManager.default.copyItem(at: file, to: snapshot) }
        catch { throw ImportError.databaseUnavailable }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar,
                                                  to: URL(fileURLWithPath: snapshot.path + suffix))
            }
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { sqlite3_close(database); throw ImportError.databaseUnavailable }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT host_key, name, encrypted_value, path, expires_utc, is_secure, is_httponly, top_frame_site_key, has_expires FROM cookies"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { sqlite3_finalize(statement); throw ImportError.databaseUnavailable }
        defer { sqlite3_finalize(statement) }
        let now = Date()
        var cookies: [HTTPCookie] = []
        var encryptedCount = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hostBytes = sqlite3_column_text(statement, 0),
                  let nameBytes = sqlite3_column_text(statement, 1),
                  let pathBytes = sqlite3_column_text(statement, 3) else { continue }
            let host = String(cString: hostBytes), name = String(cString: nameBytes)
            let path = String(cString: pathBytes)
            if let partition = sqlite3_column_text(statement, 7), !String(cString: partition).isEmpty { continue }
            let expiresRaw = sqlite3_column_int64(statement, 4)
            let expires = Date(timeIntervalSince1970: Double(expiresRaw) / 1_000_000 - 11_644_473_600)
            let hasExpires = sqlite3_column_int(statement, 8) != 0
            if hasExpires && expires <= now { continue }
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 3, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            encryptedCount += 1
            let encrypted = Data(bytes: bytes, count: length)
            guard let plaintext = decryptValue(encrypted, key: key) else { continue }
            let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.count >= hostHash.count,
                  plaintext.prefix(hostHash.count).elementsEqual(hostHash),
                  let value = String(data: plaintext.dropFirst(hostHash.count), encoding: .utf8) else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .name: name, .value: value, .path: path
            ]
            if hasExpires { properties[.expires] = expires }
            if sqlite3_column_int(statement, 5) != 0 { properties[.secure] = "TRUE" }
            if sqlite3_column_int(statement, 6) != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
        }
        if encryptedCount > 0 && cookies.isEmpty { throw ImportError.keyUnavailable }
        return cookies
    }

    static func decryptValue(_ encrypted: Data, key: Data) -> Data? {
        guard encrypted.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = encrypted.dropFirst(3)
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var length: size_t = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
                    return iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, inputBytes.baseAddress, ciphertext.count,
                                outputBytes.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = length
        return output
    }
}
