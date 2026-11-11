import AppKit

enum BrowserEngineChecks {
    static let active = CommandLine.arguments.contains("--check-engine-ui")
}

enum BrowserEngine: String, CaseIterable, Codable {
    case webKit, chromium
    var name: String { self == .webKit ? "WebKit" : "Chromium" }
    var other: Self { self == .webKit ? .chromium : .webKit }
    static var defaultEngine: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: "webbyDefaultRenderingEngine") ?? "") ?? .webKit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "webbyDefaultRenderingEngine") }
    }
    var colors: [NSColor] {
        switch self {
        case .webKit:
            return [NSColor(srgbRed: 0.13, green: 0.33, blue: 0.96, alpha: 1),
                    NSColor(srgbRed: 0.12, green: 0.66, blue: 1, alpha: 1),
                    NSColor(srgbRed: 0.38, green: 0.91, blue: 1, alpha: 1)]
        case .chromium:
            return [NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1),
                    NSColor(srgbRed: 0.20, green: 0.72, blue: 0.40, alpha: 1),
                    NSColor(srgbRed: 0.99, green: 0.77, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.96, green: 0.31, blue: 0.29, alpha: 1)]
        }
    }
}

@MainActor final class EngineSwitchPrompt: NSViewController {
    private let engine: BrowserEngine
    private let hasEdits: Bool
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    init(engine: BrowserEngine, hasEdits: Bool) {
        self.engine = engine; self.hasEdits = hasEdits
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 136))
        let title = NSTextField(labelWithString: "Reload this page in \(engine.name)?")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: hasEdits
            ? "This page has unsaved edits. Switching reloads the page and may lose them. Logins are separate."
            : "The page will reload. Each engine keeps its own logins and website data.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: "Reload in \(engine.name)", target: self, action: #selector(confirmAction))
        confirm.bezelStyle = .rounded; confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, detail, buttons]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            detail.widthAnchor.constraint(equalToConstant: 298)])
    }
    @objc private func confirmAction() { onConfirm?() }
    @objc private func cancelAction() { onCancel?() }
}

struct BrowserEngineRule: Identifiable, Codable, Equatable {
    enum Scope: String, Codable, CaseIterable {
        case site, link
        var title: String { self == .site ? "Whole site" : "Exact link" }
    }

    let scope: Scope
    let address: String
    var engine: BrowserEngine
    var id: String { scope.rawValue + ":" + address }

    private static let key = "webbyEngineRules"
    static var saved: [Self] {
        get {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    init?(input: String, scope: Scope, engine: BrowserEngine) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "https://" + value
        guard !value.isEmpty, let url = URL(string: address),
              let parts = Self.webAddress(url), let host = parts.host,
              scope != .link || value.contains("://") else { return nil }
        self.scope = scope
        self.address = scope == .site ? host : parts.string ?? address
        self.engine = engine
    }

    static func match(_ url: URL, in rules: [Self]) -> Self? {
        guard !rules.isEmpty, let parts = webAddress(url), let host = parts.host else { return nil }
        if let link = rules.first(where: { $0.scope == .link && $0.address == parts.string }) {
            return link
        }
        return rules.filter {
            $0.scope == .site && (host == $0.address || host.hasSuffix("." + $0.address))
        }.max { $0.address.count < $1.address.count }
    }

    static func engine(for url: URL) -> BrowserEngine? {
        guard let rule = match(url, in: saved),
              rule.engine != .chromium || WBChromiumAvailable() else { return nil }
        return rule.engine
    }

    private static func webAddress(_ url: URL) -> URLComponents? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host?.lowercased(), !rawHost.isEmpty,
              parts.user == nil, parts.password == nil,
              !rawHost.contains(where: \.isWhitespace) else { return nil }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        guard !host.isEmpty else { return nil }
        parts.host = host
        parts.scheme = scheme
        if parts.path.isEmpty { parts.path = "/" }
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        return parts
    }
}
