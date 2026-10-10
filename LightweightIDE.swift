import AppKit

// IDE projects are independent of browser profiles, website data and cookies.
enum IDEJava {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func mainClass(file: URL, source: String) -> String {
        let stripped = source.replacingOccurrences(of: #"(?s)/\*.*?\*/|(?m)//[^\n]*"#, with: "", options: .regularExpression)
        let expression = try! NSRegularExpression(pattern: #"(?m)^\s*package\s+([\p{L}\p{N}_$.]+)\s*;"#)
        let range = NSRange(stripped.startIndex..., in: stripped)
        if let match = expression.firstMatch(in: stripped, range: range), let name = Range(match.range(at: 1), in: stripped) {
            return String(stripped[name]) + "." + file.deletingPathExtension().lastPathComponent
        }
        return file.deletingPathExtension().lastPathComponent
    }
    static func sources(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let file as URL in walker {
            let info = try file.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink == true || ["node_modules", "build", "target"].contains(file.lastPathComponent) { walker.skipDescendants(); continue }
            if info.isDirectory != true && file.pathExtension == "java" { result.append(file) }
            if result.count > 2000 { throw NSError(domain: "WebbyIDE", code: 1, userInfo: [NSLocalizedDescriptionKey: "This project has more than 2,000 Java source files."]) }
        }
        return result.sorted { $0.path < $1.path }
    }
    static func command(root: URL, jdk: URL, files: [URL], main: String?, marker: String) -> String {
        let output = root.appendingPathComponent(".webby-build/classes-" + UUID().uuidString)
        let javac = jdk.appendingPathComponent("bin/javac")
        let java = jdk.appendingPathComponent("bin/java")
        var action = "cd -- \(quote(root.path)) && mkdir -p \(quote(output.path)) && \(quote(javac.path)) -encoding UTF-8 -d \(quote(output.path)) " + files.map { quote($0.path) }.joined(separator: " ")
        if let main { action += " && \(quote(java.path)) -cp \(quote(output.path)) \(quote(main))" }
        return "( \(action); webby_java_status=$?; printf '\\n\(marker):%s\\n' \"$webby_java_status\" )"
    }
}

private final class IDEFile {
    let url: URL
    let directory: Bool
    var children: [IDEFile]?
    init(_ url: URL) {
        self.url = url
        let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        directory = info?.isDirectory == true && info?.isSymbolicLink != true
    }
    func contents() -> [IDEFile] {
        if let children { return children }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.filter { !["node_modules"].contains($0.lastPathComponent) }.map(IDEFile.init).sorted {
            $0.directory != $1.directory ? $0.directory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        children = nodes; return nodes
    }
}

private final class IDEEditor: NSTextView {
    var onSave: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": onSave?()
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "a": selectAll(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0))
        let preceding = text.substring(with: NSRange(location: line.location, length: min(selectedRange().location - line.location, line.length)))
        let indentation = String(preceding.prefix { $0 == " " || $0 == "\t" }) + (preceding.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? "    " : "")
        insertText("\n" + indentation, replacementRange: selectedRange())
    }
}

private final class IDELineNumbers: NSRulerView {
    weak var editor: NSTextView?
    init(scroll: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor; ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let text = editor.string as NSString
        guard text.length > 0, layout.numberOfGlyphs > 0 else {
            ("1" as NSString).draw(at: NSPoint(x: 8, y: 14), withAttributes: attributes)
            return
        }
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        var character = layout.characterIndexForGlyph(at: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)))
        character = text.lineRange(for: NSRange(location: min(character, text.length), length: 0)).location
        var number = text.substring(to: character).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        while character < text.length {
            let glyph = layout.glyphIndexForCharacter(at: character)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = line.minY + editor.textContainerOrigin.y - visible.minY
            if y > bounds.height { break }
            if y > -24 { ("\(number)" as NSString).draw(at: NSPoint(x: 8, y: y + 1), withAttributes: attributes) }
            let next = NSMaxRange(text.lineRange(for: NSRange(location: character, length: 0)))
            guard next > character else { break }
            character = next; number += 1
        }
    }
}

@MainActor final class LightweightIDE: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSSplitViewDelegate {
    let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
    private var window: NSWindow? { view.window }
    var onTitleChange: ((String) -> Void)?
    var projectURL: URL? { root?.url }
    private let editor = IDEEditor()
    private let outline = NSOutlineView()
    private let fileScroll = NSScrollView()
    private let editorScroll = NSScrollView()
    private let projects = NSPopUpButton()
    private let filename = NSTextField(labelWithString: "Open a file to start")
    private let status = NSTextField(labelWithString: "Ready")
    private let entry = NSTextField()
    private var terminal: NativeTerminalPane!
    private var root: IDEFile?
    private var currentFile: URL?
    private var baseline = ""
    private var loadingFile = false
    private var highlightWork: DispatchWorkItem?
    private var projectURLs: [URL] = []
    private var marker: String?
    private var outputTail = ""
    private var dirty: Bool { currentFile != nil && editor.string != baseline }
    private let registry = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Webby IDE/projects.json")

    override init() {
        super.init()
        if let data = try? Data(contentsOf: registry), let paths = try? JSONDecoder().decode([String].self, from: data) {
            projectURLs = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        buildView()
        refreshProjects()
    }
    func show() { view.isHidden = false; view.layoutSubtreeIfNeeded(); updateEditorViewport(); terminal.open(); focus() }
    func focus() { window?.makeFirstResponder(editor) }
    func restoreProject(_ url: URL) { setProject(url) }
    func mayClose() -> Bool { resolveEdits() }
    func shutdown() { highlightWork?.cancel(); terminal.stop() }
    private func buildView() {
        let glass = view
        glass.material = .underWindowBackground; glass.blendingMode = .behindWindow; glass.state = .active
        let controls = NSStackView()
        controls.spacing = 8; controls.alignment = .centerY
        func button(_ symbol: String, _ title: String, _ action: Selector) -> GlassButton {
            let button = GlassButton(symbol: symbol, label: title, target: self, action: action)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        projects.target = self; projects.action = #selector(selectProject)
        projects.widthAnchor.constraint(equalToConstant: 190).isActive = true
        entry.placeholderString = "Main class"; entry.stringValue = "Main"
        entry.isBordered = false; entry.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        entry.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        entry.widthAnchor.constraint(equalToConstant: 190).isActive = true
        [button("folder.badge.plus", "New Project", #selector(newProject)), button("folder", "Open Project", #selector(openProject)), projects,
         button("doc.badge.plus", "New File", #selector(newFile)), button("folder.badge.plus", "New Folder", #selector(newFolder)),
         button("square.and.arrow.down", "Save File", #selector(saveAction)), entry,
         button("hammer", "Compile Java", #selector(compileJava)), button("play.fill", "Compile and Run Java", #selector(runJava)),
         button("stop.fill", "Stop", #selector(stopJava)), button("arrow.clockwise", "Refresh Files", #selector(refreshFiles))].forEach { controls.addArrangedSubview($0) }
        let body = NSSplitView(); body.isVertical = true; body.dividerStyle = .thin; body.delegate = self
        fileScroll.hasVerticalScroller = true; fileScroll.drawsBackground = false
        outline.backgroundColor = .clear; outline.rowHeight = 29; outline.indentationPerLevel = 14
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self
        outline.addTableColumn(NSTableColumn(identifier: .init("file"))); outline.outlineTableColumn = outline.tableColumns[0]
        outline.target = self; outline.action = #selector(openSelectedFile)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu(); menu.delegate = self
        outline.menu = menu; fileScroll.documentView = outline
        let content = NSSplitView(); content.isVertical = false; content.dividerStyle = .thin; content.delegate = self
        let editContainer = NSView()
        filename.font = .monospacedSystemFont(ofSize: 12, weight: .medium); filename.textColor = .secondaryLabelColor
        filename.lineBreakMode = .byTruncatingMiddle
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .labelColor; editor.insertionPointColor = .systemTeal
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.autoresizingMask = [.width]; editor.delegate = self
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.onSave = { [weak self] in _ = self?.saveFile() }
        editorScroll.hasVerticalScroller = true; editorScroll.hasHorizontalScroller = true; editorScroll.drawsBackground = false
        editorScroll.documentView = editor
        editorScroll.verticalRulerView = IDELineNumbers(scroll: editorScroll, editor: editor)
        editorScroll.hasVerticalRuler = true; editorScroll.rulersVisible = true
        editor.isEditable = false
        terminal = NativeTerminalPane(target: self, action: #selector(focusEditor))
        terminal.onOutput = { [weak self] data in self?.receiveOutput(data) }
        terminal.onInterrupt = { [weak self] in self?.marker = nil; self?.status.stringValue = "Interrupted" }
        terminal.onShellExit = { [weak self] in self?.marker = nil; self?.status.stringValue = "Shell exited · Run or click the terminal to start again" }
        terminal.toolTip = "Interactive project terminal · Control-C stops the current command"
        for view in [filename, editorScroll] { view.translatesAutoresizingMaskIntoConstraints = false; editContainer.addSubview(view) }
        NSLayoutConstraint.activate([
            filename.leadingAnchor.constraint(equalTo: editContainer.leadingAnchor, constant: 16), filename.topAnchor.constraint(equalTo: editContainer.topAnchor, constant: 10), filename.trailingAnchor.constraint(equalTo: editContainer.trailingAnchor, constant: -16),
            editorScroll.leadingAnchor.constraint(equalTo: editContainer.leadingAnchor), editorScroll.trailingAnchor.constraint(equalTo: editContainer.trailingAnchor), editorScroll.topAnchor.constraint(equalTo: filename.bottomAnchor, constant: 9), editorScroll.bottomAnchor.constraint(equalTo: editContainer.bottomAnchor)
        ])
        content.addArrangedSubview(editContainer); content.addArrangedSubview(terminal)
        body.addArrangedSubview(fileScroll); body.addArrangedSubview(content)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor
        for view in [controls, body, status] { view.translatesAutoresizingMaskIntoConstraints = false; glass.addSubview(view) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: glass.topAnchor, constant: 12), controls.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16),
            body.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12), body.leadingAnchor.constraint(equalTo: glass.leadingAnchor), body.trailingAnchor.constraint(equalTo: glass.trailingAnchor), body.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -7),
            status.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -16), status.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -9), status.heightAnchor.constraint(equalToConstant: 16)
        ])
        glass.layoutSubtreeIfNeeded(); body.setPosition(230, ofDividerAt: 0); content.setPosition(430, ofDividerAt: 0)
        updateEditorViewport()
    }
    @objc private func focusEditor() { window?.makeFirstResponder(editor) }
    private func refreshProjects() {
        projects.removeAllItems(); projects.addItem(withTitle: "Choose project…")
        for url in projectURLs { projects.addItem(withTitle: url.lastPathComponent); projects.lastItem?.toolTip = url.path }
        if let root, let index = projectURLs.firstIndex(of: root.url) { projects.selectItem(at: index + 1) }
    }
    private func rememberProject(_ url: URL) {
        projectURLs.removeAll { $0 == url }; projectURLs.insert(url, at: 0)
        do {
            try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(projectURLs.map(\.path)).write(to: registry, options: .atomic)
        } catch { status.stringValue = "Project opened; couldn’t save recent projects." }
        refreshProjects()
    }
    @objc private func selectProject() {
        let index = projects.indexOfSelectedItem - 1
        guard projectURLs.indices.contains(index) else { return }
        setProject(projectURLs[index])
    }
    @objc private func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProject(url)
    }
    @objc private func newProject() {
        guard allowProjectChange(), resolveEdits() else { return }
        let panel = NSSavePanel(); panel.title = "New Java Project"; panel.prompt = "Create Project"; panel.nameFieldStringValue = "Java Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw failure("That folder already exists. Use Open Project.") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Hello from Webby!\");\n    }\n}\n".write(to: url.appendingPathComponent("Main.java"), atomically: true, encoding: .utf8)
            setProject(url); loadFile(url.appendingPathComponent("Main.java"))
        } catch { showError(error) }
    }
    private func allowProjectChange() -> Bool {
        guard marker == nil else { showError(failure("Stop the running Java command before switching projects.")); return false }
        return true
    }
    private func setProject(_ url: URL) {
        guard root?.url != url.standardizedFileURL else { return }
        guard allowProjectChange(), resolveEdits() else { refreshProjects(); return }
        root = IDEFile(url.standardizedFileURL); currentFile = nil; baseline = ""; editor.string = ""; editor.isEditable = false
        editor.undoManager?.removeAllActions(); filename.stringValue = url.path; onTitleChange?("IDE · \(root?.url.lastPathComponent ?? url.lastPathComponent)")
        rememberProject(url); refreshFiles()
        terminal.open(); terminal.sendCommand("cd -- " + IDEJava.quote(url.path))
        status.stringValue = "\(url.path) · Drop files into the sidebar to import"
    }
    @objc private func refreshFiles() { root?.children = nil; outline.reloadData(); editorScroll.verticalRulerView?.needsDisplay = true }
    @objc private func openSelectedFile() {
        guard let node = outline.item(atRow: outline.selectedRow) as? IDEFile, !node.directory else { return }
        loadFile(node.url)
    }
    private func loadFile(_ url: URL) {
        guard url != currentFile, resolveEdits() else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 5_000_000 else { throw failure("Files larger than 5 MB should be opened in an external editor.") }
            let data = try Data(contentsOf: url)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw failure("This file isn’t UTF-8 text. Reveal it in Finder to open it elsewhere.") }
            loadingFile = true; editor.string = text; baseline = text; currentFile = url; editor.isEditable = true
            editor.undoManager?.removeAllActions(); loadingFile = false
            entry.stringValue = url.pathExtension == "java" ? IDEJava.mainClass(file: url, source: text) : entry.stringValue
            updateFilename(); highlight(); window?.makeFirstResponder(editor)
        } catch { loadingFile = false; showError(error) }
    }
    @objc private func saveAction() { _ = saveFile() }
    @discardableResult private func saveFile() -> Bool {
        guard let file = currentFile, dirty else { return true }
        do {
            if let disk = try? String(contentsOf: file, encoding: .utf8), disk != baseline {
                let alert = NSAlert(); alert.messageText = "This file changed on disk"; alert.informativeText = "Replace it with the editor’s contents?"
                alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
            try editor.string.write(to: file, atomically: true, encoding: .utf8)
            baseline = editor.string; updateFilename(); status.stringValue = "Saved \(file.lastPathComponent)"; return true
        } catch { showError(error); return false }
    }
    private func resolveEdits() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(currentFile!.lastPathComponent)?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: return saveFile(); case .alertSecondButtonReturn: editor.string = baseline; updateFilename(); highlight(); return true; default: return false }
    }
    private func updateFilename() { filename.stringValue = (currentFile?.path ?? "Open a file to start") + (dirty ? "  •" : "") }
    func textDidChange(_ notification: Notification) {
        guard !loadingFile else { return }; updateFilename()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }; highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    private func highlight() {
        guard let storage = editor.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing(); storage.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], range: range)
        if currentFile?.pathExtension == "java" {
            let patterns: [(String, NSColor)] = [
                (#"\b(?:class|public|private|protected|static|void|final|new|return|if|else|for|while|import|package|extends|implements|try|catch|throw|throws|int|double|boolean|long|float|char|byte|short|true|false|null|this|super|interface|enum|record|switch|case|break|continue)\b"#, .systemPurple),
                (#"\b\d+(?:\.\d+)?\b"#, .systemOrange),
                (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, .systemTeal),
                (#"(?m)//[^\n]*|(?s)/\*.*?\*/"#, .secondaryLabelColor)
            ]
            for (pattern, color) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    for match in regex.matches(in: editor.string, range: range) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                }
            }
        }
        storage.endEditing(); editor.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.labelColor]
        editorScroll.verticalRulerView?.needsDisplay = true
    }
    private func selectedFolder() -> URL? {
        guard let root else { return nil }
        if let node = outline.item(atRow: outline.selectedRow) as? IDEFile { return node.directory ? node.url : node.url.deletingLastPathComponent() }
        return root.url
    }
    private func promptName(_ title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 300, height: 28); alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\n") else { showError(failure("Choose a single file or folder name.")); return nil }
        return name
    }
    @objc private func newFile() { createItem(directory: false) }
    @objc private func newFolder() { createItem(directory: true) }
    private func createItem(directory: Bool) {
        guard let folder = selectedFolder() else { openProject(); return }
        guard directory || resolveEdits(), let name = promptName(directory ? "New Folder" : "New File", initial: directory ? "Folder" : "Main.java") else { return }
        let url = folder.appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw failure("An item with that name already exists.") }
            if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            else { try "".write(to: url, atomically: true, encoding: .utf8) }
            refreshFiles(); if !directory { loadFile(url) }
        } catch { showError(error) }
    }
    @objc private func compileJava() { executeJava(run: false) }
    @objc private func runJava() { executeJava(run: true) }
    @objc private func stopJava() { terminal.interrupt(); marker = nil; status.stringValue = "Interrupt sent · Control-C also stops commands" }
    private func executeJava(run: Bool) {
        guard let root else { openProject(); return }
        guard marker == nil else { showError(failure("A Java command is already running. Stop it first.")); return }
        guard saveFile() else { return }
        do {
            let files = try IDEJava.sources(in: root.url)
            guard !files.isEmpty else { throw failure("This project has no Java source files.") }
            let main = entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if run, main.range(of: #"^[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)*$"#, options: .regularExpression) == nil { throw failure("Enter the main class, for example Main or example.Main.") }
            let discovery = Process(); discovery.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
            let pipe = Pipe(); discovery.standardOutput = pipe; discovery.standardError = FileHandle.nullDevice
            try discovery.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); discovery.waitUntilExit()
            guard discovery.terminationStatus == 0, let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { throw failure("Install a JDK to compile Java. Webby uses /usr/libexec/java_home to find it.") }
            let token = "WEBBY_JAVA_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            marker = token; outputTail = ""; terminal.open()
            terminal.sendCommand(IDEJava.command(root: root.url, jdk: URL(fileURLWithPath: path), files: files, main: run ? main : nil, marker: token))
            status.stringValue = run ? "Compiling and running \(main)…" : "Compiling \(files.count) Java files…"
        } catch { showError(error) }
    }
    private func receiveOutput(_ data: Data) {
        guard let marker else { return }
        outputTail += String(decoding: data, as: UTF8.self)
        // The shell echoes the command before execution; accept only a result on
        // its own line, never the marker inside the echoed printf command.
        let pattern = "(?:^|[\\r\\n])" + marker + ":([0-9]+)[\\r\\n]"
        if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: outputTail, range: NSRange(outputTail.startIndex..., in: outputTail)), let result = Range(match.range(at: 1), in: outputTail) {
            let code = Int(outputTail[result]) ?? 1
            self.marker = nil; status.stringValue = code == 0 ? "Finished successfully" : "Exited with status \(code) · See terminal"
        }
        if outputTail.count > 16000 { outputTail = String(outputTail.suffix(8000)) }
    }
    private func updateEditorViewport() {
        let size = editorScroll.contentSize
        editor.minSize = NSSize(width: max(1, size.width), height: max(1, size.height))
        editor.setFrameSize(NSSize(width: max(editor.frame.width, size.width), height: max(editor.frame.height, size.height)))
        editorScroll.verticalRulerView?.needsDisplay = true
    }
    func windowDidResize(_ notification: Notification) { updateEditorViewport() }
    func splitViewDidResizeSubviews(_ notification: Notification) { updateEditorViewport() }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.isVertical ? 170 : 150 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { (splitView.isVertical ? splitView.bounds.width - 340 : splitView.bounds.height - 120) }
    func saveCurrentFile() { _ = saveFile() }
    private func failure(_ message: String) -> NSError { NSError(domain: "WebbyIDE", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = "Webby IDE"; alert.informativeText = error.localizedDescription; alert.runModal() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? IDEFile ?? root)?.contents().count ?? 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? IDEFile ?? root)!.contents()[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? IDEFile)?.directory == true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? IDEFile else { return nil }
        let cell = NSTableCellView(); let icon = NSImageView(); let label = NSTextField(labelWithString: node.url.lastPathComponent)
        icon.image = node.directory ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) : NSWorkspace.shared.icon(forFile: node.url.path)
        icon.contentTintColor = node.directory ? .systemTeal : nil; label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? { (item as? IDEFile)?.url as NSURL? }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard root != nil, item == nil || (item as? IDEFile)?.directory == true else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return (info.draggingSource as? NSOutlineView) === outline ? .move : .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? IDEFile)?.url ?? root?.url, resolveEdits(), marker == nil else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let moving = (info.draggingSource as? NSOutlineView) === outline
        do {
            for source in urls {
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                guard source.standardizedFileURL != destination.standardizedFileURL else { continue }
                guard !folder.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/"), source.resolvingSymlinksInPath() != folder.resolvingSymlinksInPath() else { throw failure("A folder can’t be moved into itself.") }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("\(destination.lastPathComponent) already exists. Rename it first.") }
                if moving {
                    try FileManager.default.moveItem(at: source, to: destination)
                    if let currentFile, currentFile.path == source.path || currentFile.path.hasPrefix(source.path + "/") {
                        self.currentFile = URL(fileURLWithPath: destination.path + currentFile.path.dropFirst(source.path.count)); updateFilename()
                    }
                } else { try FileManager.default.copyItem(at: source, to: destination) }
            }
            refreshFiles(); return !urls.isEmpty
        } catch { refreshFiles(); showError(error); return false }
    }
}

extension LightweightIDE: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (title, action) in [("New File", #selector(newFile)), ("New Folder", #selector(newFolder)), ("Reveal in Finder", #selector(revealFile)), ("Rename…", #selector(renameFile)), ("Move to Trash", #selector(trashFile)), ("Remove Project from Recents", #selector(forgetProject))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        if outline.clickedRow >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false) }
    }
    @objc private func revealFile() { if let url = (outline.item(atRow: outline.selectedRow) as? IDEFile)?.url ?? root?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func renameFile() {
        guard marker == nil, let node = outline.item(atRow: outline.selectedRow) as? IDEFile, resolveEdits(), let name = promptName("Rename", initial: node.url.lastPathComponent) else { return }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != node.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("That name already exists.") }
            try FileManager.default.moveItem(at: node.url, to: destination)
            if let currentFile, currentFile.path == node.url.path || currentFile.path.hasPrefix(node.url.path + "/") {
                self.currentFile = URL(fileURLWithPath: destination.path + currentFile.path.dropFirst(node.url.path.count)); updateFilename()
                if let file = self.currentFile, file.pathExtension == "java" { entry.stringValue = IDEJava.mainClass(file: file, source: editor.string) }
            }
            refreshFiles()
        } catch { showError(error) }
    }
    @objc private func trashFile() {
        guard marker == nil, let node = outline.item(atRow: outline.selectedRow) as? IDEFile, resolveEdits() else { return }
        let alert = NSAlert(); alert.messageText = "Move \(node.url.lastPathComponent) to Trash?"; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.showError(error); return }
                if let file = self.currentFile, file == node.url || file.path.hasPrefix(node.url.path + "/") {
                    self.currentFile = nil; self.editor.string = ""; self.baseline = ""; self.editor.isEditable = false; self.updateFilename()
                }
                self.refreshFiles()
            }
        }
    }
    @objc private func forgetProject() {
        guard let root else { return }
        projectURLs.removeAll { $0 == root.url }
        do { try JSONEncoder().encode(projectURLs.map(\.path)).write(to: registry, options: .atomic) } catch { showError(error) }
        refreshProjects()
    }
}
