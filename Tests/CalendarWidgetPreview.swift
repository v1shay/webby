import AppKit

@main struct CalendarWidgetPreview {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let cal = Calendar.current, now = Date()
        let start = cal.startOfDay(for: now)
        let events = [CalendarEvent(id: "demo1", title: "Design review", location: "Studio", start: start.addingTimeInterval(36000), end: start.addingTimeInterval(39600), allDay: false),
                      CalendarEvent(id: "demo2", title: "A little time to build", location: "", start: start.addingTimeInterval(50400), end: start.addingTimeInterval(54000), allDay: false)]
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        for (name, size) in [("small", NSSize(width: 100,height: 100)), ("medium", NSSize(width: 320,height: 208)), ("large", NSSize(width: 350,height: 370))] {
            let window = NSWindow(contentRect: NSRect(origin: .zero,size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let glass = NSVisualEffectView(frame: NSRect(origin: .zero,size: size))
            glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
            glass.wantsLayer = true; glass.layer?.cornerRadius = 18; glass.layer?.masksToBounds = true
            glass.layer?.backgroundColor = NSColor(srgbRed: 0.20, green: 0.24, blue: 0.30, alpha: 0.7).cgColor
            glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor; glass.layer?.borderWidth = 1
            window.contentView = glass
            let view = CalendarWidgetView(frame: NSRect(x:12,y:20,width:size.width-42,height:size.height-44))
            glass.addSubview(view)
            view.set(CalendarSnapshot(month: month, events: events, updated: now, stale: false, limited: false))
            glass.layoutSubtreeIfNeeded(); glass.display()
            let bitmap = glass.bitmapImageRepForCachingDisplay(in: glass.bounds)!
            glass.cacheDisplay(in: glass.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("calendar-\(name).png"))
            window.orderOut(nil)
        }
        print("Rendered three calendar widget sizes using sample events.")
    }
}
