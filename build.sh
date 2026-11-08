#!/bin/sh
set -eu
# Native builds work on either Mac architecture; explicit cross-builds need the
# matching Rust target installed. Keep the same target for Swift, C and Rust.
webby_arch="${WEBBY_ARCH:-$(uname -m)}"
case "$webby_arch" in
  arm64) rust_target=aarch64-apple-darwin ;;
  x86_64) rust_target=x86_64-apple-darwin ;;
  *) echo "Unsupported Mac architecture: $webby_arch" >&2; exit 2 ;;
esac
export WEBBY_ARCH="$webby_arch"
if [ -z "${WEBBY_SIGN_IDENTITY:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"system local code signing"'; then
    WEBBY_SIGN_IDENTITY="system local code signing"
  else
    WEBBY_SIGN_IDENTITY="-"
  fi
fi
export WEBBY_SIGN_IDENTITY
cargo_bin="${CARGO:-$(command -v cargo || true)}"
if [ -z "$cargo_bin" ] && [ -x "$HOME/.cargo/bin/cargo" ]; then cargo_bin="$HOME/.cargo/bin/cargo"; fi
if [ -z "$cargo_bin" ]; then echo "Install Rust (cargo) to build Webby." >&2; exit 2; fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="${WEBBY_BUILD_APP:-$script_dir/Webby.app}"
if [ -z "${WEBBY_BUILD_APP:-}" ] && [ -d "$script_dir/WebKit Browser.app" ] && [ ! -e "$app" ]; then
  mv "$script_dir/WebKit Browser.app" "$app"
fi
if [ -z "${WEBBY_BUILD_APP:-}" ] && [ -d "$script_dir/WebKit Browser.app" ] && [ -d "$app" ]; then
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
mkdir -p "$app/Contents/Resources/WidgetBrands"
cp "$script_dir/WidgetBrands/"* "$app/Contents/Resources/WidgetBrands/"
mkdir -p "$app/Contents/Resources/Fonts/Geist"
cp "$script_dir/Fonts/Geist/"* "$app/Contents/Resources/Fonts/Geist/"
cp "$script_dir/GeistPage.js" "$app/Contents/Resources/GeistPage.js"
mkdir -p "$app/Contents/Resources/Sounds"
cp "$script_dir/Sounds/"*.wav "$app/Contents/Resources/Sounds/"
mkdir -p "$app/Contents/Resources/Pets"
mkdir -p "$app/Contents/Resources/PetsWorking"
cp "$script_dir/gradient_profiles.json" "$app/Contents/Resources/gradient_profiles.json"
cp "$script_dir/ASCIIArtworks.json" "$app/Contents/Resources/ASCIIArtworks.json"
cp "$script_dir/ASCIIEngine.js" "$app/Contents/Resources/ASCIIEngine.js"
cp "$script_dir/VideoControls.js" "$app/Contents/Resources/VideoControls.js"
cp "$script_dir/PasswordFieldProbe.js" "$app/Contents/Resources/PasswordFieldProbe.js"
cp "$script_dir/ChatGPTWidget.js" "$app/Contents/Resources/ChatGPTWidget.js"
cp "$script_dir/ChromeTone.js" "$app/Contents/Resources/ChromeTone.js"
cp "$script_dir/LinkPreview.js" "$app/Contents/Resources/LinkPreview.js"
cp "$script_dir/GooglePromptFilter.js" "$app/Contents/Resources/GooglePromptFilter.js"
cp "$script_dir/CalendarFeed.js" "$app/Contents/Resources/CalendarFeed.js"
cp "$script_dir/Vendor/ical.js/ical.es5.min.cjs" "$app/Contents/Resources/ical.es5.min.cjs"
cp "$script_dir/Vendor/ical.js/LICENSE" "$app/Contents/Resources/ical.js-LICENSE"
cp "$script_dir/glass-page.js" "$app/Contents/Resources/glass-page.js"
cp "$script_dir/SchoologyDark.js" "$app/Contents/Resources/SchoologyDark.js"
cp "$script_dir/SkyBackground.png" "$app/Contents/Resources/SkyBackground.png"
cp "$script_dir/CodexWhiteIcon.svg" "$app/Contents/Resources/CodexWhiteIcon.svg"
cp "$script_dir/CodexWhiteIcon.png" "$app/Contents/Resources/CodexWhiteIcon.png"
cp "$script_dir/Pets/"*.png "$app/Contents/Resources/Pets/"
cp -R "$script_dir/PetsWorking/." "$app/Contents/Resources/PetsWorking/"

cp "$script_dir/FastRules.json" "$app/Contents/Resources/FastRules.json"

clang -O2 -target "$webby_arch-apple-macos14.0" -c "$script_dir/PTYLauncher.c" -o "$module_cache/PTYLauncher.o"

background_target="$script_dir/../work/code-background-target"
# Online by default for a fresh checkout; opt into deterministic offline builds.
if [ "${WEBBY_OFFLINE:-0}" = 1 ]; then offline_flag=--offline; else offline_flag=; fi
"$cargo_bin" build --release --locked $offline_flag --target "$rust_target" --manifest-path "$script_dir/Vendor/CodeBackground/Cargo.toml" --target-dir "$background_target"
mkdir -p "$app/Contents/Resources/CodeBackground"
cp "$script_dir/Vendor/CodeBackground/Monocode-MIT.txt" "$script_dir/Vendor/CodeBackground/NOTICE.md" "$script_dir/Vendor/CodeBackground/ThirdPartyLicenses.txt" "$app/Contents/Resources/CodeBackground/"

swiftc -O -parse-as-library -target "$webby_arch-apple-macos14.0" -module-cache-path "$module_cache" -framework AppKit -framework WebKit -framework AVFoundation -framework Security -framework CryptoKit -framework IOKit -framework JavaScriptCore -framework Carbon -framework WidgetKit \
  "$script_dir/PlainWebKitBrowser.swift" \
  "$script_dir/BrowserGlass.swift" \
  "$script_dir/GlassPageInjector.swift" \
  "$script_dir/BrowserSuggestions.swift" \
  "$script_dir/BrowserTheme.swift" \
  "$script_dir/FloatingTabWindow.swift" \
  "$script_dir/MiniWebby.swift" \
  "$script_dir/TabPreviewPopover.swift" \
  "$script_dir/FusedProfileLabel.swift" \
  "$script_dir/WebbyIcon.swift" \
  "$script_dir/BrowserMenuBar.swift" \
  "$script_dir/GoogleWorkspace.swift" \
  "$script_dir/WidgetCanvas.swift" \
  "$script_dir/ASCIIBackgrounds.swift" \
  "$script_dir/WidgetExtras.swift" \
  "$script_dir/WidgetFeeds.swift" \
  "$script_dir/CalendarFeed.swift" \
  "$script_dir/CalendarWidgetView.swift" \
  "$script_dir/BrowserDownloads.swift" \
  "$script_dir/ChromeImport.swift" \
  "$script_dir/BrowserPasswords.swift" \
  "$script_dir/ChromeSessions.swift" \
  "$script_dir/BrowserPerformance.swift" \
  "$script_dir/BrowserWallpaper.swift" \
  "$script_dir/BrowserApp.swift" \
  "$script_dir/NativeTerminal.swift" \
  "$script_dir/LightweightIDE.swift" \
  "$script_dir/CodeWorkbench.swift" \
  "$script_dir/IDEIdentity.swift" \
  "$script_dir/GitHubWidgets.swift" \
  "$script_dir/CodexAppWidgets.swift" \
  "$script_dir/DesktopWidgets/Shared.swift" \
  "$script_dir/DesktopWidgets/Host.swift" \
  "$script_dir/IndicatorScenes.swift" \
  "$script_dir/NotchIndicatorEngine.swift" \
  "$module_cache/PTYLauncher.o" \
  "$background_target/$rust_target/release/libwebby_code_background.a" \
  -lsqlite3 -lc++ -framework CoreImage -framework ImageIO \
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
  <key>CFBundleVersion</key><string>84</string>
  <key>CFBundleShortVersionString</key><string>3.14.2</string>
  <key>NSAppleEventsUsageDescription</key><string>Webby reads and controls Spotify for its music widget.</string>
  <key>NSCameraUsageDescription</key><string>Allow a website you choose to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Allow a website you choose to use the microphone.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Allow a website you choose to use your location.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Web pages</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array></dict></array>
  <key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>HTML Document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array></dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [ -n "${WEBBY_BUILD_ICON_SOURCE:-}" ]; then
  cp "$WEBBY_BUILD_ICON_SOURCE" "$app/Contents/Resources/Webby.icns"
else
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

fi

sh "$script_dir/DesktopWidgets/build-extension.sh" "$app"

codesign --force --sign "${WEBBY_SIGN_IDENTITY:-system local code signing}" "$app"
echo "$app"
