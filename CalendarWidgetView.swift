import AppKit

// A single native drawing surface: no web view, timers or per-day blur layers.
@MainActor final class CalendarWidgetView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var changeMonth: ((Date) -> Void)?
    var openDay: ((Date) -> Void)?
    private var snapshot: CalendarSnapshot?
    private var selected = Calendar.current.startOfDay(for: Date())
    private var showsSelectedDay = false
    private var message = "Loading your calendar…"
    private var days: [(NSRect, Date)] = []
    private var eventRows: [(NSRect, Date)] = []
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let today = NSButton(title: "Today", target: nil, action: nil)
    private let cal = Calendar.current
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [previous, next, today] {
            button.isBordered = false; button.font = .systemFont(ofSize: button === today ? 10 : 21, weight: .medium)
            button.contentTintColor = .white; button.target = self; addSubview(button)
        }
        previous.action = #selector(back); next.action = #selector(forward); today.action = #selector(goToday)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ snapshot: CalendarSnapshot) {
        if self.snapshot != snapshot, Motion.enabled, !isHiddenOrHasHiddenAncestor,
           window?.occlusionState.contains(.visible) == true {
            wantsLayer = true
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            layer?.add(fade,forKey:"calendarRefresh")
        }
        self.snapshot = snapshot
        if !cal.isDate(selected, equalTo: snapshot.month, toGranularity: .month) {
            showsSelectedDay = false
            selected = cal.isDate(Date(), equalTo: snapshot.month, toGranularity: .month) ? cal.startOfDay(for: Date()) : snapshot.month
        }
        message = snapshot.stale ? "Saved events · refreshing when available" : snapshot.limited ? "Some events couldn’t be expanded" : ""
        needsDisplay = true
    }
    func setStatus(_ text: String) { message = text; needsDisplay = true }
    private var month: Date { snapshot?.month ?? Date() }
    @objc private func back() { move(-1) }
    @objc private func forward() { move(1) }
    @objc private func goToday() { showsSelectedDay=false;selected=cal.startOfDay(for:Date());needsDisplay=true;changeMonth?(Date()) }
    private func move(_ amount: Int) {
        guard let date = cal.date(byAdding: .month, value: amount, to: month) else { return }
        showsSelectedDay=false
        changeMonth?(date)
    }
    override func layout() {
        super.layout()
        let compact = bounds.width < 145 || bounds.height < 105
        for button in [previous, next, today] { button.isHidden = compact }
        previous.frame = NSRect(x: bounds.width - 112, y: 5, width: 22, height: 28)
        next.frame = NSRect(x: bounds.width - 87, y: 5, width: 22, height: 28)
        today.frame = NSRect(x: bounds.width - 62, y: 7, width: 50, height: 24)
    }
    private func text(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .white, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = align
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                           .foregroundColor: color, .paragraphStyle: style])
    }
    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = pattern; return formatter.string(from: date)
    }
    private var secondary: NSColor { .white.withAlphaComponent(0.58) }
    private func events(on day: Date) -> [CalendarEvent] {
        let end = cal.date(byAdding: .day, value: 1, to: day)!
        return (snapshot?.events ?? []).filter { $0.start < end && ($0.end > day || $0.start == day) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect); days = []; eventRows = []
        let w = bounds.width, h = bounds.height
        if w < 145 || h < 105 {
            text(format(Date(), "EEE").uppercased(), in: NSRect(x: 4, y: h*0.12, width: w-8, height: 17), size: 11, weight: .semibold, color: .systemOrange, align: .center)
            text(format(Date(), "d"), in: NSRect(x: 4, y: h*0.28, width: w-8, height: h*0.58), size: min(42, h*0.5), weight: .light, align: .center)
            if !events(on: cal.startOfDay(for: Date())).isEmpty {
                NSColor.systemCyan.setFill(); NSBezierPath(ovalIn: NSRect(x: w/2-2, y: h-8, width: 4, height: 4)).fill()
            }
            return
        }
        let grid = w >= 290 && h >= 295
        text(grid ? format(month, "MMMM yyyy") : (showsSelectedDay ? format(selected, "EEE, MMM d") : "Upcoming"), in: NSRect(x: 4, y: 11, width: max(30, w-125), height: 25), size: 15, weight: .semibold)
        var top: CGFloat = 49
        if grid {
            let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
            let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
            let origin = cal.date(byAdding: .day, value: -offset, to: first)!
            let cellWidth = (w-8)/7
            let rowHeight = min(28, (h-160)/7)
            let symbols = cal.veryShortWeekdaySymbols
            for column in 0..<7 {
                let label = symbols[(cal.firstWeekday-1+column)%7]
                text(label, in: NSRect(x: 4+CGFloat(column)*cellWidth, y: top, width: cellWidth, height: 16), size: 9, color: secondary, align: .center)
            }
            top += 19
            for index in 0..<42 {
                let day = cal.date(byAdding: .day, value: index, to: origin)!
                let rect = NSRect(x: 4+CGFloat(index%7)*cellWidth, y: top+CGFloat(index/7)*rowHeight, width: cellWidth, height: rowHeight)
                days.append((rect, day))
                let isSelected = cal.isDate(day, inSameDayAs: selected)
                let isToday = cal.isDateInToday(day)
                let indicatorSide = min(26, rowHeight - 4)
                let indicator = NSRect(x: rect.midX - indicatorSide/2, y: rect.midY - indicatorSide/2 - 1,
                                       width: indicatorSide, height: indicatorSide)
                if isSelected || isToday {
                    (isSelected ? NSColor.systemCyan.withAlphaComponent(0.75) : NSColor.white.withAlphaComponent(0.12)).setFill()
                    NSBezierPath(roundedRect: indicator, xRadius: 7, yRadius: 7).fill()
                }
                let number = String(cal.component(.day, from: day))
                let font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
                let textHeight = (number as NSString).size(withAttributes: [.font: font]).height
                let numberRect = NSRect(x: rect.minX, y: indicator.midY - textHeight/2, width: rect.width, height: textHeight)
                text(number, in: numberRect, size: 11, weight: isSelected ? .semibold : .regular,
                     color: cal.isDate(day, equalTo: month, toGranularity: .month) ? .white : secondary.withAlphaComponent(0.35), align: .center)
                if !events(on: day).isEmpty {
                    NSColor.systemCyan.setFill(); NSBezierPath(ovalIn: NSRect(x: rect.midX-1.5, y: rect.maxY-5, width: 3, height: 3)).fill()
                }
            }
            top += rowHeight*6 + 12
        }
        let heading = showsSelectedDay ? (cal.isDateInToday(selected) ? "Today" : format(selected, "EEE, MMM d")) : "Upcoming"
        if grid {
            text(heading, in: NSRect(x: 5, y: top, width: w-14, height: 20), size: 10, weight: .semibold, color: secondary)
            top += 23
        }
        let now = Date()
        let items = showsSelectedDay ? events(on:selected) : (snapshot?.upcoming ?? []).filter { $0.end > now || ($0.start == $0.end && $0.start >= now) }
        if items.isEmpty {
            text(snapshot == nil ? message : (showsSelectedDay ? "No events on this date." : "No upcoming events in this calendar."), in: NSRect(x: 5, y: top, width: w-16, height: 36), size: 13, color: secondary)
        }
        let rowHeight: CGFloat = 42
        let capacity = max(0, Int((h-top-18)/rowHeight))
        for (index, event) in items.prefix(capacity).enumerated() {
            let y = top+CGFloat(index)*rowHeight
            eventRows.append((NSRect(x:0,y:y,width:w,height:rowHeight),event.start))
            let color: NSColor = event.allDay ? .systemPurple : event.start <= Date() && event.end > Date() ? .systemGreen : .systemCyan
            color.setFill(); NSBezierPath(roundedRect: NSRect(x: 5, y: y+2, width: 3, height: 30), xRadius: 1.5, yRadius: 1.5).fill()
            text(event.title, in: NSRect(x: 16, y: y, width: w-28, height: 18), size: 12, weight: .medium)
            let time = event.allDay ? "All day" : format(event.start, "h:mm a") + " – " + format(event.end, "h:mm a")
            let dateLabel = cal.isDateInToday(event.start) ? "Today" : cal.isDateInTomorrow(event.start) ? "Tomorrow" : format(event.start, cal.isDate(event.start, equalTo: now, toGranularity: .year) ? "EEE, MMM d" : "MMM d, yyyy")
            text((showsSelectedDay ? "" : dateLabel + " · ") + time + (event.location.isEmpty ? "" : " · " + event.location), in: NSRect(x: 16, y: y+19, width: w-28, height: 16), size: 10, color: secondary)
        }
        let footer = !message.isEmpty ? message : items.count > capacity ? "+\(items.count-capacity) more · open Google Calendar ↗" : "Open Google Calendar ↗"
        text(footer, in: NSRect(x: 5, y: h-14, width: w-12, height: 14), size: 9, color: secondary)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (_,date)=eventRows.first(where:{$0.0.contains(point)}) {openDay?(date);return}
        if let (_, date) = days.first(where: { $0.0.contains(point) }) {
            if cal.isDate(date, equalTo: month, toGranularity: .month) { selected = date; showsSelectedDay=true; needsDisplay = true }
            else { changeMonth?(date) }
        } else { openDay?(selected) }
    }
}
