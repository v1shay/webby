<img width="1706" height="976" alt="image" src="https://github.com/user-attachments/assets/f269a5f9-c5d6-4fbf-b723-7cbf74a32111" />

### Embedded browser engines (Apple Silicon)

WebKit and CEF/Chromium share Webby's native interface. Choose the default for
new tabs in **Webby Settings → Default Rendering Engine**. Use **⇧⌘E** to switch
the current tab (with reload confirmation), or **⌥⇧⌘E** for a new tab in the other
engine. The address gradient and tab underline identify the engine.

Each engine keeps separate website storage and sign-ins. Switching engines
reloads the URL; live page state does not transfer. Chromium loads on demand.
Saved passwords use Webby's existing profile-scoped Keychain vault in both
engines, including automatic fill and **Fill Password for This Site**. Filling
requires HTTPS and a matching current main-frame origin; passwords are never
shared between profiles. Bluetooth-assisted sign-in uses macOS permission UI.
Its native event pump runs while Chromium pages exist; idle tabs use Webby's
existing offload protections. macOS may request keychain access when Chromium
first initializes encrypted website storage.

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
contents, retains a backup, and leaves an already-running Webby open.
