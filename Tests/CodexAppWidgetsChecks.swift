import AppKit
import SQLite3

@MainActor enum Motion {
    enum Character { case widget }
    static func change(_ view:NSView?,character:Character) {}
    static func springScale(_ layer:CALayer?,from:CGFloat,to:CGFloat) {}
}
@main struct CodexAppWidgetChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3,CommandLine.arguments[1] == "--socket-fixture" {
            let socket = URL(fileURLWithPath:CommandLine.arguments[2])
            let config = CodexAppConfiguration(cli:URL(fileURLWithPath:"/usr/bin/false"),socket:socket,home:socket.deletingLastPathComponent())
            let connection = try CodexAppTransport.attach(config)
            let account = try connection.call("account/read")
            precondition(CodexAppData.identity(account) != nil)
            let chats = CodexAppData.chats(try connection.call("thread/list"))
            precondition(chats.count == 1 && chats[0].title == "Socket fixture")
            let usage = CodexAppData.usage(try connection.call("account/rateLimits/read"))
            precondition(usage.first?.remaining == 75)
            let queued = try connection.call("thread/queue/add",params:["threadId":chats[0].id,"clientUserMessageId":UUID().uuidString,"input":[["type":"text","text":"fixture only"]]])
            precondition((queued["queuedSubmission"] as? [String:Any])?["id"] as? String == "fixture-queue")
            print("PASS: native Unix WebSocket attach, handshake, masked requests, fragmented responses, ping/pong, reads and fixture queue; no CLI/server startup")
            return
        }
        func json(_ value:String)->[String:Any] { try! JSONSerialization.jsonObject(with:Data(value.utf8)) as! [String:Any] }
        let id = UUID().uuidString
        let chats = CodexAppData.chats(json("""
        {"data":[{"id":"\(id)","name":"Fix café\nnow","cwd":"/fixture","updatedAt":1780000000},{"id":"\(id)","title":"duplicate"},{"id":"not-a-chat","title":"bad"}]}
        """.replacingOccurrences(of:"café\nnow",with:"café\\nnow")))
        precondition(chats.count == 1 && chats[0].title == "Fix café now")
        precondition(chats[0].updated.timeIntervalSince1970 == 1780000000)
        let windows = CodexAppData.usage(json("""
        {"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":99,"windowDurationMins":30}},"codex":{"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1780000300},"secondary":{"usedPercent":120,"windowDurationMins":10080}}}}
        """))
        precondition(windows.count == 2 && windows[0].remaining == 77 && windows[1].remaining == 0)
        precondition(windows[0].title == "5-hour window" && windows[1].title == "Weekly")
        precondition(CodexAppData.usage([:]).isEmpty,"Missing usage must never become a fake 100% allowance")
        precondition(CodexAppData.identity(["account":NSNull()]) == nil)
        let a = json("{\"account\":{\"type\":\"chatgpt\",\"email\":\"fixture@example.test\"}}")
        let b = json("{\"account\":{\"type\":\"chatgpt\",\"email\":\"other@example.test\"}}")
        precondition(CodexAppData.identity(a) != CodexAppData.identity(b))
        precondition(CodexAppData.link(id)?.absoluteString == "codex://threads/"+id)
        precondition(CodexAppData.link(id,wake:true)?.absoluteString == "codex://threads/wake/"+id)
        precondition(CodexAppData.link("../settings?prompt=oops") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webby-codex-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        precondition(CodexAppData.localChats(home:root).isEmpty)
        precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("state_5.sqlite").path),"Read-only fallback must not create a database")
        var db:OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE threads(id TEXT,name TEXT,title TEXT,cwd TEXT,updated_at INTEGER,archived INTEGER,source TEXT); CREATE INDEX idx_threads_updated_at ON threads(updated_at DESC);"
        precondition(sqlite3_exec(db,schema,nil,nil,nil) == SQLITE_OK)
        for index in 0..<40 {
            let sql = "INSERT INTO threads VALUES('\(UUID().uuidString)',NULL,'Fixture \(index)','/fixture',\(index),\(index == 39 ? 1 : 0),'cli')"
            precondition(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK)
        }
        let before = try Data(contentsOf:root.appendingPathComponent("state_5.sqlite"))
        let local = CodexAppData.localChats(home:root)
        precondition(local.count == 32 && local[0].title == "Fixture 38")
        let after = try Data(contentsOf:root.appendingPathComponent("state_5.sqlite"))
        precondition(before == after,"Reading metadata must not change the database")
        let config = CodexAppConfiguration(cli:URL(fileURLWithPath:"/usr/bin/false"),socket:root.appendingPathComponent("absent.sock"),home:root)
        precondition(CodexAppTransport.startArguments() == ["app-server","daemon","start"],"Fallback must use the shared daemon's idempotent start, never a private server")
        precondition(CodexAppTransport.mayStartShared(after:CodexAppWidgetError.noServer))
        for error in [CodexAppWidgetError.timeout,.socketAccess,.unsafeSocket,.protocolError,.rpc("initialize",-32600)] {
            precondition(!CodexAppTransport.mayStartShared(after:error),"A present but incompatible/blocked server must never start a duplicate")
        }
        precondition(CodexWebSocketWire.accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=","WebSocket upgrade must match RFC 6455")
        let hello = Data("Hello".utf8)
        precondition(CodexWebSocketWire.frame(hello,mask:[0x37,0xfa,0x21,0x3d]) == Data([0x81,0x85,0x37,0xfa,0x21,0x3d,0x7f,0x9f,0x4d,0x51,0x58]))
        var wire = CodexWebSocketWire()
        try wire.append(Data([0x81]));let partial = try wire.next()
        if case .some = partial { preconditionFailure("A partial frame must wait for more bytes") }
        try wire.append(Data([5])+hello)
        if case .message(let text)? = try wire.next() { precondition(text == hello) } else { preconditionFailure("Split frame was lost") }
        try wire.append(Data([0x01,2])+Data("He".utf8)+Data([0x89,1,120,0x80,3])+Data("llo".utf8))
        if case .ping(let value)? = try wire.next() { precondition(value == Data([120])) } else { preconditionFailure("Ping was lost between fragments") }
        if case .message(let text)? = try wire.next() { precondition(text == hello) } else { preconditionFailure("Fragmented JSON was lost") }
        for size in [126,65535,65536] {
            let payload = Data(repeating:65,count:size)
            let header:Data = size <= 65535 ? Data([0x81,126,UInt8((size>>8)&255),UInt8(size&255)])
                : Data([0x81,127]+(0..<8).reversed().map { UInt8((UInt64(size)>>($0*8))&255) })
            var decoder = CodexWebSocketWire();try decoder.append(header+payload)
            if case .message(let text)? = try decoder.next() { precondition(text == payload) } else { preconditionFailure("Extended response frame was lost") }
            let client = CodexWebSocketWire.frame(payload,mask:[1,2,3,4])
            precondition(client[1] == (size <= 65535 ? 0xFE : 0xFF))
        }
        var invalid = CodexWebSocketWire();try invalid.append(Data([0x81,127])+Data(repeating:255,count:8))
        do { _ = try invalid.next(); preconditionFailure("Oversized WebSocket frame accepted") } catch CodexAppWidgetError.protocolError {}
        let socketMode = mode_t(S_IFSOCK),directoryMode = mode_t(S_IFDIR)
        let uid:uid_t = 502
        precondition(CodexAppTransport.protectedSocket(owner:uid,mode:socketMode|0o755,parentOwner:uid,parentMode:directoryMode|0o700,user:uid),"A normal socket inside its private daemon directory must be accepted")
        precondition(!CodexAppTransport.protectedSocket(owner:uid,mode:socketMode|0o777,parentOwner:uid,parentMode:directoryMode|0o755,user:uid),"A public writable socket in a public directory must be rejected")
        precondition(!CodexAppTransport.protectedSocket(owner:501,mode:socketMode|0o600,parentOwner:uid,parentMode:directoryMode|0o700,user:uid),"Another user's socket must be rejected")
        precondition(!CodexAppTransport.protectedSocket(owner:uid,mode:mode_t(S_IFREG)|0o600,parentOwner:uid,parentMode:directoryMode|0o700,user:uid),"A regular file is never a daemon socket")
        do { _ = try CodexAppTransport(config); preconditionFailure("No daemon must fail closed") }
        catch CodexAppWidgetError.noServer {}
        let cacheFile = root.appendingPathComponent("snapshot.json")
        let cached = CodexAppSnapshot(chats:chats,windows:windows,updated:Date(),usageUpdated:Date(),account:"fixture-hash",live:true,status:"Connected")
        try JSONEncoder().encode(cached).write(to:cacheFile)
        let store = CodexAppWidgetStore(file:cacheFile)
        let loaded = await store.cached()
        precondition(!loaded.live && loaded.windows == windows && loaded.chats == chats)
        let offline = await store.refresh(nil)
        precondition(offline.windows == windows && !offline.live)
        print("PASS: RFC 6455 wire framing, fallback policy, recent chats, usage/null handling, account isolation, safe links, bounded metadata, absent daemon and offline snapshots")
    }
}
