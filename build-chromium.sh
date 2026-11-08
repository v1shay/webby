#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app=$1
cef="$script_dir/Vendor/CEF"
frameworks="$app/Contents/Frameworks"
mkdir -p "$frameworks"
if [ ! -f "$cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]; then
  echo "CEF is missing. Run python3 fetch-chromium.py first." >&2
  exit 1
fi
framework="$frameworks/Chromium Embedded Framework.framework"
mkdir -p "$framework/Versions/A"
for component in "Chromium Embedded Framework" Libraries Resources; do
  if [ -e "$framework/$component" ] && [ ! -L "$framework/$component" ]; then
    mv "$framework/$component" "$framework/Versions/A/$component"
  fi
done
ditto "$cef/Release/Chromium Embedded Framework.framework" "$framework/Versions/A"
for component in "Chromium Embedded Framework" Libraries Resources; do
  if [ ! -L "$framework/$component" ]; then ln -s "Versions/A/$component" "$framework/$component"; fi
done
if [ ! -L "$framework/Versions/Current" ]; then ln -s A "$framework/Versions/Current"; fi
for library in "$framework/Versions/A/Libraries/"*.dylib; do
  codesign --force --sign "${WEBBY_SIGN_IDENTITY:--}" "$library"
done
codesign --force --sign "${WEBBY_SIGN_IDENTITY:--}" "$framework"
cp "$cef/LICENSE.txt" "$app/Contents/Resources/CEF-LICENSE.txt"
cp "$cef/CREDITS.html" "$app/Contents/Resources/Chromium-Credits.html"
helper="$frameworks/Webby Helper.app/Contents"
mkdir -p "$helper/MacOS" "$helper/Resources"
if [ -f "$helper/entitlements.plist" ]; then
  mv "$helper/entitlements.plist" "$helper/Resources/legacy-entitlements.plist"
fi
clang++ -std=c++20 -fobjc-arc -O2 -target arm64-apple-macos13.0 -I "$cef" \
  "$script_dir/ChromiumHelper.mm" -framework Foundation -o "$helper/MacOS/Webby Helper"
cat > "$helper/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Webby Helper</string>
<key>CFBundleIdentifier</key><string>local.plainwebkit.browser.helper</string>
<key>CFBundleName</key><string>Webby Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Websites you choose may use Bluetooth to connect to a nearby phone or security key for sign-in.</string>
</dict></plist>
PLIST
cat > "$helper/Resources/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>
PLIST
codesign --force --entitlements "$helper/Resources/entitlements.plist" --sign "${WEBBY_SIGN_IDENTITY:--}" "$frameworks/Webby Helper.app"
# Sign nested binaries before the outer app bundle.
