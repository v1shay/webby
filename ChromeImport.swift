import Foundation
import SQLite3
import WebKit

struct BrowserLink: Codable {
    let title: String
    let url: String
    let visitedAt: Date?
}

struct SavedBrowserSpace: Codable {
    let id: UUID
    let name: String
    let chromeDirectory: String?
    let bookmarks: [BrowserLink]
    let history: [BrowserLink]
}

@MainActor final class BrowserSpace {
    var saved: SavedBrowserSpace
    var tabs: [BrowserTab] = []
    var activeTabID: UUID?
    private var cachedDataStore: WKWebsiteDataStore?

    init(_ saved: SavedBrowserSpace) { self.saved = saved }

    func recordVisit(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var visits = saved.history
        visits.removeAll { $0.url == url.absoluteString }
        visits.insert(BrowserLink(title: title, url: url.absoluteString, visitedAt: Date()), at: 0)
        if visits.count > 10000 { visits.removeLast(visits.count - 10000) }
        saved = SavedBrowserSpace(id: saved.id, name: saved.name,
                                  chromeDirectory: saved.chromeDirectory,
                                  bookmarks: saved.bookmarks, history: visits)
    }

    var dataStore: WKWebsiteDataStore {
        guard saved.chromeDirectory != nil else { return .default() }
        if let cachedDataStore { return cachedDataStore }
        let store: WKWebsiteDataStore
        if #available(macOS 14, *) { store = WKWebsiteDataStore(forIdentifier: saved.id) }
        else { store = .nonPersistent() }
        cachedDataStore = store
        return store
    }
}

enum BrowserSpaceStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WebKit Browser", isDirectory: true)
            .appendingPathComponent("ChromeSpaces.json")
    }

    static func load() -> [SavedBrowserSpace] {
        guard let data = try? Data(contentsOf: fileURL),
              let spaces = try? JSONDecoder().decode([SavedBrowserSpace].self, from: data),
              !spaces.isEmpty else { return [] }
        return spaces
    }

    static func save(_ spaces: [SavedBrowserSpace]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(spaces).write(to: fileURL, options: .atomic)
    }
}

struct ChromeProfileSource {
    let directory: String
    let name: String
    let url: URL
}

enum ChromeProfileImporter {
    static var chromeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static func availableProfiles() -> [ChromeProfileSource] {
        let stateURL = chromeRoot.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = state["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.compactMap { directory, info in
            let folder = chromeRoot.appendingPathComponent(directory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return ChromeProfileSource(directory: directory,
                                       name: info["name"] as? String ?? directory, url: folder)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func `import`(_ source: ChromeProfileSource, reusing id: UUID? = nil) -> SavedBrowserSpace {
        SavedBrowserSpace(id: id ?? UUID(), name: source.name, chromeDirectory: source.directory,
                          bookmarks: readBookmarks(source.url.appendingPathComponent("Bookmarks")),
                          history: readHistory(source.url.appendingPathComponent("History")))
    }

    private static func readBookmarks(_ file: URL) -> [BrowserLink] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var links: [BrowserLink] = []
        func visit(_ node: [String: Any]) {
            if let type = node["type"] as? String, type == "url",
               let address = node["url"] as? String,
               let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") {
                links.append(BrowserLink(title: node["name"] as? String ?? address,
                                         url: address, visitedAt: nil))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { visit(node) }
        }
        return links
    }

    private static func readHistory(_ file: URL) -> [BrowserLink] {
        if let links = queryHistory(file) { return links }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeHistory-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)) != nil else { return [] }
        let snapshot = temporary.appendingPathComponent("History")
        guard (try? FileManager.default.copyItem(at: file, to: snapshot)) != nil else { return [] }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar,
                                                  to: URL(fileURLWithPath: snapshot.path + suffix))
            }
        }
        return queryHistory(snapshot) ?? []
    }

    private static func queryHistory(_ file: URL) -> [BrowserLink]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { sqlite3_close(database); return nil }
        defer { sqlite3_close(database) }
        let query = "SELECT url, title, last_visit_time FROM urls ORDER BY last_visit_time DESC LIMIT 10000"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { sqlite3_finalize(statement); return nil }
        defer { sqlite3_finalize(statement) }
        var links: [BrowserLink] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(statement) }
            guard let urlBytes = sqlite3_column_text(statement, 0) else { continue }
            let address = String(cString: urlBytes)
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? address
            let chromeTime = sqlite3_column_int64(statement, 2)
            let date = Date(timeIntervalSince1970: Double(chromeTime) / 1_000_000 - 11_644_473_600)
            links.append(BrowserLink(title: title.isEmpty ? (url.host ?? address) : title,
                                     url: address, visitedAt: date))
        }
        return result == SQLITE_DONE ? links : nil
    }
}
