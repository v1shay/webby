#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$root/../work/desktop-widget-checks"
mkdir -p "$work/Checks.app/Contents/MacOS" "$work/Checks.app/Contents/Resources"
cp "$root/WidgetBrands/"* "$root/Fonts/Geist/"*.ttf "$root/CodexWhiteIcon.png" "$work/Checks.app/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Checks" "$work/Checks.app/Contents/Info.plist" 2>/dev/null || true
python3 "$root/DesktopWidgets/generate-providers.py" "$work/providers"
sed -e 's/@main struct WebbyWidgets/struct WebbyWidgets/' -e 's/@Environment(\\.widgetFamily) private var family/var family:WidgetFamily = .systemSmall/' "$root/DesktopWidgets/Widgets.swift" > "$work/Widgets.swift"
swiftc -O -parse-as-library -D WEBBY_WIDGET_TESTS -target arm64-apple-macos14.0 \
  -module-cache-path "$work/modules" -framework SwiftUI -framework WidgetKit -framework AppIntents \
  -framework AppKit -framework Security -framework JavaScriptCore -framework CryptoKit -framework IOKit \
  "$root/DesktopWidgets/Shared.swift" "$work/Widgets.swift" "$root/DesktopWidgets/Checks.swift" \
  "$work/providers/Feeds.swift" "$work/providers/Calendar.swift" "$work/providers/GitHub.swift" "$work/providers/System.swift" \
  -o "$work/Checks.app/Contents/MacOS/Checks"
WEBBY_WIDGET_TEST_ROOT="$work/fixtures" "$work/Checks.app/Contents/MacOS/Checks"
