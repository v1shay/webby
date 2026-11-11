# Webby 3.17.6 reliability and performance audit

This pass used the existing dual-engine Webby checkout, including its uncommitted changes, as the baseline. The checks used disposable profiles and local HTTP fixtures except for the public page-load comparison. The test Mac was a Mac15,12 (Apple Silicon) running macOS 14.2. The audit did not use personal browser sessions or approve credential prompts.

## Changes verified

| Area | Change and evidence |
| --- | --- |
| Text and keyboard editing | Native AppKit mouse drag, Copy, Select All, Paste, and Cut passed in both embedded engines. Clipboard sentinels prevent a previous engine's clipboard result from falsely passing the next check. |
| Split panes and find | Clicking a pane routes the address bar and page commands to that pane. Changing active panes within the visible split avoids unnecessary PiP. Chromium find starts a fresh search on a new query, reports match status, and clears the find selection. WebKit ignores stale find completions. |
| Navigation and restoration | Chromium retains a pending initial navigation and a newer explicit request takes precedence. Session saves prefer an in-flight destination to the previous page's URL. |
| Popups | Chromium adopts the real popup into a Webby tab. Native tests cover blank `document.write`, opener identity, named reuse, `postMessage`, form POST bodies, script close, blocking, and private-session storage. |
| Site permissions | A native permission change does not recreate either pane. A policy that needs a document-start script reloads only the affected host and updates future navigations. A split on a different host retains an unsaved form and its other scripts. |
| Downloads | Chromium Cancel stops pending and active transfers; the fixture server verifies the active connection closes. URLSession cancellation wins a race with the final move without leaving a cancelled file behind. Terminal records are bounded, and private history stays out of persistence. |
| Widgets and wallpaper | Weather ignores invalid temperatures without trapping or inventing a missing low. An AVPlayer failure stops the wallpaper poller; replacing the wallpaper works. The instrumented failure case went from 21 callbacks/second to zero. |
| Address suggestions and rendering overhead | URL matching remains case insensitive while distinct case-sensitive destinations stay selectable. The fixed theme list is sorted once and the bundled page-edge color script is read once per process. |

The theme microbenchmark exercised the production catalog getter with the real bundled theme list: 10,000 warmed accesses took about 1.29 s before caching; the optimized compiler can reduce the cached count-only loop to about 0.012 ms. This isolates avoided catalog work and does not represent a tab-switch or page-load speedup.

## Startup and public page loads

Seven startup fixture processes ran Webby's normal startup handler with one isolated profile and 80 saved tabs. Time from entering the handler to Webby's window-ready marker was **177 ms median** (162–191 ms range). All 80 tabs restored as metadata; zero page views were allocated. The measurement excludes process initialization and does not measure a physical frame or an authenticated page becoming usable.

The WebKit page-load comparison used a 1392 × 963 viewport and baseline/candidate/candidate/baseline order. Each build had four visits per site across fresh ephemeral stores and repeat loads. These are median milliseconds from new-tab setup through navigation completion:

| Site | Before | Candidate |
| --- | ---: | ---: |
| Wikipedia | 1,335 | 1,328 |
| Example Domain | 103 | 116 |
| MDN Web Docs | 143 | 123 |

All 24 samples completed with no measured navigation failures, timeouts, or challenge pages. The ranges overlap and network/server times vary. The results are mixed; they do not demonstrate a general page-load speedup or compare Webby against Safari or Chrome. The baseline used `-O` and the candidate used `-O` with whole-module optimization. The local tracker fixture measured about 630 ms with its deliberately slow resource versus 20 ms with the existing WebKit blocker applied. That verifies the blocker path; it is not a new real-site performance gain.

See [final public load samples](release-public-loads/), [earlier audit samples](public-page-results/), [final startup runs](release-startup-results.json), [supporting checks](support-checks.md), and [native interaction test instructions](../../Tests/INTERACTIONS.md). The source patch compares production sources with the pre-audit checkout; it omits that checkout's pre-existing changes.

## Tab switching and release checks

The final change skips redundant chrome work and unchanged appearance assignments. In two matched runs per variant, the median of the run medians for switching between loaded pages was 1.36 → 1.23 ms in the sidebar and 1.53 → 1.44 ms in the horizontal layout. The timed interval ends before final input focus and excludes compositor latency. Transitions between home and a page still take roughly 15 ms in this fixture because they change page geometry. See [raw tab-selection comparison](selection-compare/).

The final source passed the full native suite, including Mini Webby, window and split layout, typography, fullscreen/PiP, and links. The signed app passed the dual-engine suite and strict signature verification. Separate checks passed for onboarding, settings, protected profile import with synthetic data, Local CLI in both engines, downloads, the native IDE widget, and Java diagnostics, diagnostic clearing, real breakpoint pause, debugger stop, and native Find in the isolated Workbench. The installed executable matches the signed artifact. The pre-audit app and the first audit build were backed up; see [release verification](release-verification.json).

These tests cannot establish zero bugs. Other Macs and macOS versions, live signed-in services, every extension/site, and stock CEF's missing H.264/AAC support remain outside the verified scope.
