// Compile with GitHubWidgets.swift and a test-only Motion stub. No credentials,
// personal profile files, network requests or NSApplication initialization.
import AppKit

@MainActor enum Motion {
    enum Character { case widget }
    static func change(_ view: NSView?, character: Character) {}
    static func springScale(_ layer: CALayer?, from: CGFloat, to: CGFloat) {}
}

@main struct GitHubWidgetChecks {
    @MainActor static func main() async throws {
        func json(_ text: String) -> Data { Data(text.utf8) }
        let prs = try GitHubWidgetStore.decode(.prs, data: json("""
        {"total_count":82,"items":[{"title":"Fix café ☕","html_url":"https://github.com/a/b/pull/7","number":7,"repository_url":"https://api.github.com/repos/a/b","draft":true}]}
        """), login: "fixture")
        precondition(prs.total == 82 && prs.rows.count == 1)
        precondition(prs.rows[0].detail == "a/b · #7 · Draft")
        let repos = json("""
        [{"full_name":"a/secret","description":null,"html_url":"https://github.com/a/secret","stargazers_count":2,"language":null,"private":true}]
        """)
        for kind in [GitHubWidgetKind.repos, .stars] {
            let value = try GitHubWidgetStore.decode(kind, data: repos, login: "fixture")
            precondition(value.rows[0].detail == "Private · ★ 2")
        }
        let issues = try GitHubWidgetStore.decode(.issues, data: json("{\"total_count\":0,\"items\":[]}"), login: "fixture")
        precondition(issues.total == 0 && issues.rows.isEmpty)
        let news = try GitHubWidgetStore.decode(.news, data: json("""
        [{"type":"FutureUnknownEvent","actor":{"login":"friend"},"repo":{"name":"a/b"}}]
        """), login: "fixture")
        precondition(news.rows[0].title == "friend was active in")
        let graph = try GitHubWidgetStore.decode(.contributions, data: json("""
        {"data":{"viewer":{"contributionsCollection":{"contributionCalendar":{"totalContributions":9,"weeks":[{"contributionDays":[{"date":"2026-10-25","contributionCount":9,"weekday":0}]}]}}}}}
        """), login: "fixture")
        precondition(graph.total == 9 && graph.days.count == 1)
        let year = (0..<366).map { GitHubContributionDay(date:"day\($0)",contributionCount:$0 % 20,weekday:$0 % 7) }
        for size in [NSSize(width:0,height:0), NSSize(width:8,height:25), NSSize(width:80,height:60), NSSize(width:340,height:100), NSSize(width:800,height:360)] {
            let cells = GitHubContributionLayout.cells(days:year,size:size)
            for (_,rect) in cells {
                precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= size.width+0.01 && rect.maxY <= size.height+0.01)
            }
            if size.width >= 80 { precondition(cells.last?.0.date == "day365") }
        }
        do {
            _ = try GitHubWidgetStore.decode(.contributions, data: json("{\"data\":null,\"errors\":[{\"message\":\"denied\"}]}"), login: "fixture")
            preconditionFailure("A GraphQL failure must not become an empty successful snapshot")
        } catch GitHubWidgetError.graphql {}

        for link in ["https://github.com/settings/tokens", "https://github.com/orgs/a", "https://github.com/a", "http://github.com/a/b", "https://github.com.evil.test/a/b", "https://user:pass@github.com/a/b"] {
            precondition(GitHubWidgetStore.repositoryURL(URL(string:link)!) == nil)
        }
        precondition(GitHubWidgetStore.repositoryURL(URL(string:"https://github.com/owner/repo/pull/8?secret=x#hash")!)?.absoluteString == "https://github.com/owner/repo")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("webby-github-check-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GitHubWidgetStore(directory: directory), a = UUID(), b = UUID()
        for index in 0..<34 { await store.recordVisit(URL(string:"https://github.com/owner/repo\(index)/issues/1")!, profile:a) }
        await store.recordVisit(URL(string:"https://github.com/owner/repo4/tree/main")!, profile:a)
        let recent = await store.cached(profile:a,kind:.recent)
        precondition(recent?.rows.count == 30 && recent?.rows.first?.title == "owner/repo4")
        precondition(recent?.rows.filter { $0.title == "owner/repo4" }.count == 1)
        let other = await store.cached(profile:b,kind:.recent)
        precondition(other == nil, "Profile caches must remain separate")
        let restarted = GitHubWidgetStore(directory:directory)
        let persisted = await restarted.cached(profile:a,kind:.recent)
        precondition(persisted == recent, "Cached visits must survive a restart")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys:nil)
        precondition(files.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath:files[0].path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let seeded = await store.seedRecent(["https://github.com/settings/tokens","https://github.com/a/first/issues/1","https://github.com/a/first","https://github.com/a/older"],profile:b)
        precondition(seeded)
        let seededValue = await store.cached(profile:b,kind:.recent)
        precondition(seededValue?.rows.map(\.title) == ["a/first","a/older"])
        let reseeded = await store.seedRecent(["https://github.com/a/overwrite"],profile:b)
        precondition(!reseeded,"Importing history must never overwrite live visits")
        print("PASS: API fixtures, GraphQL errors, responsive graph geometry, URL sanitization, bounded recents, deduplication, disk persistence and profile isolation")
    }
}
