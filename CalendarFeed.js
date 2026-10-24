// ICAL.js stays local to JavaScriptCore. Calendar data never enters a webpage.
function webbyCalendarParse(source, from, to, upcomingFrom = from) {
  const root = new ICAL.Component(ICAL.parse(source));
  if (root.name !== 'vcalendar') throw new Error('Invalid calendar');
  ICAL.TimezoneService.reset();
  for (const zone of root.getAllSubcomponents('vtimezone')) {
    ICAL.TimezoneService.register(new ICAL.Timezone(zone));
  }
  const components = root.getAllSubcomponents('vevent');
  const masters = new Map(), exceptions = [], events = [];
  let limited = false, steps = 0;
  const upcoming = new Map();
  let seriesUpcoming = new Set();
  const deadline = Date.now() + 4000;
  for (const component of components) {
    if (component.hasProperty('recurrence-id')) exceptions.push(component);
    else masters.set(component.getFirstPropertyValue('uid'), new ICAL.Event(component));
  }
  for (const component of exceptions) {
    const master = masters.get(component.getFirstPropertyValue('uid'));
    if (master) master.relateException(component);
    else masters.set(component.getFirstPropertyValue('uid') + String(component.getFirstPropertyValue('recurrence-id')), new ICAL.Event(component));
  }
  function add(event, start, end) {
    if (event.component.getFirstPropertyValue('status') === 'CANCELLED') return;
    const a = start.toJSDate().getTime(), b = end.toJSDate().getTime();
    const inMonth = a < to && (b > from || (a === b && a >= from));
    const inUpcoming = b > upcomingFrom || (a === b && a >= upcomingFrom);
    if (!inMonth && !inUpcoming) return;
    const item = { id: event.uid + ':' + a, title: event.summary || 'Untitled event',
      location: event.location || '', start: a / 1000, end: b / 1000, allDay: start.isDate };
    if (inMonth) events.push(item);
    // No calendar-date horizon: a single event decades away is still upcoming.
    if (inUpcoming) {
      seriesUpcoming.add(item.id);
      upcoming.set(item.id, item);
      if (upcoming.size > 20) {
        const last = [...upcoming.values()].sort((x, y) => y.start - x.start || x.id.localeCompare(y.id))[0];
        upcoming.delete(last.id);
      }
    }
  }
  for (const event of masters.values()) {
    if (Date.now() > deadline || events.length >= 4096) { limited = true; break; }
    if (event.component.getFirstPropertyValue('status') === 'CANCELLED' || !event.startDate) continue;
    seriesUpcoming = new Set();
    if (!event.isRecurring()) { add(event, event.startDate, event.endDate); continue; }
    // DTSTART belongs to the recurrence set even for an RDATE-only event.
    const excludedStart = event.component.getAllProperties('exdate').some(property =>
      property.getValues().some(value => value.compare(event.startDate) === 0));
    if (!excludedStart) {
      const first = event.getOccurrenceDetails(event.startDate);
      add(first.item, first.startDate, first.endDate);
    }
    const iterator = event.iterator();
    let occurrence;
    while ((occurrence = iterator.next())) {
      if (++steps > 100000 || Date.now() > deadline || events.length >= 4096) { limited = true; break; }
      // Resolve moved exceptions even when their original start lies outside the view.
      const details = event.getOccurrenceDetails(occurrence);
      add(details.item, details.startDate, details.endDate);
      // Bound infinite recurrence by number of useful results, not years ahead.
      if (occurrence.toJSDate().getTime() >= to && seriesUpcoming.size >= 20) break;
    }
  }
  // Include exceptions moved into this month from a later original occurrence.
  for (const component of exceptions) {
    const master = masters.get(component.getFirstPropertyValue('uid'));
    if (master?.component.getFirstPropertyValue('status') === 'CANCELLED') continue;
    const event = new ICAL.Event(component);
    if (event.startDate) add(event, event.startDate, event.endDate);
  }
  const unique = Array.from(new Map(events.map(e => [e.id, e])).values());
  unique.sort((a, b) => a.start - b.start || Number(b.allDay) - Number(a.allDay));
  return JSON.stringify({ events: unique, upcoming: [...upcoming.values()].sort((a,b) => a.start-b.start || Number(b.allDay)-Number(a.allDay)), limited });
}
