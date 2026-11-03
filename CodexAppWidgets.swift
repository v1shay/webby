import AppKit
import SQLite3
import CryptoKit
import Darwin

struct CodexRecentChat: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let directory: String
    let updated: Date
}
struct CodexUsageWindow: Codable, Equatable, Sendable {
    let used: Double
    let minutes: Int
    let resets: Date?
    var remaining: Int { max(0,min(100,Int((100-used).rounded()))) }
    var title: String {
        if minutes >= 10080 { return "Weekly" }
        if minutes >= 1440 { return "\(minutes/1440)-day window" }
        if minutes >= 60 { return "\(minutes/60)-hour window" }
        return "\(minutes)-minute window"
    }
}
struct CodexAppSnapshot: Codable, Equatable, Sendable {
    var chats: [CodexRecentChat] = []
    var windows: [CodexUsageWindow] = []
    var updated = Date.distantPast
    var usageUpdated: Date?
    var account: String?
    var live = false
    var status = "Open Codex to refresh"
}
struct CodexAppConfiguration: Sendable {
    let cli: URL
    let socket: URL
    let home: URL
    @MainActor static func current() -> Self? {
        let workspace = NSWorkspace.shared
        let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" })?.bundleURL
            ?? workspace.urlForApplication(withBundleIdentifier:"com.openai.codex")
        guard let app else { return nil }
        let cli = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        guard FileManager.default.isExecutableFile(atPath:cli.path) else { return nil }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath:$0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return .init(cli:cli,socket:home.appendingPathComponent("app-server-control/app-server-control.sock"),home:home)
    }
}
enum CodexAppWidgetError: LocalizedError {
    case unavailable, timeout, protocolError, rejected, uncertain
    case socketAccess, unsafeSocket, noServer, rpc(String,Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "We couldn’t connect to Codex’s shared app server."
        case .timeout: "Codex took too long to reply. We’ll keep the saved view."
        case .protocolError: "This Codex version couldn’t read the requested data."
        case .rejected: "Codex couldn’t queue this prompt. Your draft is still here."
        case .uncertain: "We couldn’t confirm delivery. Check the chat in Codex before retrying."
        case .socketAccess: "macOS blocked access to Codex’s local socket."
        case .noServer: "No shared Codex app server is running."
        case .unsafeSocket: "Codex’s socket isn’t owned by this account or protected by its directory."
        case .rpc(let method,let code): "Codex rejected \(method) (RPC \(code))."
        }
    }
}

// The daemon's Unix socket carries RFC 6455 WebSockets, not JSONL. Native I/O
// avoids spawning a proxy process and never opens a separate model connection.
struct CodexWebSocketWire {
    enum Event { case message(Data), ping(Data), pong, closed }
    private var buffer = Data(), fragment = Data()
    private var fragmented = false
    static let maximum = 2_000_000
    static func accept(_ key:String) -> String {
        Data(Insecure.SHA1.hash(data:Data((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
    static func frame(_ payload:Data,opcode:UInt8 = 1,mask:[UInt8]? = nil) -> Data {
        let mask = mask ?? (0..<4).map { _ in UInt8.random(in:0...255) }
        precondition(mask.count == 4)
        var bytes:[UInt8] = [0x80|opcode]
        let count = payload.count
        if count < 126 { bytes.append(0x80|UInt8(count)) }
        else if count <= 65535 { bytes += [0xFE,UInt8((count>>8)&255),UInt8(count&255)] }
        else { bytes.append(0xFF); bytes += (0..<8).reversed().map { UInt8((UInt64(count)>>($0*8))&255) } }
        bytes += mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset%4] }
        return Data(bytes)
    }
    mutating func append(_ data:Data) throws {
        guard buffer.count+data.count <= Self.maximum+16 else { throw CodexAppWidgetError.protocolError }
        buffer.append(data)
    }
    mutating func next() throws -> Event? {
        while buffer.count >= 2 {
            let first = buffer[0], second = buffer[1], opcode = first & 15
            guard first & 0x70 == 0,second & 0x80 == 0 else { throw CodexAppWidgetError.protocolError }
            let final = first & 0x80 != 0
            var count = UInt64(second & 127), offset = 2
            if count == 126 {
                guard buffer.count >= 4 else { return nil }
                count = UInt64(buffer[2])*256+UInt64(buffer[3]); offset = 4
            } else if count == 127 {
                guard buffer.count >= 10 else { return nil }
                count = buffer[2..<10].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }; offset = 10
            }
            guard count <= UInt64(Self.maximum),opcode < 8 || (final && count <= 125) else { throw CodexAppWidgetError.protocolError }
            guard buffer.count >= offset+Int(count) else { return nil }
            let payload = Data(buffer[offset..<offset+Int(count)])
            buffer = Data(buffer.dropFirst(offset+Int(count)))
            switch opcode {
            case 8: return .closed
            case 9: return .ping(payload)
            case 10: return .pong
            case 1,2:
                guard !fragmented else { throw CodexAppWidgetError.protocolError }
                if final { return .message(payload) }
                fragment = payload; fragmented = true
            case 0:
                guard fragmented,fragment.count+payload.count <= Self.maximum else { throw CodexAppWidgetError.protocolError }
                fragment.append(payload)
                if final { let result = fragment; fragment = Data(); fragmented = false; return .message(result) }
            default: throw CodexAppWidgetError.protocolError
            }
        }
        return nil
    }
}

final class CodexAppTransport {
    private var socketFD:Int32 = -1
    private var wire = CodexWebSocketWire()
    private var nextID = 0, bytesRead = 0
    static func startArguments() -> [String] { ["app-server","daemon","start"] }
    static func mayStartShared(after error:Error) -> Bool {
        if case CodexAppWidgetError.noServer = error { return true }
        return false
    }
    static func protectedSocket(owner:uid_t,mode:mode_t,parentOwner:uid_t,parentMode:mode_t,user:uid_t) -> Bool {
        owner == user && (mode & S_IFMT) == S_IFSOCK &&
            ((mode & 0o077) == 0 || (parentOwner == user && (parentMode & S_IFMT) == S_IFDIR && (parentMode & 0o077) == 0))
    }
    static func attach(_ configuration:CodexAppConfiguration) throws -> CodexAppTransport {
        do { return try CodexAppTransport(configuration) }
        catch {
            guard mayStartShared(after:error) else { throw error }
            // CLI startup has the shared daemon's own lock and is idempotent:
            // another app winning the race is reused, never stopped/restarted.
            try startShared(configuration)
            return try CodexAppTransport(configuration)
        }
    }
    private static func startShared(_ configuration:CodexAppConfiguration) throws {
        let process = Process(); process.executableURL = configuration.cli
        process.arguments = startArguments(); process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = configuration.home.path; process.environment = environment
        do { try process.run() } catch { throw CodexAppWidgetError.unavailable }
        let until = ProcessInfo.processInfo.systemUptime+12
        while process.isRunning,ProcessInfo.processInfo.systemUptime < until { usleep(50_000) }
        if process.isRunning {
            process.terminate(); usleep(100_000)
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            process.waitUntilExit(); throw CodexAppWidgetError.timeout
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CodexAppWidgetError.unavailable }
    }
    init(_ configuration:CodexAppConfiguration) throws {
        var info = stat()
        let resolved = configuration.socket.resolvingSymlinksInPath().path
        guard stat(resolved,&info) == 0 else {
            if errno == EACCES || errno == EPERM { throw CodexAppWidgetError.socketAccess }
            if errno == ENOENT { throw CodexAppWidgetError.noServer }
            throw CodexAppWidgetError.unavailable
        }
        var parent = stat()
        guard stat(URL(fileURLWithPath:resolved).deletingLastPathComponent().path,&parent) == 0,
              Self.protectedSocket(owner:info.st_uid,mode:info.st_mode,parentOwner:parent.st_uid,parentMode:parent.st_mode,user:getuid()) else { throw CodexAppWidgetError.unsafeSocket }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(resolved.utf8)+[0]
        guard path.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw CodexAppWidgetError.protocolError }
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:path) }
        socketFD = Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard socketFD >= 0 else { throw CodexAppWidgetError.unavailable }
        do {
            _ = fcntl(socketFD,F_SETFL,fcntl(socketFD,F_GETFL)|O_NONBLOCK)
            var one:Int32 = 1
            _ = setsockopt(socketFD,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(socketFD,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result < 0 {
                let code = errno
                if code == ENOENT || code == ECONNREFUSED { throw CodexAppWidgetError.noServer }
                if code == EACCES || code == EPERM { throw CodexAppWidgetError.socketAccess }
                guard code == EINPROGRESS || code == EAGAIN else { throw CodexAppWidgetError.unavailable }
                try wait(POLLOUT,until:ProcessInfo.processInfo.systemUptime+8)
                var error:Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(socketFD,SOL_SOCKET,SO_ERROR,&error,&size) == 0 else { throw CodexAppWidgetError.unavailable }
                if error == ECONNREFUSED || error == ENOENT { throw CodexAppWidgetError.noServer }
                guard error == 0 else { throw CodexAppWidgetError.unavailable }
            }
            try upgrade()
            _ = try call("initialize",params:["clientInfo":["name":"webby_widgets","title":"Webby Widgets","version":"2"],"capabilities":["experimentalApi":true]])
            try send(["method":"initialized"])
        } catch { close(); throw error }
    }
    deinit { close() }
    private func close() { if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 } }
    private func wait(_ events:Int32,until:Double) throws {
        while ProcessInfo.processInfo.systemUptime < until {
            var fd = pollfd(fd:socketFD,events:Int16(events),revents:0)
            let result = poll(&fd,1,150)
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw CodexAppWidgetError.unavailable }
        }
        throw CodexAppWidgetError.timeout
    }
    private func write(_ data:Data) throws {
        let until = ProcessInfo.processInfo.systemUptime+8
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(socketFD,bytes.baseAddress!.advanced(by:offset),data.count-offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try wait(POLLOUT,until:until); continue }
                throw CodexAppWidgetError.unavailable
            }
        }
    }
    private func read(until:Double) throws -> Data {
        while true {
            try wait(POLLIN,until:until)
            var bytes = [UInt8](repeating:0,count:16384)
            let count = Darwin.read(socketFD,&bytes,bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { throw CodexAppWidgetError.unavailable }
            bytesRead += count
            guard bytesRead <= 8_000_000 else { throw CodexAppWidgetError.protocolError }
            return Data(bytes.prefix(count))
        }
    }
    private func upgrade() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in:0...255) }).base64EncodedString()
        let headers = "GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(headers.utf8))
        var data = Data(); let until = ProcessInfo.processInfo.systemUptime+8
        while data.range(of:Data("\r\n\r\n".utf8)) == nil {
            guard data.count < 16384 else { throw CodexAppWidgetError.protocolError }
            data.append(try read(until:until))
        }
        let range = data.range(of:Data("\r\n\r\n".utf8))!
        let lines = String(decoding:data[..<range.lowerBound],as:UTF8.self).components(separatedBy:"\r\n")
        guard lines.first?.split(separator:" ").dropFirst().first == "101" else { throw CodexAppWidgetError.protocolError }
        var fields:[String:String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator:":",maxSplits:1)
            if pair.count == 2 { fields[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in:.whitespaces) }
        }
        guard fields["sec-websocket-accept"] == CodexWebSocketWire.accept(key),fields["upgrade"]?.lowercased() == "websocket" else { throw CodexAppWidgetError.protocolError }
        try wire.append(Data(data[range.upperBound...]))
    }
    private func send(_ packet:[String:Any]) throws { try write(CodexWebSocketWire.frame(JSONSerialization.data(withJSONObject:packet))) }
    func call(_ method:String,params:[String:Any]? = nil) throws -> [String:Any] {
        nextID += 1; let id = nextID
        var packet:[String:Any] = ["id":id,"method":method]
        if let params { packet["params"] = params }
        try send(packet); let until = ProcessInfo.processInfo.systemUptime+8
        while ProcessInfo.processInfo.systemUptime < until {
            if let event = try wire.next() {
                switch event {
                case .message(let data):
                    guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CodexAppWidgetError.protocolError }
                    if json["id"] as? Int == id {
                        if let error = json["error"] as? [String:Any] { throw CodexAppWidgetError.rpc(method,error["code"] as? Int ?? -1) }
                        guard let result = json["result"] as? [String:Any] else { throw CodexAppWidgetError.protocolError }
                        return result
                    }
                case .ping(let data): try write(CodexWebSocketWire.frame(data,opcode:10))
                case .pong: break
                case .closed: throw CodexAppWidgetError.unavailable
                }
            } else { try wire.append(read(until:until)) }
        }
        throw CodexAppWidgetError.timeout
    }
}

enum CodexAppData {
    static func chats(_ result:[String:Any]) -> [CodexRecentChat] {
        var seen = Set<String>()
        return (result["data"] as? [[String:Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String,UUID(uuidString:id) != nil,seen.insert(id).inserted else { return nil }
            let name = [row["name"],row["title"],row["preview"]].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? "Untitled chat"
            return .init(id:id,title:String(name.replacingOccurrences(of:"\n",with:" ").prefix(180)),directory:row["cwd"] as? String ?? "",updated:Date(timeIntervalSince1970:row["updatedAt"] as? Double ?? 0))
        }.prefix(32).map { $0 }
    }
    static func usage(_ result:[String:Any]) -> [CodexUsageWindow] {
        let buckets = result["rateLimitsByLimitId"] as? [String:[String:Any]]
        let bucket = buckets?["codex"] ?? result["rateLimits"] as? [String:Any] ?? [:]
        return ["primary","secondary"].compactMap { name in
            guard let window = bucket[name] as? [String:Any],let used = window["usedPercent"] as? Double,
                  used.isFinite,let minutes = window["windowDurationMins"] as? Int,minutes > 0 else { return nil }
            return .init(used:max(0,min(100,used)),minutes:minutes,resets:(window["resetsAt"] as? Double).map { Date(timeIntervalSince1970:$0) })
        }
    }
    static func identity(_ account:[String:Any]) -> String? {
        guard account["account"] is [String:Any],let data = try? JSONSerialization.data(withJSONObject:account,options:[.sortedKeys]) else { return nil }
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func link(_ thread:String?,wake:Bool = false) -> URL? {
        guard let thread else { return URL(string:"codex://") }
        guard UUID(uuidString:thread) != nil else { return nil }
        return URL(string:"codex://threads/"+(wake ? "wake/" : "")+thread)
    }
    // Read metadata only, with SQLite's read-only mode and a short lock timeout.
    // No transcript scans, auth reads, migrations, writes or database checkpoints.
    static func localChats(home:URL) -> [CodexRecentChat] {
        var db:OpaquePointer?
        let file = home.appendingPathComponent("state_5.sqlite")
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return [] }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db,50)
        var query:OpaquePointer?
        // Force the existing recency index, then filter only 256 candidates. A
        // missing index/schema disables this fallback instead of scanning/sorting
        // a potentially huge live Codex database or modifying its indexes.
        let sql = "SELECT id,COALESCE(NULLIF(name,''),NULLIF(title,''),'Untitled chat'),cwd,updated_at FROM (SELECT id,name,title,cwd,updated_at,archived,source FROM threads INDEXED BY idx_threads_updated_at ORDER BY updated_at DESC LIMIT 256) WHERE archived=0 AND source NOT LIKE '%subAgent%' ORDER BY updated_at DESC LIMIT 32"
        guard sqlite3_prepare_v2(db,sql,-1,&query,nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(query) }
        var rows:[[String:Any]] = []
        while sqlite3_step(query) == SQLITE_ROW {
            func text(_ index:Int32) -> String { sqlite3_column_text(query,index).map { String(cString:$0) } ?? "" }
            rows.append(["id":text(0),"title":text(1),"cwd":text(2),"updatedAt":Double(sqlite3_column_int64(query,3))])
        }
        return chats(["data":rows])
    }
}

actor CodexAppWidgetStore {
    static let shared = CodexAppWidgetStore()
    private var value:CodexAppSnapshot?
    private var pending:Task<CodexAppSnapshot,Never>?
    private var attempted = Date.distantPast
    private let file:URL
    init(file:URL? = nil) {
        self.file = file ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Webby/Codex App/widgets.json")
    }
    func cached() -> CodexAppSnapshot {
        if let value { return value }
        if let data = try? Data(contentsOf:file),data.count < 200_000,let saved = try? JSONDecoder().decode(CodexAppSnapshot.self,from:data) {
            var saved = saved; saved.live = false; saved.status = "Saved · open Codex to refresh"; value = saved
        } else { value = CodexAppSnapshot() }
        return value!
    }
    func refresh(_ configuration:CodexAppConfiguration?) async -> CodexAppSnapshot {
        if let pending { return await pending.value }
        let old = cached()
        guard Date().timeIntervalSince(attempted) >= 60 else { return old }
        attempted = Date()
        let task = Task.detached(priority:.utility) { () -> CodexAppSnapshot in
            var next = old; next.live = false
            guard let configuration else { next.status = "Install or open the Codex app"; return next }
            let local = CodexAppData.localChats(home:configuration.home)
            if !local.isEmpty { next.chats = local }
            do {
                let proxy = try CodexAppTransport.attach(configuration)
                let account = try proxy.call("account/read",params:["refreshToken":false])
                let identity = CodexAppData.identity(account)
                if identity != next.account { next.windows = []; next.usageUpdated = nil }
                next.account = identity
                if let result = try? proxy.call("thread/list",params:["limit":32,"sortKey":"updated_at","sortDirection":"desc","archived":false,"sourceKinds":["cli","vscode","exec","appServer"],"useStateDbOnly":true]) {
                    next.chats = CodexAppData.chats(result)
                }
                var usageFailure:String?
                if identity != nil {
                    do {
                        let result = try proxy.call("account/rateLimits/read")
                        next.windows = CodexAppData.usage(result); next.usageUpdated = Date()
                    } catch { usageFailure = (error as? CodexAppWidgetError)?.localizedDescription ?? "Codex couldn’t return usage limits." }
                }
                next.live = true; next.updated = Date(); next.status = usageFailure ?? (identity == nil ? "Sign in through Codex" : "Connected to Codex")
            } catch {
                next.status = (error as? CodexAppWidgetError)?.localizedDescription ?? "Codex connection failed. Your saved chats are still here."
            }
            return next
        }
        pending = task; let next = await task.value; pending = nil; value = next
        if let data = try? JSONEncoder().encode(next),data.count < 200_000 {
            try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try? data.write(to:file,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        return next
    }
    func queue(_ text:String,thread:String,configuration:CodexAppConfiguration?) async throws {
        guard let configuration,UUID(uuidString:thread) != nil,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count <= 64_000 else { throw CodexAppWidgetError.unavailable }
        try await Task.detached(priority:.userInitiated) {
            let proxy = try CodexAppTransport.attach(configuration)
            // Persist a submission on the app's daemon; the app resumes/wakes it.
            // No turn/start, independent agent, model override or permission policy.
            do {
                let result = try proxy.call("thread/queue/add",params:["threadId":thread,"clientUserMessageId":UUID().uuidString,"input":[["type":"text","text":text]]])
                guard let queued = result["queuedSubmission"] as? [String:Any],let id = queued["id"] as? String,!id.isEmpty else { throw CodexAppWidgetError.uncertain }
            } catch { throw CodexAppWidgetError.uncertain }
        }.value
    }
}

extension Notification.Name { static let webbyCodexAppChanged = Notification.Name("webbyCodexAppChanged") }

@MainActor final class CodexWidgetHub {
    static let shared = CodexWidgetHub()
    private(set) var snapshot = CodexAppSnapshot()
    private var viewers = Set<ObjectIdentifier>()
    private var task:Task<Void,Never>?
    private var timer:Timer?
    private var cacheLoaded = false
    init() {
        NotificationCenter.default.addObserver(self,selector:#selector(wake),name:NSApplication.didBecomeActiveNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(sleep),name:NSApplication.didResignActiveNotification,object:nil)
    }
    func visible(_ owner:NSView,_ visible:Bool) {
        let id = ObjectIdentifier(owner)
        if visible { viewers.insert(id) } else { viewers.remove(id) }
        if viewers.isEmpty { sleep() } else { wake() }
    }
    @objc private func sleep() { timer?.invalidate(); timer = nil }
    @objc private func wake() {
        guard !viewers.isEmpty,NSApp.isActive else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in Task { @MainActor [weak self] in self?.refresh() } }
            timer?.tolerance = 10
        }
        refresh()
    }
    private func refresh() {
        guard task == nil,NSApp.isActive,!viewers.isEmpty else { return }
        let configuration = CodexAppConfiguration.current()
        task = Task {
            if !cacheLoaded {
                cacheLoaded = true; snapshot = await CodexAppWidgetStore.shared.cached()
                NotificationCenter.default.post(name:.webbyCodexAppChanged,object:nil)
            }
            snapshot = await CodexAppWidgetStore.shared.refresh(configuration)
            NotificationCenter.default.post(name:.webbyCodexAppChanged,object:nil)
            task = nil
        }
    }
    static func open(_ thread:String? = nil,wake:Bool = false) {
        if let url = CodexAppData.link(thread,wake:wake) { NSWorkspace.shared.open(url) }
    }
}

@MainActor private final class CodexChatButton:NSButton {
    let chat:CodexRecentChat
    var selected = false { didSet { needsDisplay = true } }
    var choose:((String)->Void)?
    init(_ chat:CodexRecentChat) {
        self.chat = chat; super.init(frame:.zero); title = ""; isBordered = false; target = self; action = #selector(pressed)
        toolTip = chat.title+"\n"+chat.directory; setAccessibilityLabel("Choose chat: "+chat.title)
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func pressed() { Motion.springScale(layer,from:0.98,to:1); choose?(chat.id) }
    override func draw(_ dirtyRect:NSRect) {
        if selected || isHighlighted {
            NSColor.white.withAlphaComponent(selected ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()
        }
        let icon = NSImage(systemSymbolName:"bubble.left",accessibilityDescription:nil)
        icon?.draw(in:NSRect(x:8,y:(bounds.height-16)/2,width:16,height:16))
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let roomy = bounds.height >= 39
        (chat.title as NSString).draw(in:NSRect(x:32,y:roomy ? bounds.height-21 : (bounds.height-17)/2,width:max(0,bounds.width-38),height:17),withAttributes:[.font:WebbyTypography.font(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
        if roomy {
            let folder = chat.directory.isEmpty ? "Codex" : URL(fileURLWithPath:chat.directory).lastPathComponent
            (folder as NSString).draw(in:NSRect(x:32,y:3,width:max(0,bounds.width-38),height:13),withAttributes:[.font:WebbyTypography.font(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:style])
        }
    }
}

@MainActor private final class CodexUsageMeter:NSView {
    var windowValue:CodexUsageWindow? {didSet {needsDisplay=true}}
    var secondaryValue:CodexUsageWindow? {didSet {needsDisplay=true}}
    var ringFrame:NSRect {
        let footer:CGFloat=bounds.height>=120 ? (secondaryValue == nil ? 24:42):0
        let side=max(0,min(bounds.width-8,bounds.height-footer-8))
        return NSRect(x:(bounds.width-side)/2,y:footer+(bounds.height-footer-side)/2,width:side,height:side)
    }
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    private func ring(_ rect:NSRect,value:CodexUsageWindow?,color:NSColor,line:CGFloat){
        guard rect.width>line else{return}
        let track=NSBezierPath(ovalIn:rect);track.lineWidth=line
        NSColor.white.withAlphaComponent(0.12).setStroke();track.stroke()
        guard let value,value.used.isFinite else{return}
        let fraction=CGFloat(max(0,min(100,value.used)))/100
        guard fraction>0 else{return}
        let arc=NSBezierPath();arc.lineWidth=line;arc.lineCapStyle = .round
        arc.appendArc(withCenter:NSPoint(x:rect.midX,y:rect.midY),radius:rect.width/2,startAngle:90,endAngle:90-360*fraction,clockwise:true)
        (fraction>=0.9 ? NSColor.systemOrange:color).setStroke();arc.stroke()
    }
    override func draw(_ dirtyRect:NSRect){
        super.draw(dirtyRect)
        let rect=ringFrame,line=max(2,min(8,rect.width*0.045))
        ring(rect.insetBy(dx:line/2,dy:line/2),value:windowValue,color:.systemMint,line:line)
        if secondaryValue != nil {ring(rect.insetBy(dx:line*2,dy:line*2),value:secondaryValue,color:.systemPurple,line:line*0.72)}
        guard bounds.height>=120 else{return}
        let style=NSMutableParagraphStyle();style.alignment = .center;style.lineBreakMode = .byTruncatingTail
        func label(_ value:CodexUsageWindow?,y:CGFloat,color:NSColor){
            let text=value.flatMap{$0.used.isFinite ? "\($0.title) · \(Int(max(0,min(100,$0.used)).rounded()))% used":nil} ?? "Usage unavailable"
            (text as NSString).draw(in:NSRect(x:2,y:y,width:max(0,bounds.width-4),height:18),withAttributes:[.font:WebbyTypography.font(ofSize:11,weight:.medium),.foregroundColor:color,.paragraphStyle:style])
        }
        label(windowValue,y:secondaryValue == nil ? 1:21,color:.labelColor)
        if secondaryValue != nil {label(secondaryValue,y:1,color:.systemPurple)}
    }
}

@MainActor final class CodexAppWidgetView:NSView,NSTextFieldDelegate {
    let usage:Bool
    private var profile:UUID?
    private var selected:String?
    private var snapshot = CodexAppSnapshot()
    private var rows:[CodexChatButton] = []
    private var feedVisible = false
    private var sending = false
    private var sendTask:Task<Void,Never>?
    private let heading = NSTextField(labelWithString:"")
    private let status = NSTextField(labelWithString:"")
    private let empty = NSTextField(wrappingLabelWithString:"")
    private let logo = NSButton(title:"",target:nil,action:nil)
    private let prompt = NSTextField(string:"")
    private let sendButton = NSButton(title:"↑",target:nil,action:nil)
    private let picker = NSButton(title:"Recent chats ⌄",target:nil,action:nil)
    private let primary = CodexUsageMeter(),secondary = CodexUsageMeter()
    private let tinyValue = NSTextField(labelWithString:"")
    init(usage:Bool) {
        self.usage = usage; super.init(frame:.zero); wantsLayer = true
        heading.stringValue = usage ? "Codex Usage" : "Codex Chats"; heading.font = WebbyTypography.font(ofSize:13,weight:.semibold)
        status.font = WebbyTypography.font(ofSize:10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        empty.font = WebbyTypography.font(ofSize:12); empty.textColor = .secondaryLabelColor
        tinyValue.font = .monospacedDigitSystemFont(ofSize:24,weight:.medium); tinyValue.alignment = .center
        if let path = Bundle.main.path(forResource:"CodexWhiteIcon",ofType:"png") { logo.image = NSImage(contentsOfFile:path) }
        logo.imageScaling = .scaleProportionallyUpOrDown; logo.isBordered = false; logo.target = self; logo.action = #selector(openApp)
        logo.toolTip = "Open in the existing Codex app"; logo.setAccessibilityLabel("Open Codex")
        prompt.placeholderString = "Choose a chat, then type…"; prompt.font = WebbyTypography.font(ofSize:13); prompt.isBezeled = false
        prompt.drawsBackground = false; prompt.focusRingType = .none; prompt.delegate = self
        prompt.target = self; prompt.action = #selector(sendPrompt); prompt.setAccessibilityLabel("Prompt for selected Codex chat")
        sendButton.isBordered = false; sendButton.font = WebbyTypography.font(ofSize:19,weight:.medium); sendButton.target = self; sendButton.action = #selector(sendPrompt)
        sendButton.setAccessibilityLabel("Queue prompt in Codex")
        picker.isBordered = false; picker.font = WebbyTypography.font(ofSize:11,weight:.medium); picker.target = self; picker.action = #selector(showChats)
        for view in [heading,status,empty,logo,prompt,sendButton,picker,primary,secondary,tinyValue] { addSubview(view) }
        NotificationCenter.default.addObserver(self,selector:#selector(changed),name:.webbyCodexAppChanged,object:nil)
        changed()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        // Visibility is revoked on removal. Sending is intentionally not retried.
    }
    func configure(profile:UUID) {
        guard self.profile != profile else { return }
        self.profile = profile
        selected = UserDefaults.standard.string(forKey:"webbyCodexChat."+profile.uuidString)
        prompt.stringValue = UserDefaults.standard.string(forKey:"webbyCodexDraft."+profile.uuidString) ?? ""
        changed()
    }
    func setFeedVisible(_ visible:Bool) {
        guard visible != feedVisible else { return }; feedVisible = visible
        CodexWidgetHub.shared.visible(self,visible && window != nil && !isHiddenOrHasHiddenAncestor)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CodexWidgetHub.shared.visible(self,feedVisible && window != nil && !isHiddenOrHasHiddenAncestor)
    }
    func containsControl(_ point:NSPoint)->Bool {
        ([logo,prompt,sendButton,picker]+rows).contains { !$0.isHidden && $0.frame.contains(point) }
    }
    func focusComposer() { if !usage,!prompt.isHidden { window?.makeFirstResponder(prompt) } }
    func controlTextDidChange(_ obj:Notification) { saveDraft(); sendButton.isEnabled = !sending && selected != nil && !prompt.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private func saveDraft() { if let profile { UserDefaults.standard.set(prompt.stringValue,forKey:"webbyCodexDraft."+profile.uuidString) } }
    @objc private func changed() {
        let new = CodexWidgetHub.shared.snapshot
        if new != snapshot { Motion.change(self,character:.widget) }
        if !usage,rows.map(\.chat) != new.chats {
            rows.forEach { $0.removeFromSuperview() }; rows = new.chats.map { chat in
                let row = CodexChatButton(chat); row.wantsLayer = true; row.choose = { [weak self] id in self?.choose(id) }; addSubview(row); return row
            }
        }
        snapshot = new
        // Keep an explicit selection. A disappearing/archived chat is never silently
        // replaced by a different recipient when a user has already typed a draft.
        for row in rows { row.selected = row.chat.id == selected }
        let chat = new.chats.first { $0.id == selected }
        prompt.placeholderString = chat.map { "Message \($0.title)…" } ?? "Choose a chat, then type…"
        picker.title = chat.map { String($0.title.prefix(36))+" ⌄" } ?? "Choose a recent chat ⌄"
        status.stringValue = new.status; status.toolTip = new.status
        if usage,let updated = new.usageUpdated {
            let date = RelativeDateTimeFormatter().localizedString(for:updated,relativeTo:Date())
            status.stringValue = (new.live ? "Updated " : "Saved ")+date+" · Codex app"
            status.toolTip = status.stringValue+" · "+new.status
        }
        empty.stringValue = usage ? "Usage isn’t available yet. Open Codex to refresh." : "Your recent Codex chats will appear here."
        primary.windowValue = new.windows.first; primary.secondaryValue = new.windows.dropFirst().first; secondary.windowValue = new.windows.dropFirst().first
        sendButton.isEnabled = !sending && selected != nil && chat != nil && !prompt.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        needsLayout = true
    }
    private func choose(_ id:String) {
        guard !sending,snapshot.chats.contains(where: { $0.id == id }) else { return }
        selected = id
        if let profile { UserDefaults.standard.set(id,forKey:"webbyCodexChat."+profile.uuidString) }
        changed(); window?.makeFirstResponder(prompt)
    }
    @objc private func showChats() {
        let menu = NSMenu(title:"Recent Codex Chats")
        for chat in snapshot.chats {
            let item = menu.addItem(withTitle:chat.title,action:#selector(menuChat(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = chat.id; item.state = selected == chat.id ? .on : .off
        }
        if menu.items.isEmpty { let item = menu.addItem(withTitle:"Open Codex to load chats",action:#selector(openApp),keyEquivalent:""); item.target = self }
        menu.popUp(positioning:nil,at:NSPoint(x:picker.frame.minX,y:picker.frame.minY),in:self)
    }
    @objc private func menuChat(_ item:NSMenuItem) { if let id = item.representedObject as? String { choose(id) } }
    @objc private func openApp() { CodexWidgetHub.open(usage ? nil : selected) }
    @objc private func sendPrompt() {
        let text = prompt.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !sending,!text.isEmpty,let selected,snapshot.chats.contains(where: { $0.id == selected }) else { return }
        let originalProfile = profile, originalDraft = prompt.stringValue
        sending = true; sendButton.isEnabled = false; picker.isEnabled = false; status.stringValue = "Sending to Codex…"
        let config = CodexAppConfiguration.current()
        sendTask = Task { [weak self] in
            do {
                try await CodexAppWidgetStore.shared.queue(text,thread:selected,configuration:config)
                CodexWidgetHub.open(selected,wake:true)
                CodexWidgetHub.open(selected)
                guard let self else { return }
                if self.profile == originalProfile,self.prompt.stringValue == originalDraft { self.prompt.stringValue = ""; self.saveDraft() }
                self.status.stringValue = "Queued in Codex"; Motion.change(self,character:.widget)
            } catch {
                self?.status.stringValue = (error as? CodexAppWidgetError)?.localizedDescription ?? "We couldn’t reach Codex. Your draft is still here."
                self?.status.toolTip = self?.status.stringValue
            }
            self?.sending = false; self?.picker.isEnabled = true; self?.sendTask = nil
            if let self { self.sendButton.isEnabled = self.selected != nil && !self.prompt.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            self?.needsLayout = true
        }
    }
    override func layout() {
        super.layout(); let w = bounds.width,h = bounds.height
        let tiny = w < 140 || h < 100
        heading.isHidden = tiny; heading.frame = NSRect(x:0,y:h-22,width:max(1,w-40),height:20)
        status.isHidden = tiny; status.frame = NSRect(x:0,y:0,width:w,height:15)
        prompt.isHidden = tiny || usage; sendButton.isHidden = tiny || usage; picker.isHidden = tiny || usage
        primary.isHidden = !usage || snapshot.windows.isEmpty
        tinyValue.isHidden = true
        secondary.isHidden = !usage || snapshot.windows.count < 2 || tiny
        empty.isHidden = tiny || (usage ? !snapshot.windows.isEmpty : !snapshot.chats.isEmpty)
        if usage {
            rows.forEach{$0.isHidden=true};primary.isHidden=false;secondary.isHidden=true;empty.isHidden=true;tinyValue.isHidden=true
            primary.frame=NSRect(x:0,y:tiny ? 0:30,width:w,height:max(1,h-(tiny ? 0:56)))
            let ring=primary.ringFrame
            logo.frame=primary.convert(ring.insetBy(dx:ring.width*0.23,dy:ring.height*0.23),to:self)
            let values=snapshot.windows.prefix(2).map { value in
                let amount=value.used.isFinite ? "\(Int(max(0,min(100,value.used)).rounded()))% used":"unavailable"
                let reset=value.resets.map{" · resets "+DateFormatter.localizedString(from:$0,dateStyle:.short,timeStyle:.short)} ?? ""
                return value.title+": "+amount+reset
            }
            primary.toolTip=values.isEmpty ? "Usage is unavailable. Open Codex to refresh.":values.joined(separator:"\n")
            logo.toolTip=primary.toolTip;logo.setAccessibilityLabel("Open Codex. "+(primary.toolTip ?? ""))
            return
        }
        if tiny {
            rows.forEach{$0.isHidden=true};primary.isHidden=true;secondary.isHidden=true
            let side=min(w,h)*0.65;logo.frame=NSRect(x:(w-side)/2,y:(h-side)/2,width:side,height:side)
            return
        }
        do {
            prompt.frame = NSRect(x:12,y:27,width:max(0,w-50),height:25)
            sendButton.frame = NSRect(x:w-35,y:25,width:29,height:29)
            picker.frame = NSRect(x:0,y:62,width:max(0,w-4),height:22)
            let wide = w >= 285 && w >= h*1.05
            let top = h-31,bottom:CGFloat = 92
            let side = min(max(0,top-bottom),wide ? min(104,max(40,w*0.28)) : min(74,max(24,(h-170)*0.4)))
            logo.frame = NSRect(x:wide ? w-side : (w-side)/2,y:wide ? max(bottom,(bottom+top-side)/2) : top-side,width:side,height:side)
            let listTop = wide ? top : top-side-9
            let rowHeight:CGFloat = h < 240 ? 36 : 45
            let capacity = max(0,Int((listTop-bottom)/rowHeight))
            let listWidth = wide ? max(0,w-side-14) : w
            for (index,row) in rows.enumerated() {
                row.isHidden = index >= capacity
                row.frame = NSRect(x:0,y:listTop-CGFloat(index+1)*rowHeight,width:listWidth,height:rowHeight-2)
            }
            empty.frame = NSRect(x:0,y:bottom,width:listWidth,height:max(0,listTop-bottom))
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard !usage,!prompt.isHidden else { return }
        NSColor.white.withAlphaComponent(0.065).setFill()
        let rect = NSRect(x:0,y:23,width:bounds.width,height:34)
        NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12).stroke()
    }
}
