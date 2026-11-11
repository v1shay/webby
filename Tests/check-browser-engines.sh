#!/bin/sh
set -eu
export WEBBY_ENGINE_TEST_KEYCHAIN=1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="${WEBBY_BUILD_APP:-$root/Webby.app}"
python3 - "$app" <<'PY'
import plistlib, sys
from pathlib import Path
app=Path(sys.argv[1])
for path in [app/'Contents/Info.plist',app/'Contents/Frameworks/Webby Helper.app/Contents/Info.plist']:
    with path.open('rb') as handle: info=plistlib.load(handle)
    assert info.get('NSBluetoothAlwaysUsageDescription','').strip(), f'Missing Bluetooth usage declaration: {path}'
print('PASS: Bluetooth privacy declarations in browser and helper bundles')
PY
work=$(mktemp -d /tmp/webby-engine-checks.XXXXXX)
python3 "$root/Tests/engine_fixture_server.py" > "$work/port" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT INT TERM
while [ ! -s "$work/port" ]; do sleep 0.1; done
base="http://127.0.0.1:$(cat "$work/port")"
clang++ -std=c++20 -fobjc-arc -O1 -target arm64-apple-macos13.0 -I "$root/Vendor/CEF" \
  "$root/Tests/ChromiumIntegration.mm" "$root/ChromiumBridge.mm" -framework AppKit -framework WebKit \
  -o "$app/Contents/MacOS/WebbyEngineChecks"
codesign --force --sign - "$app/Contents/MacOS/WebbyEngineChecks"
codesign --force --sign "${WEBBY_SIGN_IDENTITY:--}" "$app"
"$app/Contents/MacOS/WebbyEngineChecks" "$base" "$work/profiles"
# The real product executable includes an isolated diagnostic entry point.
codesign --force --sign "${WEBBY_SIGN_IDENTITY:--}" "$app"
python3 - "$app/Contents/MacOS/Webby" "$base" <<'PY'
import subprocess, sys
# Detect a wedged main queue from outside the synthetic diagnostic process.
subprocess.run([sys.argv[1], '--check-engine-ui', sys.argv[2]], check=True, timeout=45)
PY
# Keep the generated check executable out of the distributable app bundle.
mv "$app/Contents/MacOS/WebbyEngineChecks" "$work/WebbyEngineChecks"
codesign --force --sign "${WEBBY_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
