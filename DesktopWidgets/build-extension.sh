#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$1"
work="$root/../work/desktop-widget-build"
ext="$app/Contents/PlugIns/WebbyWidgets.appex"
mkdir -p "$work" "$ext/Contents/MacOS" "$ext/Contents/Resources"
python3 "$root/DesktopWidgets/generate-providers.py" "$work/providers"
printf '["AppIntent","WidgetConfigurationIntent","AppEntity","EntityQuery","AppEnum"]\n' > "$work/protocols.json"
swiftc -O -whole-module-optimization -emit-const-values-path "$work/WebbyWidgets.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$work/protocols.json" -parse-as-library -application-extension -module-name WebbyWidgets \
  -target arm64-apple-macos14.0 -module-cache-path "$work/module-cache" \
  -framework SwiftUI -framework WidgetKit -framework AppIntents -framework AppKit \
  -framework Security -framework JavaScriptCore -framework CryptoKit -framework IOKit \
  "$root/DesktopWidgets/Shared.swift" "$root/DesktopWidgets/Widgets.swift" \
  "$work/providers/Feeds.swift" "$work/providers/Calendar.swift" "$work/providers/GitHub.swift" "$work/providers/System.swift" \
  -o "$ext/Contents/MacOS/WebbyWidgets"
cp "$root/WidgetBrands/"* "$ext/Contents/Resources/"
cp "$root/Fonts/Geist/"*.ttf "$ext/Contents/Resources/"
cp "$root/Fonts/Geist/OFL.txt" "$ext/Contents/Resources/"
cp "$root/CodexWhiteIcon.png" "$root/CalendarFeed.js" "$root/Vendor/ical.js/ical.es5.min.cjs" "$ext/Contents/Resources/"
python3 - "$ext" "$work/entitlements.plist" <<'PY'
import plistlib,sys
from pathlib import Path
ext=Path(sys.argv[1])
plistlib.dump({'CFBundleIdentifier':'local.plainwebkit.browser.desktopwidgets','CFBundleName':'Webby','CFBundleDisplayName':'Webby','CFBundleExecutable':'WebbyWidgets','CFBundlePackageType':'XPC!','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSMinimumSystemVersion':'14.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}},(ext/'Contents/Info.plist').open('wb'))
# Local signing has no Apple team/App Group. Grant only the non-secret widget
# snapshot directory, rather than access to browser profiles or credential files.
plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.temporary-exception.files.home-relative-path.read-write':['/Library/Application Support/Webby Desktop Widgets/']},open(sys.argv[2],'wb'))
PY
xcrun appintentsmetadataprocessor --output "$ext/Contents/Resources" --module-name WebbyWidgets \
  --target-triple arm64-apple-macos14.0 --binary-file "$ext/Contents/MacOS/WebbyWidgets" \
  --swift-const-vals "$work/WebbyWidgets.swiftconstvalues" --compile-time-extraction \
  --source-files "$root/DesktopWidgets/Widgets.swift" --sdk-root "$(xcrun --show-sdk-path)" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" --platform-family macOS --deployment-target 14.0 --force
test -s "$ext/Contents/Resources/Metadata.appintents/extract.actionsdata"
codesign --force --sign "${WEBBY_SIGN_IDENTITY:-system local code signing}" --entitlements "$work/entitlements.plist" "$ext"
