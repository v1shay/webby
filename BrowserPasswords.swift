import AppKit
import Foundation
import Security
import SQLite3

struct BrowserCredential {
    let host: String
    let username: String
    let password: String
}

enum BrowserPasswords {
    private static let service = "local.plainwebkit.browser.passwords"

    static func credentials(in space: UUID, host: String? = nil) -> [BrowserCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        let prefix = space.uuidString + "|"
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix),
                  let data = row[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            let parts = account.dropFirst(prefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let domain = String(parts[0])
            guard host == nil || domain == host else { return nil }
            return BrowserCredential(host: domain, username: String(parts[1]), password: password)
        }.sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    static func save(_ credential: BrowserCredential, in space: UUID) -> OSStatus {
        let account = "\(space.uuidString)|\(credential.host)|\(credential.username)"
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        let data = Data(credential.password.utf8)
        let status = SecItemAdd(key.merging([kSecValueData as String: data,
                                              kSecAttrLabel as String: credential.host]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status
    }

    static func delete(_ credential: BrowserCredential, in space: UUID) -> OSStatus {
        let account = "\(space.uuidString)|\(credential.host)|\(credential.username)"
        return SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: service,
                              kSecAttrAccount as String: account] as CFDictionary)
    }

    static func deleteAll(in space: UUID) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecMatchLimit as String: kSecMatchLimitAll,
                                     kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        let lookup = SecItemCopyMatching(query as CFDictionary, &result)
        if lookup == errSecItemNotFound { return errSecSuccess }
        guard lookup == errSecSuccess, let rows = result as? [[String: Any]] else { return lookup }
        let prefix = space.uuidString + "|"
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: account] as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { return status }
        }
        return errSecSuccess
    }

    static func importChromeCSV(_ url: URL, into space: UUID) throws -> (saved: Int, skipped: Int) {
        // Chrome's export is plaintext. Read it directly and never copy it into app storage.
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportError.invalidCSV }
        let names = header.map {
            $0.replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let urlIndex = names.firstIndex(of: "url"),
              let userIndex = names.firstIndex(of: "username"),
              let passwordIndex = names.firstIndex(of: "password") else { throw ImportError.invalidCSV }
        var saved = 0, skipped = 0
        for row in rows.dropFirst() {
            guard row.count > max(urlIndex, userIndex, passwordIndex),
                  let website = URL(string: row[urlIndex]),
                  website.scheme?.lowercased() == "https",
                  let host = website.host?.lowercased(), !host.isEmpty,
                  !row[passwordIndex].isEmpty else { skipped += 1; continue }
            let status = save(BrowserCredential(host: host, username: row[userIndex],
                                                password: row[passwordIndex]), in: space)
            if status == errSecSuccess { saved += 1 } else { skipped += 1 }
        }
        return (saved, skipped)
    }

    static func readChromePasswords(from source: ChromeProfileSource, key: Data) throws -> [BrowserCredential] {
        var byAccount: [String: BrowserCredential] = [:]
        var encryptedCount = 0
        var decryptedCount = 0
        for name in ["Login Data", "Login Data For Account"] {
            let file = source.url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChromePasswords-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let snapshot = temporary.appendingPathComponent(name)
            try FileManager.default.copyItem(at: file, to: snapshot)
            for suffix in ["-wal", "-shm", "-journal"] {
                let sourceSidecar = URL(fileURLWithPath: file.path + suffix)
                if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                    try? FileManager.default.copyItem(at: sourceSidecar,
                                                      to: URL(fileURLWithPath: snapshot.path + suffix))
                }
            }
            var database: OpaquePointer?
            guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database else { sqlite3_close(database); throw ImportError.unreadableChromeStore }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            let query = "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0"
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { sqlite3_finalize(statement); throw ImportError.unreadableChromeStore }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let urlBytes = sqlite3_column_text(statement, 0),
                      let usernameBytes = sqlite3_column_text(statement, 1) else { continue }
                let address = String(cString: urlBytes), username = String(cString: usernameBytes)
                if sqlite3_column_bytes(statement, 2) > 3 { encryptedCount += 1 }
                guard let url = URL(string: address), url.scheme?.lowercased() == "https",
                      let host = url.host?.lowercased(), !host.isEmpty,
                      sqlite3_column_bytes(statement, 2) > 3,
                      let bytes = sqlite3_column_blob(statement, 2),
                      let decrypted = ChromeSessions.decryptValue(
                        Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))), key: key),
                      let password = String(data: decrypted, encoding: .utf8), !password.isEmpty else { continue }
                decryptedCount += 1
                byAccount[host + "|" + username] = BrowserCredential(host: host, username: username,
                                                                        password: password)
            }
        }
        if encryptedCount > 0 && decryptedCount == 0 { throw ImportError.couldNotDecrypt }
        return Array(byAccount.values)
    }

    enum ImportError: LocalizedError {
        case invalidCSV
        case unreadableChromeStore
        case couldNotDecrypt
        var errorDescription: String? {
            switch self {
            case .invalidCSV: "Choose a Chrome password CSV with url, username, and password columns."
            case .unreadableChromeStore: "Chrome's password database could not be read. Quit Chrome and retry."
            case .couldNotDecrypt: "Chrome passwords were found, but its macOS Keychain key could not decrypt them. Allow Chrome Safe Storage access and retry."
            }
        }
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        // Swift treats CRLF as one Character, so normalize line endings first.
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty { quoted = true }
            else if character == "," { row.append(field); field = "" }
            else if character == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(character) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
