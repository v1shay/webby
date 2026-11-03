import AppKit
import Security

enum GitHubWidgetKind: String, CaseIterable, Codable, Sendable {
    case prs, contributions, recent, repos, issues, stars, news
    var title: String {
        switch self {
        case .prs: "Open PRs"
        case .contributions: "Contributions"
        case .recent: "Recently Visited"
        case .repos: "Repositories"
        case .issues: "Assigned Issues"
        case .stars: "Starred Repos"
        case .news: "GitHub Activity"
        }
    }
    var symbol: String {
        switch self {
        case .prs: "arrow.triangle.pull"
        case .contributions: "square.grid.3x3.fill"
        case .recent: "clock.arrow.circlepath"
        case .repos: "book.closed"
        case .issues: "circle.inset.filled"
        case .stars: "star"
        case .news: "point.3.connected.trianglepath.dotted"
        }
    }
    func destination(login: String) -> URL {
        let base = "https://github.com"
        switch self {
        case .prs: return URL(string: base+"/pulls")!
        case .issues: return URL(string: base+"/issues/assigned")!
        case .stars: return URL(string: base+"/"+login+"?tab=stars")!
        case .repos, .recent: return URL(string: base+"/"+login+"?tab=repositories")!
        case .contributions: return URL(string: base+"/"+login)!
        case .news: return URL(string: base+"/dashboard")!
        }
    }
}

struct GitHubWidgetRow: Codable, Equatable, Sendable {
    let title: String
    let detail: String
    let url: String
    let symbol: String
}
struct GitHubContributionDay: Codable, Equatable, Sendable {
    let date: String
    let contributionCount: Int
    let weekday: Int
}
struct GitHubWidgetSnapshot: Codable, Equatable, Sendable {
    var login: String
    var rows: [GitHubWidgetRow]
    var days: [GitHubContributionDay] = []
    var total: Int
    var updated: Date
}

enum GitHubWidgetError: LocalizedError {
    case disconnected, unauthorized, permission, limited, response, keychain, graphql
    var errorDescription: String? {
        switch self {
        case .disconnected: "Let’s connect GitHub."
        case .unauthorized: "This token expired or was revoked. Let’s reconnect."
        case .permission: "This token can’t read this data. Check its repository permissions."
        case .limited: "GitHub asked us to pause. We’ll try again later."
        case .response: "We couldn’t refresh GitHub. Your saved data is still here."
        case .keychain: "We couldn’t save the token in Keychain."
        case .graphql: "GitHub couldn’t return the contribution graph. Check your token’s access."
        }
    }
}

private enum GitHubCredential {
    static func query(_ profile: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.plainwebkit.github-widgets",
         kSecAttrAccount as String: profile.uuidString]
    }
    static func read(_ profile: UUID) -> String? {
        var q = query(profile)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, profile: UUID) throws {
        let q = query(profile), values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q.merging(values) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitHubWidgetError.keychain }
    }
    static func remove(_ profile: UUID) throws {
        let status = SecItemDelete(query(profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubWidgetError.keychain }
    }
}

// Never forward an Authorization header to redirects, even if an API changes hosts.
private final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// One actor owns requests, credentials and bounded disk snapshots. No networking or
// filesystem work is performed by layout/drawing or on the browser's main actor.
actor GitHubWidgetStore {
    static let shared = GitHubWidgetStore()
    private struct Key: Hashable { let profile: UUID; let kind: GitHubWidgetKind }
    private var snapshots: [Key: GitHubWidgetSnapshot] = [:]
    private var loaded = Set<Key>()
    private var credentials: [UUID: String] = [:]
    private var credentialLoaded = Set<UUID>()
    private var logins: [UUID: String] = [:]
    private var pending: [Key: Task<GitHubWidgetSnapshot, Error>] = [:]
    private var loginPending: [UUID: Task<String, Error>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var retryAfter: [Key: Date] = [:]
    private var accountRetry: [UUID: Date] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: GitHubRedirectGuard(), delegateQueue: nil)
    }()
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Webby/GitHub Widgets", isDirectory: true)
    }
    private func file(_ key: Key) -> URL {
        directory.appendingPathComponent(key.profile.uuidString+"-"+key.kind.rawValue+".json")
    }
    private func write(_ value: GitHubWidgetSnapshot, key: Key) {
        snapshots[key] = value; loaded.insert(key)
        guard let data = try? JSONEncoder().encode(value), data.count < 600_000 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file(key), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
    }
    func cached(profile: UUID, kind: GitHubWidgetKind) -> GitHubWidgetSnapshot? {
        let key = Key(profile: profile, kind: kind)
        if !loaded.contains(key) {
            loaded.insert(key)
            if let data = try? Data(contentsOf: file(key)), data.count < 600_000,
               let value = try? JSONDecoder().decode(GitHubWidgetSnapshot.self, from: data) { snapshots[key] = value }
        }
        return snapshots[key]
    }
    func connected(_ profile: UUID) -> Bool { token(profile) != nil }
    private func token(_ profile: UUID) -> String? {
        if credentialLoaded.insert(profile).inserted { credentials[profile] = GitHubCredential.read(profile) }
        return credentials[profile]
    }
    func connect(_ input: String, profile: UUID) async throws {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20, token.count < 512, !token.contains(where: { $0.isWhitespace }) else { throw GitHubWidgetError.unauthorized }
        let generation = UUID(); generations[profile] = generation
        let data = try await request("/user", token: token)
        let user = try JSONDecoder().decode(User.self, from: data)
        guard generations[profile] == generation else { throw CancellationError() }
        try GitHubCredential.save(token, profile: profile)
        clearRemote(profile)
        credentials[profile] = token; credentialLoaded.insert(profile); logins[profile] = user.login
    }
    func disconnect(_ profile: UUID) throws {
        try GitHubCredential.remove(profile)
        generations[profile] = UUID(); clearRemote(profile)
        credentials.removeValue(forKey: profile); credentialLoaded.insert(profile)
    }
    func deleteProfile(_ profile: UUID) {
        // Profile deletion is also a local-data deletion, including visited repos.
        try? GitHubCredential.remove(profile)
        generations[profile] = UUID(); clearRemote(profile)
        credentials.removeValue(forKey:profile); credentialLoaded.insert(profile)
        let key = Key(profile:profile,kind:.recent)
        snapshots.removeValue(forKey:key); loaded.remove(key)
        try? FileManager.default.removeItem(at:file(key))
    }
    private func clearRemote(_ profile: UUID) {
        for kind in GitHubWidgetKind.allCases where kind != .recent {
            let key = Key(profile: profile, kind: kind)
            pending.removeValue(forKey: key)?.cancel()
            snapshots.removeValue(forKey: key); loaded.remove(key); retryAfter.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: file(key))
        }
        loginPending.removeValue(forKey: profile)?.cancel(); logins.removeValue(forKey: profile)
        accountRetry.removeValue(forKey: profile)
    }
    private func login(_ profile: UUID, token: String) async throws -> String {
        if let login = logins[profile] { return login }
        if let task = loginPending[profile] { return try await task.value }
        let generation = generations[profile]
        let task = Task { let data = try await self.request("/user", token: token); return try JSONDecoder().decode(User.self, from: data).login }
        loginPending[profile] = task
        defer { if generations[profile] == generation { loginPending.removeValue(forKey: profile) } }
        let value = try await task.value
        try Task.checkCancellation()
        guard generations[profile] == generation else { throw CancellationError() }
        logins[profile] = value
        return value
    }
    func refresh(profile: UUID, kind: GitHubWidgetKind) async throws -> GitHubWidgetSnapshot {
        if kind == .recent { return cached(profile: profile, kind: kind) ?? .init(login: "", rows: [], total: 0, updated: Date()) }
        let key = Key(profile: profile, kind: kind)
        if let date = accountRetry[profile], date > Date() { throw GitHubWidgetError.limited }
        if let date = retryAfter[key], date > Date() { throw GitHubWidgetError.response }
        if let value = cached(profile: profile, kind: kind), Date().timeIntervalSince(value.updated) < 300 { return value }
        if let task = pending[key] { return try await task.value }
        guard let token = token(profile) else { throw GitHubWidgetError.disconnected }
        let generation = generations[profile] ?? UUID(); generations[profile] = generation
        let task = Task { () throws -> GitHubWidgetSnapshot in
            let login = try await self.login(profile, token: token)
            try Task.checkCancellation()
            return try await self.fetch(kind, login: login, token: token)
        }
        pending[key] = task
        do {
            let value = try await task.value
            guard generations[profile] == generation else { throw CancellationError() }
            pending.removeValue(forKey: key); retryAfter.removeValue(forKey: key)
            write(value, key: key)
            return value
        } catch {
            if generations[profile] == generation {
                pending.removeValue(forKey: key)
                retryAfter[key] = Date().addingTimeInterval(300)
                if case GitHubWidgetError.limited = error { accountRetry[profile] = Date().addingTimeInterval(900) }
            }
            throw error
        }
    }
    private func request(_ path: String, token: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.github.com"+path), url.host == "api.github.com", url.scheme == "https" else { throw GitHubWidgetError.response }
        var request = URLRequest(url: url)
        request.setValue("Bearer "+token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Webby-Widgets", forHTTPHeaderField: "User-Agent")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GitHubWidgetError.response }
        if http.statusCode == 401 { throw GitHubWidgetError.unauthorized }
        if http.statusCode == 429 || (http.statusCode == 403 && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil)) { throw GitHubWidgetError.limited }
        if http.statusCode == 403 || http.statusCode == 404 { throw GitHubWidgetError.permission }
        guard http.statusCode == 200, data.count < 4_000_000 else { throw GitHubWidgetError.response }
        return data
    }
    private struct User: Decodable { let login: String }
    private struct Search: Decodable { let total_count: Int; let items: [Issue] }
    private struct Issue: Decodable { let title: String; let html_url: String; let number: Int; let repository_url: String; let draft: Bool? }
    private struct Repo: Decodable { let full_name: String; let description: String?; let html_url: String; let stargazers_count: Int; let language: String?; let `private`: Bool }
    private struct Event: Decodable {
        struct Actor: Decodable { let login: String }
        struct Repo: Decodable { let name: String }
        let type: String; let actor: Actor; let repo: Repo
    }
    private struct Graph: Decodable {
        struct DataValue: Decodable {
            struct Viewer: Decodable {
                struct Collection: Decodable {
                    struct Calendar: Decodable {
                        struct Week: Decodable { let contributionDays: [GitHubContributionDay] }
                        let totalContributions: Int; let weeks: [Week]
                    }
                    let contributionCalendar: Calendar
                }
                let contributionsCollection: Collection
            }
            let viewer: Viewer?
        }
        let data: DataValue?
    }
    private func fetch(_ kind: GitHubWidgetKind, login: String, token: String) async throws -> GitHubWidgetSnapshot {
        let data: Data
        switch kind {
        case .prs, .issues:
            let query = kind == .prs ? "is:pr is:open author:\(login)" : "is:issue is:open assignee:\(login)"
            var components = URLComponents(); components.queryItems = [.init(name: "q", value: query), .init(name: "sort", value: "updated"), .init(name: "per_page", value: "30")]
            data = try await request("/search/issues?"+(components.percentEncodedQuery ?? ""), token: token)
        case .repos, .stars:
            let path = kind == .repos ? "/user/repos?sort=pushed&per_page=30" : "/user/starred?sort=created&per_page=30"
            data = try await request(path, token: token)
        case .news:
            data = try await request("/users/\(login)/received_events?per_page=30", token: token)
        case .contributions:
            let query = "query { viewer { contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount weekday } } } } } }"
            let body = try JSONSerialization.data(withJSONObject: ["query": query])
            data = try await request("/graphql", token: token, body: body)
        case .recent: data = Data()
        }
        return try Self.decode(kind, data: data, login: login)
    }
    nonisolated static func decode(_ kind: GitHubWidgetKind, data: Data, login: String) throws -> GitHubWidgetSnapshot {
        let decoder = JSONDecoder()
        var rows: [GitHubWidgetRow] = [], days: [GitHubContributionDay] = [], total = 0
        switch kind {
        case .prs, .issues:
            let search = try decoder.decode(Search.self, from: data); total = search.total_count
            rows = search.items.map { item in
                let repo = item.repository_url.replacingOccurrences(of: "https://api.github.com/repos/", with: "")
                return .init(title: item.title, detail: repo+" · #\(item.number)"+(item.draft == true ? " · Draft" : ""), url: item.html_url, symbol: kind.symbol)
            }
        case .repos, .stars:
            let repos = try decoder.decode([Repo].self, from: data); total = repos.count
            rows = repos.map { repo in
                .init(title: repo.full_name, detail: [repo.private ? "Private" : repo.language, repo.description, "★ \(repo.stargazers_count)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), url: repo.html_url, symbol: kind == .stars ? "star" : "book.closed")
            }
        case .news:
            let events = try decoder.decode([Event].self, from: data); total = events.count
            rows = events.map { event in
                let verb: String
                switch event.type {
                case "PushEvent": verb = "pushed to"
                case "WatchEvent": verb = "starred"
                case "ForkEvent": verb = "forked"
                case "PullRequestEvent": verb = "updated a pull request in"
                case "IssuesEvent": verb = "updated an issue in"
                case "ReleaseEvent": verb = "published a release in"
                case "CreateEvent": verb = "created a branch or tag in"
                default: verb = "was active in"
                }
                return .init(title: event.actor.login+" "+verb, detail: event.repo.name, url: "https://github.com/"+event.repo.name, symbol: event.type == "PullRequestEvent" ? "arrow.triangle.pull" : "arrow.triangle.branch")
            }
        case .contributions:
            guard let calendar = try decoder.decode(Graph.self, from: data).data?.viewer?.contributionsCollection.contributionCalendar else { throw GitHubWidgetError.graphql }
            days = Array(calendar.weeks.flatMap(\.contributionDays).filter { (0...6).contains($0.weekday) }.prefix(371)); total = calendar.totalContributions
        case .recent: break
        }
        return .init(login: login, rows: rows, days: days, total: total, updated: Date())
    }
    nonisolated static func repositoryURL(_ url: URL) -> URL? {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let reserved: Set<String> = ["settings", "notifications", "pulls", "issues", "explore", "marketplace", "login", "logout", "signup", "search", "orgs", "users", "organizations", "features", "topics", "collections", "sponsors", "dashboard", "new", "codespaces", "sessions"]
        guard parts.count >= 2, !reserved.contains(parts[0].lowercased()), parts[1] != "new" else { return nil }
        var components = URLComponents(); components.scheme = "https"; components.host = "github.com"; components.path = "/"+parts[0]+"/"+parts[1]
        return components.url
    }
    func recordVisit(_ url: URL, profile: UUID) {
        guard let repo = Self.repositoryURL(url) else { return }
        var value = cached(profile: profile, kind: .recent) ?? .init(login: "", rows: [], total: 0, updated: Date())
        value.rows.removeAll { $0.url == repo.absoluteString }
        value.rows.insert(.init(title: repo.path.dropFirst().description, detail: "Visited in Webby", url: repo.absoluteString, symbol: "book.closed"), at: 0)
        value.rows = Array(value.rows.prefix(30)); value.total = value.rows.count; value.updated = Date()
        write(value, key: .init(profile: profile, kind: .recent))
    }
    func seedRecent(_ links: [String], profile: UUID) -> Bool {
        guard cached(profile:profile,kind:.recent) == nil else { return false }
        var seen = Set<String>(), rows: [GitHubWidgetRow] = []
        for text in links {
            guard let url = URL(string:text),let repo = Self.repositoryURL(url),seen.insert(repo.absoluteString).inserted else { continue }
            rows.append(.init(title:repo.path.dropFirst().description,detail:"Visited in Webby",url:repo.absoluteString,symbol:"book.closed"))
            if rows.count == 30 { break }
        }
        write(.init(login:"",rows:rows,total:rows.count,updated:Date()),key:.init(profile:profile,kind:.recent))
        return true
    }
}

extension Notification.Name { static let webbyGitHubChanged = Notification.Name("webbyGitHubChanged") }

// The credential editor is native and keeps secrets out of page JavaScript/defaults.
@MainActor enum GitHubWidgetConnection {
    static func present(profile: UUID) {
        let alert = NSAlert()
        alert.messageText = "Connect GitHub"
        alert.informativeText = "Let’s bring your repositories, pull requests and activity into this profile. Paste a GitHub personal access token. We’ll keep it in macOS Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "GitHub personal access token"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Disconnect")
        alert.window.initialFirstResponder = field
        let choice = alert.runModal()
        guard choice != .alertSecondButtonReturn else { return }
        let token = field.stringValue; field.stringValue = ""
        Task {
            do {
                if choice == .alertThirdButtonReturn { try await GitHubWidgetStore.shared.disconnect(profile) }
                else { try await GitHubWidgetStore.shared.connect(token, profile: profile) }
                NotificationCenter.default.post(name: .webbyGitHubChanged, object: profile)
            } catch {
                let errorAlert = NSAlert(); errorAlert.messageText = "GitHub connection"
                errorAlert.informativeText = (error as? GitHubWidgetError)?.localizedDescription ?? "We couldn’t connect to GitHub. Let’s try again."
                errorAlert.runModal()
            }
        }
    }
}

@MainActor private final class GitHubRowButton: NSButton {
    let row: GitHubWidgetRow
    var open: ((URL) -> Void)?
    private var hover = false
    init(_ row: GitHubWidgetRow) {
        self.row = row; super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(pressed)
        toolTip = row.title+"\n"+row.detail; setAccessibilityLabel(row.title+", "+row.detail)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    @objc private func pressed() {
        guard let url = URL(string: row.url), url.scheme == "https", url.host == "github.com" else { return }
        Motion.springScale(layer, from: 0.98, to: 1); open?(url)
    }
    override func draw(_ dirtyRect: NSRect) {
        if hover || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.13 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let icon = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors:[.systemGreen]))
        let iconRect = NSRect(x: 9, y: (bounds.height-16)/2, width: 16, height: 16)
        NSColor.systemGreen.set(); icon?.draw(in: iconRect)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let roomy = bounds.height >= 43
        (row.title as NSString).draw(in: NSRect(x: 35, y: roomy ? bounds.height-23 : (bounds.height-17)/2, width: max(0,bounds.width-45), height: 18),
            withAttributes: [.font: WebbyTypography.font(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        if roomy {
            (row.detail as NSString).draw(in: NSRect(x: 35, y: 5, width: max(0,bounds.width-45), height: 15),
                withAttributes: [.font: WebbyTypography.font(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        }
    }
}

enum GitHubContributionLayout {
    static func cells(days: [GitHubContributionDay], size: NSSize) -> [(GitHubContributionDay, NSRect)] {
        guard !days.isEmpty, size.width >= 8, size.height >= 25 else { return [] }
        let weeks = max(1, min(53, Int((size.width+3)/9)))
        let first = max(0, days.count-1-max(0,days.last!.weekday)-(weeks-1)*7)
        let visible = Array(days.dropFirst(first))
        let columns = max(1, Int(ceil(Double(visible.count + (visible.first?.weekday ?? 0))/7)))
        let side = max(1,min(18, (size.width-CGFloat(columns-1)*3)/CGFloat(columns), (size.height-18)/7))
        let width = CGFloat(columns)*(side+3)-3
        let x = max(0,(size.width-width)/2), y = max(0,(size.height-(side+3)*7+3)/2)
        return visible.enumerated().map { index, day in
            let position = index+(visible.first?.weekday ?? 0)
            return (day, NSRect(x:x+CGFloat(position/7)*(side+3), y:y+CGFloat(day.weekday)*(side+3), width:side,height:side))
        }
    }
}
@MainActor private final class GitHubContributionGraph: NSView {
    var days: [GitHubContributionDay] = [] { didSet { needsDisplay = true; rebuildTooltips() } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsDisplay = true }
    private func rebuildTooltips() { toolTip = "Your GitHub contribution activity over the past year" }
    override func draw(_ dirtyRect: NSRect) {
        let peak = max(1,days.map(\.contributionCount).max() ?? 1)
        for (day, rect) in GitHubContributionLayout.cells(days: days, size: bounds.size) {
            let strength = day.contributionCount == 0 ? 0 : max(0.3, sqrt(Double(day.contributionCount)/Double(peak)))
            (strength == 0 ? NSColor.white.withAlphaComponent(0.075) : NSColor(calibratedRed:0.23,green:0.88,blue:0.58,alpha:strength)).setFill()
            NSBezierPath(roundedRect:rect,xRadius:min(3,rect.width/4),yRadius:min(3,rect.height/4)).fill()
        }
    }
}

@MainActor final class GitHubWidgetView: NSView {
    let kind: GitHubWidgetKind
    var openURL: ((URL) -> Void)?
    private var profile: UUID?
    private var snapshot: GitHubWidgetSnapshot?
    private var rows: [GitHubRowButton] = []
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var feedVisible = false
    private var refreshing = false
    private var connection = false
    private let heading = NSTextField(labelWithString: "")
    private let category = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let brand = NSButton(title: "", target: nil, action: nil)
    private let more = NSButton(title: "View all ↗", target: nil, action: nil)
    private let graph = GitHubContributionGraph()
    init(kind: GitHubWidgetKind) {
        self.kind = kind; super.init(frame: .zero); wantsLayer = true
        heading.stringValue = kind.title; heading.font = WebbyTypography.font(ofSize:13,weight:.semibold)
        category.image = NSImage(systemSymbolName:kind.symbol,accessibilityDescription:kind.title)
        category.contentTintColor = .systemGreen
        toolTip = kind.title
        heading.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize:34,weight:.medium)
        status.font = WebbyTypography.font(ofSize:10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        empty.font = WebbyTypography.font(ofSize:12); empty.textColor = .secondaryLabelColor
        brand.image = GitHubWidgetBrand.image; brand.imageScaling = .scaleProportionallyUpOrDown
        brand.isBordered = false; brand.target = self; brand.action = #selector(settings)
        brand.toolTip = "GitHub connection for this profile"; brand.setAccessibilityLabel("GitHub connection settings")
        more.isBordered = false; more.font = WebbyTypography.font(ofSize:11,weight:.medium); more.target = self; more.action = #selector(showAll)
        for view in [heading,category,count,status,empty,brand,more,graph] { addSubview(view) }
        NotificationCenter.default.addObserver(self, selector:#selector(connectionChanged(_:)), name:.webbyGitHubChanged, object:nil)
        NotificationCenter.default.addObserver(self, selector:#selector(wake), name:NSApplication.didBecomeActiveNotification, object:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate(); task?.cancel(); NotificationCenter.default.removeObserver(self) }
    func configure(profile:UUID) {
        guard self.profile != profile else { return }
        task?.cancel(); refreshing = false; self.profile = profile; snapshot = nil; connection = false
        render(nil); loadCache()
    }
    func setFeedVisible(_ visible:Bool) {
        guard feedVisible != visible else { return }
        feedVisible = visible
        if visible { refresh() }
        else { timer?.invalidate(); timer = nil }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { timer?.invalidate(); timer = nil } else { refresh() } }
    @objc private func wake() { refresh() }
    @objc private func connectionChanged(_ note:Notification) {
        guard note.object as? UUID == profile else { return }
        if note.userInfo?["recentOnly"] as? Bool == true && kind != .recent { return }
        task?.cancel(); refreshing = false; snapshot = nil; connection = false; render(nil); loadCache()
    }
    private func loadCache() {
        guard let profile else { return }
        task = Task { [weak self,kind] in
            let value = await GitHubWidgetStore.shared.cached(profile:profile,kind:kind)
            guard !Task.isCancelled,let view = self,view.profile == profile else { return }
            view.render(value)
            let connected = kind == .recent ? true : await GitHubWidgetStore.shared.connected(profile)
            guard !Task.isCancelled,let self,self.profile == profile else { return }
            self.connection = connected; self.render(value); self.task = nil; self.refresh()
        }
    }
    private var visible:Bool { feedVisible && window?.isVisible == true && !isHiddenOrHasHiddenAncestor && NSApp.isActive }
    private func refresh() {
        guard visible, !refreshing, task == nil, let profile else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in Task { @MainActor [weak self] in self?.refresh() } }
            timer?.tolerance = 30
        }
        guard connection || kind == .recent else { return }
        refreshing = true; status.stringValue = snapshot == nil ? "Loading…" : "Updating…"
        task = Task { [weak self,kind] in
            do {
                let value = try await GitHubWidgetStore.shared.refresh(profile:profile,kind:kind)
                guard !Task.isCancelled,let self,self.profile == profile else { return }
                self.render(value)
            } catch {
                guard !Task.isCancelled,let self,self.profile == profile else { return }
                self.status.stringValue = (error as? GitHubWidgetError)?.localizedDescription ?? "Offline · showing saved data"
                if self.snapshot == nil { self.empty.stringValue = self.status.stringValue; self.needsLayout = true }
            }
            self?.refreshing = false; self?.task = nil
        }
    }
    private func render(_ value:GitHubWidgetSnapshot?) {
        let changed = snapshot != value
        let rowsChanged = snapshot?.rows != value?.rows
        snapshot = value
        if changed { Motion.change(self,character:.widget) }
        if rowsChanged {
            rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
            for item in value?.rows ?? [] {
                let row = GitHubRowButton(item); row.open = { [weak self] url in self?.openURL?(url) }
                rows.append(row); addSubview(row)
            }
        }
        heading.stringValue = kind.title + (value.map { " · \($0.total)" } ?? "")
        count.stringValue = value.map { "\($0.total)" } ?? "—"
        graph.days = value?.days ?? []
        if let value {
            let date = RelativeDateTimeFormatter().localizedString(for:value.updated,relativeTo:Date())
            let qualifier = kind == .prs ? "Authored by you" : kind == .contributions ? "Past year" : kind == .repos || kind == .stars ? "Latest \(value.rows.count)" : ""
            status.stringValue = [qualifier,value.login.isEmpty ? "" : "@"+value.login,"Updated "+date].filter { !$0.isEmpty }.joined(separator:" · ")
            empty.stringValue = kind == .recent ? "Your next repository visit will appear here." : "All clear. Nothing here yet."
        } else {
            status.stringValue = connection ? "Ready to refresh" : kind == .recent ? "Saved on this Mac" : "Connect this profile"
            empty.stringValue = connection ? "We’re getting your GitHub ready." : kind == .recent ? "Visit a repository in Webby to keep it close." : "Let’s connect GitHub to bring your work here."
        }
        status.toolTip = status.stringValue
        more.title = connection ? "View all ↗" : "Connect GitHub"; needsLayout = true
    }
    @objc private func settings() { if let profile { GitHubWidgetConnection.present(profile:profile) } }
    @objc private func showAll() {
        guard connection || kind == .recent else { settings(); return }
        if kind == .recent {
            let menu = NSMenu(title:"Recently Visited Repositories")
            for row in snapshot?.rows ?? [] {
                let item = menu.addItem(withTitle:row.title,action:#selector(openRecent(_:)),keyEquivalent:"")
                item.target = self; item.representedObject = row.url
                item.image = NSImage(systemSymbolName:"book.closed",accessibilityDescription:nil)
            }
            if menu.items.isEmpty { let item = menu.addItem(withTitle:"No recent repositories yet",action:nil,keyEquivalent:""); item.isEnabled = false }
            menu.popUp(positioning:nil,at:NSPoint(x:more.frame.minX,y:more.frame.minY),in:self)
            return
        }
        openURL?(kind.destination(login:snapshot?.login ?? ""))
    }
    @objc private func openRecent(_ item:NSMenuItem) {
        guard let text = item.representedObject as? String,let url = URL(string:text),url.scheme == "https",url.host == "github.com" else { return }
        openURL?(url)
    }
    func containsControl(_ point:NSPoint) -> Bool {
        ([brand,more]+rows).contains { !$0.isHidden && $0.frame.contains(point) }
    }
    override func layout() {
        super.layout(); let w = bounds.width,h = bounds.height
        let tiny = w < 150 || h < 100, strip = h < 145
        category.isHidden = tiny && h < 70 && w < 150
        category.frame = NSRect(x:1,y:max(0,h-24),width:18,height:18)
        brand.frame = NSRect(x:max(0,w-26),y:max(0,h-26),width:22,height:22)
        heading.isHidden = tiny && w < 150; heading.frame = NSRect(x:27,y:h-24,width:max(0,w-63),height:20)
        count.isHidden = !tiny && kind != .contributions
        let tinySize = max(10,min(h < 70 ? 18 : 32,h*0.4,w/max(1,CGFloat(count.stringValue.count))*1.5))
        count.font = .monospacedDigitSystemFont(ofSize:tiny ? tinySize : 28,weight:.medium)
        count.frame = tiny ? NSRect(x:0,y:h < 70 ? 0 : max(0,(h-68)/2),width:w,height:h < 70 ? 22 : 40)
            : NSRect(x:0,y:h-64,width:max(0,w-26),height:40)
        status.isHidden = tiny || strip; status.frame = NSRect(x:0,y:0,width:max(0,w-90),height:16)
        more.isHidden = tiny; more.frame = NSRect(x:max(0,w-96),y:0,width:min(96,w),height:20)
        graph.isHidden = kind != .contributions || tiny || h < 150 || snapshot?.days.isEmpty != false
        graph.frame = NSRect(x:0,y:24,width:max(0,w),height:max(0,h-94))
        let top = h-34, bottom:CGFloat = strip ? 22 : 25
        let rowHeight:CGFloat = strip ? 31 : 49
        let perColumn = max(0,Int((top-bottom)/rowHeight))
        let columns = w >= 580 ? 2 : 1
        let capacity = perColumn * columns
        let columnWidth = (w-CGFloat(columns-1)*12)/CGFloat(columns)
        for (index,row) in rows.enumerated() {
            row.isHidden = tiny || kind == .contributions || index >= capacity
            let column = perColumn > 0 ? index/perColumn : 0
            let position = perColumn > 0 ? index%perColumn : 0
            row.frame = NSRect(x:CGFloat(column)*(columnWidth+12),y:top-CGFloat(position+1)*rowHeight,width:max(0,columnWidth),height:rowHeight-2)
        }
        empty.isHidden = tiny || !(snapshot?.rows.isEmpty ?? true) || (kind == .contributions && snapshot?.days.isEmpty == false)
        empty.frame = NSRect(x:4,y:28,width:max(0,w-8),height:max(0,h-(kind == .contributions ? 100 : 68)))
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        // Quiet, static skeletons; never replace cached rows or run shimmer timers.
        guard snapshot == nil, connection, bounds.width >= 150, bounds.height >= 160 else { return }
        NSColor.white.withAlphaComponent(0.055).setFill()
        for index in 0..<min(3,max(0,Int((bounds.height-85)/49))) {
            NSBezierPath(roundedRect:NSRect(x:5,y:bounds.height-59-CGFloat(index)*49,width:max(0,bounds.width-18-CGFloat(index)*17),height:9),xRadius:4,yRadius:4).fill()
        }
    }
}

@MainActor private enum GitHubWidgetBrand {
    // GitHub's Octicon mark, bundled as vector geometry: no remote logo request.
    static let image: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill="#e7ecef" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.65 7.65 0 0 1 8 3.86c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
        """
        return NSImage(data:Data(svg.utf8))
    }()
}
