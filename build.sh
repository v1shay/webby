#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$script_dir/Webby.app"
if [ -d "$script_dir/WebKit Browser.app" ] && [ ! -e "$app" ]; then
  mv "$script_dir/WebKit Browser.app" "$app"
fi
if [ -d "$script_dir/WebKit Browser.app" ] && [ -d "$app" ]; then
  # Two bundles with the same identifier can make the Dock pick the old icon.
  legacy_archive="$script_dir/../work/Legacy WebKit Browser.app-$(date +%Y%m%d%H%M%S).zip"
  mkdir -p "$(dirname "$legacy_archive")"
  ditto -c -k --keepParent "$script_dir/WebKit Browser.app" "$legacy_archive"
  unzip -t "$legacy_archive" >/dev/null
  rm -rf "$script_dir/WebKit Browser.app"
fi
module_cache="${TMPDIR:-/tmp}/plain-webkit-browser-module-cache"
rule_dir="$app/Contents/Resources/ContentRules"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$module_cache"
mkdir -p "$rule_dir"
mkdir -p "$app/Contents/Resources/Pets"
mkdir -p "$app/Contents/Resources/PetsWorking"
cp "$script_dir/gradient_profiles.json" "$app/Contents/Resources/gradient_profiles.json"
cp "$script_dir/VideoControls.js" "$app/Contents/Resources/VideoControls.js"
cp "$script_dir/LinkPreview.js" "$app/Contents/Resources/LinkPreview.js"
cp "$script_dir/glass-page.js" "$app/Contents/Resources/glass-page.js"
cp "$script_dir/SkyBackground.png" "$app/Contents/Resources/SkyBackground.png"
cp "$script_dir/CodexWhiteIcon.svg" "$app/Contents/Resources/CodexWhiteIcon.svg"
cp "$script_dir/CodexWhiteIcon.png" "$app/Contents/Resources/CodexWhiteIcon.png"
cp "$script_dir/Pets/"*.png "$app/Contents/Resources/Pets/"
cp -R "$script_dir/PetsWorking/." "$app/Contents/Resources/PetsWorking/"

swiftc -O -module-cache-path "$module_cache" -framework WebKit \
  "$script_dir/CompileRules.swift" \
  -o "${TMPDIR:-/tmp}/plain-webkit-compile-rules"
"${TMPDIR:-/tmp}/plain-webkit-compile-rules" "$script_dir/FastRules.json" "$rule_dir"

clang -O2 -target arm64-apple-macos13.0 -c "$script_dir/PTYLauncher.c" -o "$module_cache/PTYLauncher.o"

swiftc -O -parse-as-library -target arm64-apple-macos13.0 -module-cache-path "$module_cache" -framework AppKit -framework WebKit -framework AVFoundation -framework Security -framework CryptoKit \
  "$script_dir/PlainWebKitBrowser.swift" \
  "$script_dir/BrowserGlass.swift" \
  "$script_dir/GlassPageInjector.swift" \
  "$script_dir/BrowserSuggestions.swift" \
  "$script_dir/BrowserTheme.swift" \
  "$script_dir/FloatingTabWindow.swift" \
  "$script_dir/TabPreviewPopover.swift" \
  "$script_dir/FusedProfileLabel.swift" \
  "$script_dir/WebbyIcon.swift" \
  "$script_dir/BrowserMenuBar.swift" \
  "$script_dir/GoogleWorkspace.swift" \
  "$script_dir/WidgetCanvas.swift" \
  "$script_dir/WidgetFeeds.swift" \
  "$script_dir/BrowserDownloads.swift" \
  "$script_dir/ChromeImport.swift" \
  "$script_dir/BrowserPasswords.swift" \
  "$script_dir/ChromeSessions.swift" \
  "$script_dir/BrowserApp.swift" \
  "$script_dir/NativeTerminal.swift" \
  "$script_dir/IndicatorScenes.swift" \
  "$script_dir/NotchIndicatorEngine.swift" \
  "$module_cache/PTYLauncher.o" \
  -lsqlite3 \
  -o "$app/Contents/MacOS/Webby"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Webby</string>
  <key>CFBundleDisplayName</key><string>Webby</string>
  <key>CFBundleIdentifier</key><string>local.plainwebkit.browser</string>
  <key>CFBundleExecutable</key><string>Webby</string>
  <key>CFBundleIconFile</key><string>Webby</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>63</string>
  <key>CFBundleShortVersionString</key><string>3.8.9</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

iconset="$module_cache/Webby.iconset"
mkdir -p "$iconset"
"$app/Contents/MacOS/Webby" --render-icon "$iconset/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256; do
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Webby.icns"

codesign --force --sign "system local code signing" "$app"
echo "$app"
