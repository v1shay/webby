import Foundation
import Security
import CryptoKit
import JavaScriptCore

struct CalendarEvent: Codable, Equatable {
    let id: String
    let title: String
    let location: String
    let start: Date
    let end: Date
    let allDay: Bool
}

struct CalendarSnapshot: Codable, Equatable {
    let month: Date
    let events: [CalendarEvent]
    let updated: Date
    let stale: Bool
    let limited: Bool
    let upcoming: [CalendarEvent]
    init(month: Date, events: [CalendarEvent], updated: Date, stale: Bool, limited: Bool, upcoming: [CalendarEvent] = []) {
        self.month=month;self.events=events;self.updated=updated;self.stale=stale;self.limited=limited;self.upcoming=upcoming
    }
}

enum CalendarFeedError: LocalizedError {
    case missing, invalid, network, parse, keychain
    var errorDescription: String? {
        switch self {
        case .missing: "Let’s connect a private calendar feed."
        case .invalid: "Let’s use a Google Calendar HTTPS iCal link."
        case .network: "We couldn’t refresh your calendar. Try again shortly."
        case .parse: "We couldn’t read this calendar feed."
        case .keychain: "We couldn’t save the calendar link in Keychain."
        }
    }
}

// Secrets are per profile, in Keychain, never in defaults, bundled resources or Git.
enum CalendarSubscription {
    private static func query(_ profile: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.plainwebkit.calendar-feed",
         kSecAttrAccount as String: profile.uuidString]
    }
    static func url(profile: UUID) -> URL? {
        var q = query(profile)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: text)
    }
    static func remove(profile: UUID) { SecItemDelete(query(profile) as CFDictionary); CalendarSnapshotCache.remove(profile) }
    static func save(_ text: String, profile: UUID) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", url.host == "calendar.google.com",
              url.path.hasPrefix("/calendar/ical/"), url.path.hasSuffix(".ics"),
              url.user == nil, url.password == nil else { throw CalendarFeedError.invalid }
        let q = query(profile)
        let values = [kSecValueData as String: Data(text.utf8)]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q.merging(values) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CalendarFeedError.keychain }
        CalendarSnapshotCache.remove(profile)
    }
}

actor CalendarFeed {
    static let shared = CalendarFeed()
    private struct Cached {
        let url: URL
        let source: String
        let updated: Date
    }
    private var cache: [UUID: Cached] = [:]
    private var snapshots: [String: CalendarSnapshot] = [:]
    private var pending: [UUID: Task<Cached, Error>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func invalidate(profile: UUID) {
        cache.removeValue(forKey: profile)
        pending.removeValue(forKey: profile)?.cancel()
        snapshots = snapshots.filter { !$0.key.hasPrefix(profile.uuidString) }
    }

    func load(profile: UUID, month: Date = Date()) async throws -> CalendarSnapshot {
        guard let url = CalendarSubscription.url(profile: profile) else { throw CalendarFeedError.missing }
        var stale = false
        let feed: Cached
        if let existing = cache[profile], existing.url == url, Date().timeIntervalSince(existing.updated) < 300 {
            feed = existing
        } else {
            let task = pending[profile] ?? Task { [session] in
                let request = URLRequest(url: url)
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          data.count <= 12_000_000, let source = String(data: data, encoding: .utf8),
                          source.contains("BEGIN:VCALENDAR") else { throw CalendarFeedError.parse }
                    return Cached(url: url, source: source, updated: Date())
                } catch { throw CalendarFeedError.network } // Never surface the secret URL in errors.
            }
            pending[profile] = task
            do { feed = try await task.value; cache[profile] = feed; pending[profile] = nil }
            catch {
                pending[profile] = nil
                guard let existing = cache[profile], existing.url == url else { throw error }
                feed = existing; stale = true
            }
        }
        // This actor runs away from the UI actor, including recurrence expansion.
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let from = cal.date(byAdding: .day, value: -7, to: first)!
        let to = cal.date(byAdding: .day, value: 42, to: first)!
        let key = profile.uuidString + String(first.timeIntervalSince1970)
        if let snapshot = snapshots[key], snapshot.updated == feed.updated, snapshot.stale == stale { return snapshot }
        let result = try Self.parse(feed.source, from: from, to: to)
        let snapshot = CalendarSnapshot(month: first, events: result.events, updated: feed.updated, stale: stale, limited: result.limited, upcoming: result.upcoming)
        if snapshots.count > 12 { snapshots.removeAll() }
        guard CalendarSubscription.url(profile:profile) == url else { throw CalendarFeedError.missing }
        snapshots[key] = snapshot
        CalendarSnapshotCache.save(snapshot,profile:profile,url:url)
        return snapshot
    }

    struct Parsed: Decodable { let events: [CalendarEvent]; let upcoming: [CalendarEvent]; let limited: Bool }
    static func parse(_ source: String, from: Date, to: Date, upcomingFrom: Date = Date(), resources: URL = Bundle.main.resourceURL!) throws -> Parsed {
        guard let context = JSContext(),
              let library = try? String(contentsOf: resources.appendingPathComponent("ical.es5.min.cjs")),
              let parser = try? String(contentsOf: resources.appendingPathComponent("CalendarFeed.js")) else { throw CalendarFeedError.parse }
        context.evaluateScript(library)
        context.evaluateScript(parser)
        guard context.exception == nil,
              let value = context.objectForKeyedSubscript("webbyCalendarParse")?.call(withArguments:
                [source, from.timeIntervalSince1970 * 1000, to.timeIntervalSince1970 * 1000, upcomingFrom.timeIntervalSince1970 * 1000]),
              context.exception == nil, let text = value.toString(), let data = text.data(using: .utf8) else { throw CalendarFeedError.parse }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Parsed.self, from: data)
    }
}

// Persist only parsed events; the private subscription URL stays in Keychain.
enum CalendarSnapshotCache {
    private struct Record: Codable { let source: String; let snapshot: CalendarSnapshot }
    private static func key(_ profile: UUID) -> String { "webbyCalendarSnapshot.v1." + profile.uuidString }
    private static func fingerprint(_ url: URL) -> String {
        SHA256.hash(data:Data(url.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    static func remove(_ profile: UUID) { UserDefaults.standard.removeObject(forKey:key(profile)) }
    static func save(_ snapshot: CalendarSnapshot, profile: UUID, url: URL) {
        guard Calendar.current.isDate(snapshot.month,equalTo:Date(),toGranularity:.month) else { return }
        guard let data = try? JSONEncoder().encode(Record(source:fingerprint(url),snapshot:snapshot)),
              data.count <= 2_000_000 else { return }
        UserDefaults.standard.set(data,forKey:key(profile))
    }
    static func read(profile: UUID, month: Date = Date()) -> CalendarSnapshot? {
        guard let url = CalendarSubscription.url(profile:profile) else { return nil }
        return read(profile:profile,url:url,month:month)
    }
    static func read(profile: UUID, url: URL, month: Date) -> CalendarSnapshot? {
        guard let data = UserDefaults.standard.data(forKey:key(profile)), data.count <= 2_000_000,
              let record = try? JSONDecoder().decode(Record.self,from:data), record.source == fingerprint(url),
              Calendar.current.isDate(record.snapshot.month,equalTo:month,toGranularity:.month) else { return nil }
        let s = record.snapshot
        return CalendarSnapshot(month:s.month,events:s.events,updated:s.updated,stale:true,limited:s.limited,upcoming:s.upcoming)
    }
}
