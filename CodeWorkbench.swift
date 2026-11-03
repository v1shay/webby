import AppKit
import WebKit
import Darwin

// Insert only missing defaults. Keep JSONC comments, explicit overrides, and formatting intact.
enum WorkbenchEnergyDefaults {
    static let values: [String: Any] = [
        "java.server.launchMode": "Standard",
        "java.import.exclusions": ["**/node_modules/**", "**/.metadata/**", "**/archetype-resources/**", "**/META-INF/maven/**", "**/.webby-build/**", "**/.gradle/**"],
        "files.watcherExclude": ["**/.webby-build/**": true, "**/.gradle/**": true, "**/node_modules/**": true],
        "search.exclude": ["**/.webby-build/**": true, "**/.gradle/**": true],
        "terminal.integrated.enablePersistentSessions": false,
        "git.openRepositoryInParentFolders": "never",
        "editor.minimap.enabled": false
    ]
    private struct Inventory: Decodable {
        struct Key: CodingKey {
            let stringValue: String; var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        let keys: Set<String>
        init(from decoder: Decoder) throws { keys = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)) }
    }
    static func applying(to original: String) throws -> String {
        let decoder = JSONDecoder(); decoder.allowsJSON5 = true
        let keys = try decoder.decode(Inventory.self, from: Data(original.utf8)).keys
        let additions = values.filter { !keys.contains($0.key) }
        guard !additions.isEmpty else { return original }
        let expression = try NSRegularExpression(pattern: #"\A(?:\s|//[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*\{"#)
        let text = original as NSString
        guard let prefix = expression.firstMatch(in: original, range: NSRange(location: 0, length: text.length)) else { return original }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: additions, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let properties = String(json.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.substring(to: prefix.range.length) + "\n" + properties + (keys.isEmpty ? "\n" : ",\n") + text.substring(from: prefix.range.length)
    }
    static func install(at file: URL) throws {
        let original = try String(contentsOf: file, encoding: .utf8)
        let updated = try applying(to: original)
        guard original != updated else { return }
        let backup = file.appendingPathExtension("before-webby-energy")
        if !FileManager.default.fileExists(atPath: backup.path) { try Data(original.utf8).write(to: backup, options: .withoutOverwriting) }
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }
}

// FileHandle callbacks drain output off the UI thread. After readiness, discard logs
// without creating a main-actor task for every extension/terminal log chunk.
private final class WorkbenchStartupOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var delivered = false
    func consume(_ data: Data) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return nil }
        buffer = String((buffer + String(decoding: data, as: UTF8.self)).suffix(12000))
        guard let range = buffer.range(of: #"http://127\.0\.0\.1:\d+/"#, options: .regularExpression), let url = URL(string: String(buffer[range])) else { return nil }
        delivered = true; buffer = ""; return url
    }
}

// One authenticated loopback server shared by IDE tabs; no browser profile data.
@MainActor final class CodeWorkbenchRuntime {
    static let shared = CodeWorkbenchRuntime()
    private var process: Process?
    private var preparing = false
    private var clients = Set<UUID>()
    private var pending: [(Result<URL, Error>) -> Void] = []
    private var endpoint: URL?
    private var generation = UUID()
    static var testing: Bool { Bundle.main.bundleIdentifier == "local.webby.performance-tests" }
    private func availablePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(clamping: Self.testing ? 0 : UserDefaults.standard.integer(forKey: "webbyIDEPort")).bigEndian
        func attempt() -> Int32 { withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        if attempt() != 0 { address.sin_port = 0; guard attempt() == 0 else { return 0 } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard status == 0 else { return 0 }
        let port = UInt16(bigEndian: address.sin_port)
        if !Self.testing { UserDefaults.standard.set(Int(port), forKey: "webbyIDEPort") }
        return port
    }
    let password = UUID().uuidString + UUID().uuidString
    static var executable: String? {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Webby IDE/Runtime/bin/code-server").path, "/opt/homebrew/bin/code-server", "/usr/local/bin/code-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func acquire(_ id: UUID, ready: @escaping (Result<URL, Error>) -> Void) {
        clients.insert(id)
        if let endpoint { ready(.success(endpoint)); return }
        pending.append(ready)
        guard process == nil, !preparing else { return }
        guard let executable = Self.executable else {
            finish(.failure(NSError(domain: "WebbyIDE", code: 1, userInfo: [NSLocalizedDescriptionKey: "The VS Code runtime isn’t installed. Install code-server, then reopen this tab."]))); return
        }
        preparing = true
        let token = UUID(); generation = token
        let testing = Self.testing
        Task { [weak self] in
            do {
                let files = try await Task.detached(priority: .utility) { try Self.prepareFiles(testing: testing) }.value
                guard let self, self.generation == token else { return }
                self.preparing = false
                guard !self.clients.isEmpty else { self.stop(); return }
                self.launch(executable: executable, files: files, token: token)
            } catch {
                guard let self, self.generation == token else { return }
                self.preparing = false; self.finish(.failure(error))
            }
        }
    }
    private struct LaunchFiles: Sendable { let directory: URL; let config: URL; let extensions: URL }
    private nonisolated static func prepareFiles(testing: Bool) throws -> LaunchFiles {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Webby IDE", isDirectory: true)
        let directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("webby-ide-test-" + UUID().uuidString) : support.appendingPathComponent("Workbench", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: config.path) { try "{}\n".write(to: config, atomically: true, encoding: .utf8) }
        let settingsFolder = directory.appendingPathComponent("User", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
        let settings = settingsFolder.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: settings.path) {
            var preferences: [String: Any] = ["workbench.colorTheme": "Default Dark Modern", "window.autoDetectColorScheme": false, "files.autoSave": "off", "files.hotExit": "onExitAndWindowClose", "editor.smoothScrolling": true, "workbench.list.smoothScrolling": true, "editor.cursorSmoothCaretAnimation": "explicit", "editor.cursorBlinking": "smooth", "workbench.reduceMotion": "auto", "telemetry.telemetryLevel": "off", "workbench.startupEditor": "none", "workbench.secondarySideBar.defaultVisibility": "hidden", "workbench.colorCustomizations": ["editor.background": "#17252bA8", "sideBar.background": "#20333b80", "activityBar.background": "#19313b66", "titleBar.activeBackground": "#21394080", "statusBar.background": "#19343b88", "panel.background": "#172a33A0"]]
            if testing { preferences["security.workspace.trust.enabled"] = false } // Only generated, known-safe fixture projects.
            try JSONSerialization.data(withJSONObject: preferences, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
        }
        // If an externally edited settings file is temporarily invalid, do not
        // block startup or rewrite it. The editor can still repair it normally.
        try? WorkbenchEnergyDefaults.install(at: settings)
        return LaunchFiles(directory: directory, config: config, extensions: support.appendingPathComponent("Workbench/extensions"))
    }
    private func launch(executable: String, files: LaunchFiles, token: UUID) {
        do {
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = ["--bind-addr", "127.0.0.1:\(availablePort())", "--auth", "password", "--disable-telemetry", "--disable-update-check", "--config", files.config.path, "--user-data-dir", files.directory.path, "--extensions-dir", files.extensions.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PASSWORD"] = password
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            task.environment = environment; task.standardOutput = pipe; task.standardError = pipe
            let startup = WorkbenchStartupOutput()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                guard let url = startup.consume(data) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.endpoint = url; self.finish(.success(url))
                }
            }

            task.terminationHandler = { [weak self] _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.process = nil; self.endpoint = nil
                    self.finish(.failure(NSError(domain: "WebbyIDE", code: 2, userInfo: [NSLocalizedDescriptionKey: "The IDE runtime stopped. Close and reopen the IDE tab to restart it."])))
                }
            }
            process = task; try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
                guard let self, self.generation == token, self.endpoint == nil else { return }
                self.process?.terminate()
                self.finish(.failure(NSError(domain: "WebbyIDE", code: 3, userInfo: [NSLocalizedDescriptionKey: "The IDE took too long to start. Reopen the tab to try again."])))
            }
        } catch { process = nil; finish(.failure(error)) }
    }
    func stop() { preparing = false; generation = UUID(); process?.terminate(); process = nil; endpoint = nil; pending.removeAll() }
    private func finish(_ result: Result<URL, Error>) { let callbacks = pending; pending.removeAll(); callbacks.forEach { $0(result) } }
    func release(_ id: UUID) {
        clients.remove(id)
        // Let VS Code's hot-exit service save recovery state before stopping.
        guard clients.isEmpty else { return }
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.clients.isEmpty, self.generation == token else { return }
            self.stop()
        }
    }
}

@MainActor final class CodeWorkbench: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view = NSVisualEffectView()
    private let web: WKWebView
    private let message = NSTextField(labelWithString: "Let’s open our workspace…")
    private let id = UUID()
    private var endpoint: URL?
    private var closed = false
    private var started = false
    private(set) var projectURL: URL?
    var titleChanged: ((String) -> Void)?
    override init() {
        let configuration = WKWebViewConfiguration()
        if #available(macOS 14, *), !CodeWorkbenchRuntime.testing {
            let key = "webbyIDEWebsiteStore"
            let identifier = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
            UserDefaults.standard.set(identifier.uuidString, forKey: key)
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        } else { configuration.websiteDataStore = .nonPersistent() }
        configuration.userContentController.addUserScript(WKUserScript(source: "const s=document.createElement('style');s.textContent='html,body,.monaco-workbench{background:transparent!important}';document.documentElement.appendChild(s)", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.material = .underWindowBackground; view.blendingMode = .withinWindow; view.state = .active
        web.navigationDelegate = self; web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        let controls = NSStackView(); controls.spacing = 8
        for (symbol, title, action) in [("folder", "Open Project", #selector(chooseProject)), ("folder.badge.plus", "New Project", #selector(newProject))] {
            let button = GlassButton(symbol: symbol, label: title, target: self, action: action)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            controls.addArrangedSubview(button)
        }
        message.font = WebbyTypography.font(ofSize: 12); message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingMiddle
        controls.addArrangedSubview(message)
        for child in [controls, web] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), controls.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12), controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), controls.heightAnchor.constraint(equalToConstant: 32),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor), web.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8), web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    func start() {
        guard !started, !closed else { return }; started = true
        CodeWorkbenchRuntime.shared.acquire(id) { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let url): self.endpoint = url; self.authenticate()
            case .failure(let error): self.message.stringValue = error.localizedDescription
            }
        }
    }
    private func authenticate() {
        guard let endpoint else { return }
        var login = URLComponents(url: endpoint.appendingPathComponent("login"), resolvingAgainstBaseURL: false)!
        login.queryItems = [URLQueryItem(name: "to", value: destinationPath)]
        var request = URLRequest(url: login.url!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = Data(("password=" + CodeWorkbenchRuntime.shared.password).utf8)
        web.load(request)
    }
    private var destinationPath: String {
        var route = URLComponents(); route.path = "/"
        if let projectURL { route.queryItems = [URLQueryItem(name: "folder", value: projectURL.path)] }
        return route.string ?? "/"
    }
    func openFolder(_ url: URL) {
        projectURL = url.standardizedFileURL
        IDERecentProjects.record(url)
        titleChanged?("IDE · " + url.lastPathComponent)
        if endpoint != nil { authenticate() }
    }
    @objc private func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }
    @objc private func newProject() {
        let panel = NSSavePanel(); panel.title = "New Java Project"; panel.nameFieldStringValue = "JavaProject"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try "public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Hello, Webby!\");\n    }\n}\n".write(to: url.appendingPathComponent("Main.java"), atomically: true, encoding: .utf8)
            openFolder(url)
        } catch { message.stringValue = error.localizedDescription }
    }
    func focus() { view.window?.makeFirstResponder(web) }
    func shortcut(_ key: String, shift: Bool = false, keyCode: UInt16) {
        guard let window = view.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode) else { return }
        web.keyDown(with: event)
    }
    func save() { shortcut("s", keyCode: 1) }
    func mayClose() -> Bool {
        let alert = NSAlert(); alert.messageText = "Close this IDE workspace?"
        alert.informativeText = "Save any changes you want to keep before closing. Unsaved editor recovery is managed by the workbench."
        alert.addButton(withTitle: "Close Workspace"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func shutdown() { guard !closed else { return }; closed = true; web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil; CodeWorkbenchRuntime.shared.release(id) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "folder" })?.value, path.hasPrefix("/") {
            projectURL = URL(fileURLWithPath: path).standardizedFileURL
            if let projectURL { IDERecentProjects.record(projectURL) }
            titleChanged?("IDE · " + (projectURL?.lastPathComponent ?? "Workspace"))
        }
        message.stringValue = projectURL?.lastPathComponent ?? "Workspace · Open a project to begin"
        Motion.reveal(web, character: .editor)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { message.stringValue = error.localizedDescription } }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.host == "127.0.0.1", url.port == endpoint?.port { decisionHandler(.allow) }
        else { decisionHandler(.cancel); if action.navigationType == .linkActivated, let url = action.request.url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage text: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = text; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
