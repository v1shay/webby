import AppKit
import Darwin

@_silgen_name("WBSpawnShell")
private func WBSpawnShell(_ master: UnsafeMutablePointer<Int32>, _ columns: Int32, _ rows: Int32) -> Int32

final class PTYSession {
    private var master: Int32 = -1
    private var childPID: Int32 = 0
    private var source: DispatchSourceRead?
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?
    private(set) var running = false

    func start(columns: Int, rows: Int) throws {
        guard !running else { return }
        let pid = WBSpawnShell(&master, Int32(columns), Int32(rows))
        guard pid > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        childPID = pid
        running = true
        let descriptor = master
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        reader.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { return }
            let chunk = Data(bytes.prefix(count))
            DispatchQueue.main.async {
                guard let self, self.childPID == pid else { return }
                self.onData?(chunk)
            }
        }
        reader.resume()
        source = reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                guard let self, self.childPID == pid else { return }
                self.running = false
                self.source?.cancel(); self.source = nil
                if self.master >= 0 { Darwin.close(self.master); self.master = -1 }
                self.childPID = 0
                self.onExit?()
            }
        }
    }

    func send(_ data: Data) {
        guard master >= 0, running else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(master, base.advanced(by: offset), raw.count - offset)
                if count <= 0 { break }
                offset += count
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func stop() {
        source?.cancel(); source = nil
        if childPID > 0 { _ = Darwin.kill(childPID, SIGHUP); childPID = 0 }
        if master >= 0 { Darwin.close(master); master = -1 }
        running = false
    }
}

private struct TerminalCell {
    var character = " "
    var foreground: NSColor = .labelColor
    var background: NSColor?
}

private final class TerminalGrid {
    private enum ParseState { case text, escape, csi, osc, oscEscape }
    private var state: ParseState = .text
    private var sequence = ""
    private var rows: [[TerminalCell]] = []
    private var history: [[TerminalCell]] = []
    private var savedNormal: ([[TerminalCell]], [[TerminalCell]], Int, Int)?
    private var alternate = false
    private var foreground: NSColor = .labelColor
    private var background: NSColor?
    private var reverseVideo = false
    private var scrollTop = 0
    private var scrollBottom = 0
    private var savedX = 0
    private var savedY = 0
    private(set) var columns = 80
    private(set) var lineCount = 24
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    private(set) var applicationCursor = false
    private(set) var bracketedPaste = false
    var onResponse: ((Data) -> Void)?
    var historyCount: Int { history.count }
    var isAlternate: Bool { alternate }

    init() { resize(columns: 80, rows: 24) }

    private func blankRow() -> [TerminalCell] { Array(repeating: TerminalCell(), count: columns) }

    func resize(columns newColumns: Int, rows newRows: Int) {
        let width = max(20, newColumns), height = max(4, newRows)
        guard width != columns || height != lineCount || rows.isEmpty else { return }
        let old = rows
        columns = width; lineCount = height
        rows = Array(repeating: blankRow(), count: height)
        for index in 0..<min(old.count, height) {
            let source = old[max(0, old.count - height) + index]
            for col in 0..<min(source.count, width) { rows[index][col] = source[col] }
        }
        cursorX = min(cursorX, width - 1)
        cursorY = min(cursorY, height - 1)
        scrollTop = 0; scrollBottom = height - 1
    }

    func visibleRows(scrolledBy offset: Int) -> [[TerminalCell]] {
        if alternate || offset == 0 { return rows }
        let combined = history + rows
        let end = max(lineCount, combined.count - min(offset, history.count))
        return Array(combined[(end - lineCount)..<end])
    }

    func feed(_ data: Data) {
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars { consume(scalar) }
    }

    private func consume(_ scalar: Unicode.Scalar) {
        switch state {
        case .text:
            switch scalar.value {
            case 0x1B: state = .escape
            case 0x0D: cursorX = 0
            case 0x0A: lineFeed()
            case 0x08: cursorX = max(0, cursorX - 1)
            case 0x09: cursorX = min(columns - 1, ((cursorX / 8) + 1) * 8)
            case 0x07, 0x00: break
            default: if scalar.value >= 0x20 { put(String(scalar)) }
            }
        case .escape:
            state = .text
            switch scalar.value {
            case 0x5B: sequence = ""; state = .csi
            case 0x5D: sequence = ""; state = .osc
            case 0x37: savedX = cursorX; savedY = cursorY
            case 0x38: cursorX = savedX; cursorY = savedY
            case 0x44: lineFeed()
            case 0x45: cursorX = 0; lineFeed()
            case 0x4D: reverseLineFeed()
            case 0x63: reset()
            default: break
            }
        case .csi:
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                executeCSI(Character(scalar)); state = .text; sequence = ""
            } else if sequence.count < 80 { sequence.unicodeScalars.append(scalar) }
            else { state = .text; sequence = "" }
        case .osc:
            if scalar.value == 0x07 { state = .text }
            else if scalar.value == 0x1B { state = .oscEscape }
        case .oscEscape:
            state = scalar.value == 0x5C ? .text : .osc
        }
    }

    private func put(_ string: String) {
        if cursorX >= columns { cursorX = 0; lineFeed() }
        guard rows.indices.contains(cursorY), rows[cursorY].indices.contains(cursorX) else { return }
        rows[cursorY][cursorX] = reverseVideo
            ? TerminalCell(character: string, foreground: background ?? .textBackgroundColor, background: foreground)
            : TerminalCell(character: string, foreground: foreground, background: background)
        cursorX += 1
    }

    private func lineFeed() {
        if cursorY == scrollBottom { scrollUp(from: scrollTop, through: scrollBottom) }
        else { cursorY = min(lineCount - 1, cursorY + 1) }
    }

    private func reverseLineFeed() {
        if cursorY == scrollTop {
            rows.insert(blankRow(), at: scrollTop)
            rows.remove(at: scrollBottom + 1)
        } else { cursorY = max(0, cursorY - 1) }
    }

    private func scrollUp(from top: Int, through bottom: Int) {
        guard top >= 0, bottom < rows.count, top <= bottom else { return }
        let removed = rows.remove(at: top)
        rows.insert(blankRow(), at: bottom)
        if !alternate && top == 0 && bottom == lineCount - 1 {
            history.append(removed)
            if history.count > 1500 { history.removeFirst(history.count - 1500) }
        }
    }

    private func reset() {
        rows = Array(repeating: blankRow(), count: lineCount)
        cursorX = 0; cursorY = 0; foreground = .labelColor; background = nil; reverseVideo = false
        scrollTop = 0; scrollBottom = lineCount - 1
    }

    func clearAll() {
        alternate = false
        savedNormal = nil
        state = .text
        cursorVisible = true
        applicationCursor = false
        bracketedPaste = false
        history.removeAll()
        reset()
    }

    private func executeCSI(_ command: Character) {
        let privateMode = sequence.hasPrefix("?")
        let raw = privateMode ? String(sequence.dropFirst()) : sequence
        let parameters = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < parameters.count, parameters[index] != 0 else { return fallback }
            return parameters[index]
        }
        if privateMode {
            let mode = parameters.first ?? 0
            if (command == "h" || command == "l") && [47, 1047, 1049].contains(mode) { setAlternate(command == "h") }
            if (command == "h" || command == "l") && mode == 25 { cursorVisible = command == "h" }
            if (command == "h" || command == "l") && mode == 1 { applicationCursor = command == "h" }
            if (command == "h" || command == "l") && mode == 2004 { bracketedPaste = command == "h" }
            return
        }
        switch command {
        case "A": cursorY = max(0, cursorY - value(0))
        case "B": cursorY = min(lineCount - 1, cursorY + value(0))
        case "C": cursorX = min(columns - 1, cursorX + value(0))
        case "D": cursorX = max(0, cursorX - value(0))
        case "E": cursorY = min(lineCount - 1, cursorY + value(0)); cursorX = 0
        case "F": cursorY = max(0, cursorY - value(0)); cursorX = 0
        case "G": cursorX = min(columns - 1, value(0) - 1)
        case "d": cursorY = min(lineCount - 1, value(0) - 1)
        case "H", "f": cursorY = min(lineCount - 1, value(0) - 1); cursorX = min(columns - 1, value(1) - 1)
        case "J":
            let mode = parameters.first ?? 0
            if mode == 2 || mode == 3 { rows = Array(repeating: blankRow(), count: lineCount); if mode == 3 { history.removeAll() } }
            else if mode == 0 {
                clearLine(from: cursorX, through: columns - 1, row: cursorY)
                if cursorY + 1 < lineCount { for row in (cursorY + 1)..<lineCount { rows[row] = blankRow() } }
            } else if mode == 1 {
                clearLine(from: 0, through: cursorX, row: cursorY)
                if cursorY > 0 { for row in 0..<cursorY { rows[row] = blankRow() } }
            }
        case "K":
            let mode = parameters.first ?? 0
            if mode == 2 { rows[cursorY] = blankRow() }
            else if mode == 1 { clearLine(from: 0, through: cursorX, row: cursorY) }
            else { clearLine(from: cursorX, through: columns - 1, row: cursorY) }
        case "m": applyStyle(parameters)
        case "@":
            let start = min(cursorX, columns - 1)
            let count = min(value(0), columns - start)
            if count > 0 {
                for column in stride(from: columns - 1, through: start + count, by: -1) {
                    rows[cursorY][column] = rows[cursorY][column - count]
                }
                clearLine(from: start, through: start + count - 1, row: cursorY)
            }
        case "P":
            let start = min(cursorX, columns - 1)
            let count = min(value(0), columns - start)
            if count > 0 {
                if start < columns - count {
                    for column in start..<(columns - count) { rows[cursorY][column] = rows[cursorY][column + count] }
                }
                clearLine(from: columns - count, through: columns - 1, row: cursorY)
            }
        case "X": clearLine(from: cursorX, through: min(columns - 1, cursorX + value(0) - 1), row: cursorY)
        case "r":
            scrollTop = min(lineCount - 1, value(0) - 1)
            scrollBottom = min(lineCount - 1, value(1, default: lineCount) - 1)
            if scrollBottom < scrollTop { scrollTop = 0; scrollBottom = lineCount - 1 }
            cursorX = 0; cursorY = 0
        case "s": savedX = cursorX; savedY = cursorY
        case "u": cursorX = savedX; cursorY = savedY
        case "n":
            if parameters.first == 6 { onResponse?(Data("\u{001B}[\(cursorY + 1);\(cursorX + 1)R".utf8)) }
        case "L":
            for _ in 0..<min(value(0), lineCount) { rows.insert(blankRow(), at: cursorY); rows.remove(at: scrollBottom + 1) }
        case "M":
            for _ in 0..<min(value(0), lineCount) { rows.remove(at: cursorY); rows.insert(blankRow(), at: scrollBottom) }
        case "S": for _ in 0..<min(value(0), lineCount) { scrollUp(from: scrollTop, through: scrollBottom) }
        case "T":
            for _ in 0..<min(value(0), lineCount) {
                rows.insert(blankRow(), at: scrollTop)
                rows.remove(at: scrollBottom + 1)
            }
        default: break
        }
    }

    private func clearLine(from start: Int, through end: Int, row: Int) {
        guard rows.indices.contains(row), start <= end else { return }
        for column in max(0, start)...min(columns - 1, end) { rows[row][column] = TerminalCell() }
    }

    private func setAlternate(_ enabled: Bool) {
        guard enabled != alternate else { return }
        if enabled {
            savedNormal = (rows, history, cursorX, cursorY)
            alternate = true; reset()
        } else {
            alternate = false
            if let savedNormal { rows = savedNormal.0; history = savedNormal.1; cursorX = savedNormal.2; cursorY = savedNormal.3 }
            savedNormal = nil
        }
    }

    private func applyStyle(_ codes: [Int]) {
        let values = codes.isEmpty ? [0] : codes
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: foreground = .labelColor; background = nil; reverseVideo = false
            case 1: foreground = foreground.withAlphaComponent(1)
            case 7: reverseVideo = true
            case 27: reverseVideo = false
            case 30...37: foreground = palette(code - 30)
            case 40...47: background = palette(code - 40)
            case 90...97: foreground = palette(code - 90 + 8)
            case 100...107: background = palette(code - 100 + 8)
            case 39: foreground = .labelColor
            case 49: background = nil
            case 38, 48:
                if index + 2 < values.count && values[index + 1] == 5 {
                    let color = palette(values[index + 2])
                    if code == 38 { foreground = color } else { background = color }
                    index += 2
                } else if index + 4 < values.count && values[index + 1] == 2 {
                    let color = NSColor(calibratedRed: CGFloat(values[index + 2]) / 255,
                                        green: CGFloat(values[index + 3]) / 255,
                                        blue: CGFloat(values[index + 4]) / 255, alpha: 1)
                    if code == 38 { foreground = color } else { background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private func palette(_ index: Int) -> NSColor {
        let standard: [NSColor] = [.black, .systemRed, .systemGreen, .systemYellow,
                                   .systemBlue, .systemPurple, .systemCyan, .white,
                                   .darkGray, .systemRed, .systemGreen, .systemYellow,
                                   .systemBlue, .systemPink, .systemTeal, .white]
        if index < 16 { return standard[max(0, index)] }
        if index < 232 {
            let n = index - 16
            func component(_ value: Int) -> CGFloat { value == 0 ? 0 : CGFloat(55 + 40 * value) / 255 }
            return NSColor(calibratedRed: component(n / 36), green: component((n / 6) % 6),
                           blue: component(n % 6), alpha: 1)
        }
        let shade = CGFloat(8 + 10 * min(23, index - 232)) / 255
        return NSColor(calibratedWhite: shade, alpha: 1)
    }

}

private final class TerminalScreenView: NSView {
    private var cursorColors: [NSColor] = [.systemTeal, .white, .systemBlue]
    private let grid = TerminalGrid()
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let inset: CGFloat = 17
    private var scrollOffset = 0
    private var columnWidth: CGFloat = 9
    private var rowHeight: CGFloat = 19
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        columnWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        rowHeight = ceil(font.ascender - font.descender + font.leading + 2)
        grid.onResponse = { [weak self] in self?.onInput?($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let columns = max(20, Int((bounds.width - inset * 2) / columnWidth))
        let rows = max(4, Int((bounds.height - inset * 2) / rowHeight))
        if columns != grid.columns || rows != grid.lineCount {
            grid.resize(columns: columns, rows: rows)
            onResize?(columns, rows)
            needsDisplay = true
        }
    }

    func receive(_ data: Data) {
        grid.feed(data)
        if scrollOffset == 0 && !isHiddenOrHasHiddenAncestor { needsDisplay = true }
    }
    func applyTheme(_ profile: PetGradientProfile) {
        cursorColors = profile.gradients.working.stops.map { BrowserTheme.color($0.color, alpha: 0.72) }
        needsDisplay = true
    }
    func clear() { grid.clearAll(); scrollOffset = 0; needsDisplay = true }
    func dimensions() -> (Int, Int) { (grid.columns, grid.lineCount) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rows = grid.visibleRows(scrolledBy: scrollOffset)
        for (rowIndex, cells) in rows.enumerated() {
            let y = inset + CGFloat(rowIndex) * rowHeight
            if y > bounds.height { break }
            let line = NSMutableAttributedString(string: cells.map(\.character).joined(),
                                                 attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            var textOffset = 0
            for (column, cell) in cells.enumerated() {
                if let bg = cell.background {
                    bg.setFill()
                    NSRect(x: inset + CGFloat(column) * columnWidth, y: y,
                           width: columnWidth, height: rowHeight).fill()
                }
                if !cell.foreground.isEqual(NSColor.labelColor) {
                    line.addAttribute(.foregroundColor, value: cell.foreground,
                                      range: NSRange(location: textOffset, length: (cell.character as NSString).length))
                }
                textOffset += (cell.character as NSString).length
            }
            line.draw(at: NSPoint(x: inset, y: y))
        }
        if grid.cursorVisible && scrollOffset == 0 {
            let cursorRect = NSRect(x: inset + CGFloat(min(grid.cursorX, grid.columns - 1)) * columnWidth,
                                    y: inset + CGFloat(grid.cursorY) * rowHeight,
                                    width: max(2, columnWidth * 0.16), height: rowHeight - 2)
            NSGradient(colors: cursorColors)?.draw(in: cursorRect, angle: 90)
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func scrollWheel(with event: NSEvent) {
        guard !grid.isAlternate else { return }
        scrollOffset = max(0, min(grid.historyCount, scrollOffset + Int(event.scrollingDeltaY.rounded())))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        let key: String
        switch event.keyCode {
        case 36, 76: key = "\r"
        case 51: key = "\u{7F}"
        case 48: key = "\t"
        case 53: key = "\u{1B}"
        case 126: key = grid.applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        case 125: key = grid.applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
        case 124: key = grid.applicationCursor ? "\u{1B}OC" : "\u{1B}[C"
        case 123: key = grid.applicationCursor ? "\u{1B}OD" : "\u{1B}[D"
        case 115: key = "\u{1B}[H"
        case 119: key = "\u{1B}[F"
        case 116: key = "\u{1B}[5~"
        case 121: key = "\u{1B}[6~"
        case 117: key = "\u{1B}[3~"
        default:
            if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
               scalar.value >= 0x40 && scalar.value <= 0x7F {
                onInput?(Data([UInt8(scalar.value & 0x1F)]))
                return
            }
            key = event.characters ?? ""
        }
        if !key.isEmpty { onInput?(Data(key.utf8)); scrollOffset = 0; needsDisplay = true }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v",
           let text = NSPasteboard.general.string(forType: .string) {
            let payload = grid.bracketedPaste ? "\u{001B}[200~" + text + "\u{001B}[201~" : text
            onInput?(Data(payload.utf8))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class NativeTerminalPane: NSVisualEffectView {
    private let session = PTYSession()
    private let screen = TerminalScreenView(frame: .zero)
    private let gradientTint = CAGradientLayer()
    private let closeButton: GlassButton
    var onClose: (() -> Void)?

    init(target: AnyObject, action: Selector) {
        closeButton = GlassButton(symbol: "globe", label: "Back to Search", target: target, action: action)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(gradientTint)
        screen.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(screen)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor),
            screen.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        screen.onInput = { [weak self] in self?.session.send($0) }
        screen.onResize = { [weak self] columns, rows in self?.session.resize(columns: columns, rows: rows) }
        session.onData = { [weak self] in self?.screen.receive($0) }
        session.onExit = { [weak self] in self?.screen.receive(Data("\r\n[Shell exited]\r\n".utf8)) }
        applyTheme(BrowserTheme.profile)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        gradientTint.frame = bounds
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: gradientTint, alpha: 0.09)
        screen.applyTheme(profile)
    }

    func open() {
        layoutSubtreeIfNeeded()
        screen.needsDisplay = true
        let (columns, rows) = screen.dimensions()
        if !session.running {
            do { try session.start(columns: columns, rows: rows) }
            catch { screen.receive(Data("Could not start terminal: \(error.localizedDescription)\r\n".utf8)) }
        }
        window?.makeFirstResponder(screen)
    }

    func focus() { window?.makeFirstResponder(screen) }
    func sendCommand(_ command: String) {
        guard session.running else { return }
        session.send(Data((command + "\r").utf8))
    }
    func stop() { session.stop(); screen.clear() }
}
