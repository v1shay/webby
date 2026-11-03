"""Reuse existing parsers/providers, never touch the browser's source or stores."""
from pathlib import Path
import sys
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
(out/'Feeds.swift').write_text((root/'WidgetFeeds.swift').read_text().split('// One small record')[0])
calendar=(root/'CalendarFeed.swift').read_text().replace('local.plainwebkit.calendar-feed','local.webby.desktop.calendar-feed')
# A widget refresh must never open an authorization dialog.
calendar=calendar.replace('q[kSecReturnData as String] = true','q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail\n        q[kSecReturnData as String] = true')
(out/'Calendar.swift').write_text(calendar)
github=(root/'GitHubWidgets.swift').read_text().split('extension Notification.Name')[0]
github=github.replace('local.plainwebkit.github-widgets','local.webby.desktop.github-widgets')
github=github.replace('q[kSecReturnData as String] = true','q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail\n        q[kSecReturnData as String] = true')
github=github.replace('.appendingPathComponent("Webby/GitHub Widgets", isDirectory: true)','.appendingPathComponent("Webby/GitHub Widgets", isDirectory: true)')
(out/'GitHub.swift').write_text(github)
# Native data only: do not include AppleScript automation, terminal or UI code.
extras=(root/'WidgetExtras.swift').read_text()
start=extras.index('struct BatterySnapshot')
end=extras.index('struct ExpressionCalculator')
(out/'System.swift').write_text('import AppKit\nimport IOKit.ps\nimport Darwin\n'+extras[start:end])
