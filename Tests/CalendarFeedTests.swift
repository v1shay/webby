import Foundation

@main struct CalendarFeedTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let iso = ISO8601DateFormatter()
        func date(_ text: String) -> Date { iso.date(from: text)! }
        let fixture = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTIMEZONE
        TZID:America/New_York
        BEGIN:DAYLIGHT
        DTSTART:19700308T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
        TZOFFSETFROM:-0500
        TZOFFSETTO:-0400
        END:DAYLIGHT
        BEGIN:STANDARD
        DTSTART:19701101T020000
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:weekly
        DTSTART;TZID=America/New_York:20261025T090000
        DTEND;TZID=America/New_York:20261025T100000
        RRULE:FREQ=WEEKLY;COUNT=4
        EXDATE;TZID=America/New_York:20261101T090000
        SUMMARY:Weekly\\, planning
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        RECURRENCE-ID;TZID=America/New_York:20261108T090000
        DTSTART;TZID=America/New_York:20261109T090000
        DTEND;TZID=America/New_York:20261109T100000
        SUMMARY:Moved meeting
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        RECURRENCE-ID;TZID=America/New_York:20261115T090000
        DTSTART;TZID=America/New_York:20261115T090000
        DTEND;TZID=America/New_York:20261115T100000
        STATUS:CANCELLED
        SUMMARY:Cancelled occurrence
        END:VEVENT
        BEGIN:VEVENT
        UID:all-day
        DTSTART;VALUE=DATE:20261103
        DTEND;VALUE=DATE:20261105
        SUMMARY:A folded long
         Unicode café
        END:VEVENT
        BEGIN:VEVENT
        UID:cancelled
        DTSTART:20261103T100000Z
        DTEND:20261103T110000Z
        STATUS:CANCELLED
        SUMMARY:Must not appear
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "Weekly,", with: "Weekly\\,")
        let result = try CalendarFeed.parse(fixture, from: date("2026-10-20T00:00:00Z"), to: date("2026-11-20T00:00:00Z"), resources: resources)
        precondition(!result.limited && result.events.count == 3)
        let weekly = result.events.first { $0.title.hasPrefix("Weekly") }!
        let moved = result.events.first { $0.title == "Moved meeting" }!
        precondition(weekly.start == date("2026-10-25T13:00:00Z"))
        precondition(moved.start == date("2026-11-09T14:00:00Z"))
        precondition(result.events.filter(\.allDay).count == 1)
        precondition(result.events.contains { $0.title.contains("Unicode café") })
        let rules = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:monthly
        DTSTART:20260925T120000Z
        DTEND:20260925T130000Z
        RRULE:FREQ=MONTHLY;COUNT=3;BYDAY=-1FR
        SUMMARY:Last Friday
        END:VEVENT
        BEGIN:VEVENT
        UID:extra-dates
        DTSTART:20261001T100000Z
        DTEND:20261001T110000Z
        RDATE:20261004T100000Z,20261005T100000Z
        EXDATE:20261004T100000Z
        SUMMARY:Extra dates
        END:VEVENT
        END:VCALENDAR
        """
        let additional = try CalendarFeed.parse(rules, from: date("2026-10-01T00:00:00Z"), to: date("2026-12-01T00:00:00Z"), resources: resources)
        precondition(additional.events.count == 4 && !additional.limited)
        precondition(additional.events.contains { $0.start == date("2026-11-27T12:00:00Z") })
        let distant = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:far-single
        DTSTART:20441017T100000Z
        DTEND:20441017T110000Z
        SUMMARY:In eighteen years
        END:VEVENT
        BEGIN:VEVENT
        UID:far-rule
        DTSTART:20441018T100000Z
        DTEND:20441018T110000Z
        RRULE:FREQ=YEARLY;COUNT=3
        EXDATE:20441018T100000Z
        SUMMARY:Far recurring
        END:VEVENT
        BEGIN:VEVENT
        UID:past
        DTSTART:20261001T100000Z
        DTEND:20261001T110000Z
        SUMMARY:Already finished
        END:VEVENT
        BEGIN:VEVENT
        UID:cancelled-future
        DTSTART:20441016T100000Z
        DTEND:20441016T110000Z
        STATUS:CANCELLED
        SUMMARY:Cancelled future
        END:VEVENT
        END:VCALENDAR
        """
        let far = try CalendarFeed.parse(distant,from:date("2026-10-01T00:00:00Z"),to:date("2026-11-15T00:00:00Z"),upcomingFrom:date("2026-10-17T00:00:00Z"),resources:resources)
        precondition(far.upcoming.count == 3 && !far.limited)
        precondition(far.upcoming.first?.title == "In eighteen years")
        precondition(far.upcoming.last?.start == date("2046-10-18T10:00:00Z"))
        precondition(!far.upcoming.contains{$0.title.contains("Cancelled") || $0.title.contains("finished")})
        let near = try CalendarFeed.parse(fixture,from:date("2026-10-20T00:00:00Z"),to:date("2026-11-20T00:00:00Z"),upcomingFrom:date("2026-11-03T12:00:00Z"),resources:resources)
        precondition(near.upcoming.contains{$0.allDay})
        precondition(near.upcoming.contains{$0.title=="Moved meeting"})
        print("PASS: upcoming agenda finds events 18–20 years away, exclusions/cancellations, moved overrides and ongoing all-day events")
        do { try CalendarSubscription.save("https://example.com/calendar.ics", profile: UUID()); preconditionFailure("Non-Google feed accepted") }
        catch CalendarFeedError.invalid { }
        let empty = try CalendarFeed.parse("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR", from: Date(), to: Date(), resources: resources)
        precondition(empty.events.isEmpty)
        do { _ = try CalendarFeed.parse("not a calendar", from: Date(), to: Date(), resources: resources); preconditionFailure("Malformed input accepted") }
        catch { }
        print("PASS: recurrence, COUNT, exclusions, moved overrides, DST, all-day, folded Unicode, cancellations, empty and malformed calendars")
        if CommandLine.arguments.count > 2 {
            let source = try String(contentsOfFile: CommandLine.arguments[2])
            let start = Date()
            let real = try CalendarFeed.parse(source, from: date("2026-10-01T00:00:00Z"), to: date("2026-11-15T00:00:00Z"), resources: resources)
            print("Private feed parsed: \(real.events.count) occurrences, limited=\(real.limited), \(Int(Date().timeIntervalSince(start)*1000)) ms. No event details logged.")
        }
    }
}
