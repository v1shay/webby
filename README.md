<img width="1706" height="976" alt="image" src="https://github.com/user-attachments/assets/f269a5f9-c5d6-4fbf-b723-7cbf74a32111" />

### Embedded browser engines (Apple Silicon, macOS 14 and later)

WebKit and CEF/Chromium share Webby's native interface. Choose the default for
new tabs in **Webby Settings → Default Rendering Engine**. Use **⇧⌘E** to switch
the current tab (with reload confirmation), or **⌥⇧⌘E** for a new tab in the other
engine. The address gradient and tab underline identify the engine.

Schoology uses the custom dark palette in Chromium and in WebKit with page
glass off. WebKit supports translucent Schoology surfaces with page glass on.
Chromium uses an opaque embedded view. Chromium popups open in Webby tabs
while preserving their opener, form submissions, and profile or private session.

Each engine keeps separate website storage and sign-ins. Switching engines
reloads the URL; live page state does not transfer. Chromium loads on demand.
Saved passwords use Webby's existing profile-scoped Keychain vault in both
engines, including automatic fill and **Fill Password for This Site**. Filling
requires HTTPS and a matching current main-frame origin; passwords are never
shared between profiles. Bluetooth-assisted sign-in uses macOS permission UI.
Its native event pump runs while Chromium pages exist; idle tabs use Webby's
existing offload protections. macOS may request keychain access when Chromium
first initializes encrypted website storage.

Hover over a video in either engine for Webby's Picture in Picture and
Fullscreen controls. The controls keep the site's original media session.
The pinned standard CEF package plays WebM (VP9/Opus) but omits H.264 and AAC
support. For sites that only offer those formats, Webby's WebKit engine can
use the macOS codecs. Native H.264/AAC playback in Chromium requires a
codec-enabled build of the pinned CEF release.

To build that release on Apple Silicon, follow the [CEF build instructions](https://github.com/chromiumembedded/cef/blob/master/docs/automated_build_setup.md)
with the macOS SDK required for the branch. Use CEF revision `cf671c0` on
branch `8078`, select the arm64 minimal Release distribution, and add
`proprietary_codecs=true ffmpeg_branding=Chrome` to `GN_DEFINES`.
Package the resulting distribution into a fresh staging bundle by setting
`WEBBY_CEF_DIR` to the extracted CEF distribution and `WEBBY_BUILD_APP` to the
staging app path when running `./build.sh`. Set
`WEBBY_REQUIRE_CHROMIUM_MP4=1` when running `Tests/check-browser-engines.sh` to
require H.264/AAC playback, Picture in Picture, and inline return in the
embedded Chromium engine. Set `WEBBY_BUILD_APP` to the same staging app path
for that check.

The CEF distribution is pinned in `Vendor/CEF/version.json` and fetched from
the official CEF build service:

```sh
python3 fetch-chromium.py
WEBBY_SIGN_IDENTITY=- ./build.sh
sh Tests/check-browser-engines.sh
python3 install-built-webby.py
```

The checks use local fixture pages, temporary profiles, and a synthetic test
keychain. They cover mixed-engine browsing, navigation, storage isolation,
switch confirmation/cancellation, split views, offload/resume, failed-load
recovery, repeated close/create cycles, and shutdown. They do not approve macOS
keychain prompts or use saved sign-ins. The installer atomically swaps bundle
contents, retains a backup, and leaves an already-running Webby open. Use
`--destination /path/to/Webby.app` when Webby lives outside `~/Applications`.

### Webby Agent and Local CLI

Open **Webby Agent** with **⇧⌘J** to use the running local Codex app server from a browser tab. Enable **Local CLI** in that tab to let other local agents drive Webby’s existing profiles and pages. See [Webby Agent and CLI usage](WEBBY-AGENT.md).
