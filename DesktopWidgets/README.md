# Webby in the macOS widget picker

The `WebbyWidgets.appex` extension is embedded in Webby.app. It is registered as
**Webby** in Edit Widgets, not as a separate desktop companion application. macOS
runs the sandboxed extension on its schedule; the browser need not be running.
Requires macOS 14 or later.

## First setup

Reopen the updated Webby. In the Webby menu-bar settings choose **Widgets &
Backgrounds → Desktop Widgets… → Enable Desktop Widgets**. macOS may ask for
Keychain authorization for existing calendar/GitHub connections. Then right-click
the desktop, choose **Edit Widgets**, and search **Webby**. Add a widget and edit it
to choose the owning profile. Webby can subsequently be fully quit.

## Included (17 gallery choices)

- Independently refreshed: Weather, Stocks, Google Calendar, GitHub Open PRs,
  Contributions, Repositories, Assigned Issues, Starred Repos, GitHub Activity.
- Sampled when macOS runs the timeline: Battery, System Monitor (memory/disk).
- Saved data: Quick Note, Spotify last track, Codex Chats, Codex Usage, Downloads,
  GitHub Recently Visited. These sync at enabled Webby startup/quit or when Desktop
  Widgets setup is repeated. Spotify artwork can download during widget refresh.

The existing network providers and iCal recurrence parser are reused by the build,
not reimplemented. API errors preserve cached data. Deleted profile selections
never fall back to another profile. Quote data may be delayed by the source.

WidgetKit cannot host typing fields, AppKit views, terminal/IDE sessions, continuous
system monitoring or the existing web-session widgets. Calculator, Clipboard,
IDE, Gmail, Drive and ChatGPT are **not advertised as working native ports** here.
Spotify playback controls and live Codex socket access need an additional supported
service design; this extension deliberately presents their saved state instead.
Downloads currently lists saved filenames; it does not continue browser downloads.

## Credentials and privacy

Webby's originals are never changed. Only foreground setup reads existing
Calendar/GitHub secrets, subject to macOS authorization. It stores separate login
Keychain entries under `local.webby.desktop.*`, trusted only to the signed browser
and embedded extension. Widget refresh uses `kSecUseAuthenticationUIFail`, so it
cannot trigger a surprise Keychain dialog. Secrets are never written to JSON,
source, logs or images. Browser cookies/passwords are not read or copied.

Local signing currently uses a narrowly scoped sandbox exception for
`~/Library/Application Support/Webby Desktop Widgets/` (owner-only directory and
files), containing profile configuration, notes and saved widget data. It grants no
access to browser stores. A Developer-ID distribution should use a provisioned
App Group instead. macOS acceptance of locally signed widgets must be checked on
the target Mac; PlugInKit registration is not proof of visible gallery rendering.

Disconnected connections and deleted profiles are pruned from the desktop Keychain
copies on the next enabled browser startup/quit or setup sync. Remote token/feed
revocation takes effect at the service itself. This is a first local build.

## Verification

`sh DesktopWidgets/check.sh` renders all 17 views in three families using isolated
synthetic data and checks immediate cache display, profile separation, deleted
profile handling, and nonfinite/flat chart data. It never reads real credentials or
personal profiles. Build fails unless App Intents metadata is generated. Release
bundles must pass `codesign --verify --deep --strict` and registration checks.
