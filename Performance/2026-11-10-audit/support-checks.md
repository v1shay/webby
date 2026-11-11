# Webby supporting feature audit — November 10, 2026

Repository: `/Users/vishayagarwal/Documents/Codex/2026-09-29/can-y/webby-unified`.
All commands below ran in that repository, using disposable local files/defaults. Existing dirty changes preserved. This is local Apple Silicon/macOS evidence, not a proof of absence of all defects or cross-machine compatibility.

## Fixes and direct regressions

`BrowserDownloads.swift`: Cancel now dispatches an engine-specific callback (BrowserApp and Chromium bridge wiring coordinated with other agents). A cancelled URLSession transfer that has already moved its temporary file now deletes that file when its deferred main-queue completion arrives. Session invalidation no longer depends on owner lifetime. URLSession completion and cancellation now trim in-memory entries after all transports finish, and persist after trimming, matching the 30-entry limit of the other transports.

Command: `python3 Tests/test_download_lifecycle.py`

Output: `PASS: cancellation after file move cleans up, engine Cancel dispatches, session history stays bounded, private download not persisted`

The test deliberately withholds main-queue completion until the worker has stored the actual file, cancels, then checks file cleanup. It also sends 35 downloads from a loopback HTTP fixture, checks 30 retained records, and checks 29 persisted public records when the newest transfer is private. Engine callback test uses a synthetic callback; actual CEF cancellation was independently tested by engine_interaction in ChromiumIntegration.

`WidgetFeeds.swift`: Every current/daily/hourly temperature uses finite, exactly representable rounded Int conversion. Invalid current readings fail cleanly; malformed optional readings are omitted. Missing low temperature no longer displays an invented 0°F.

Command: `swiftc -parse-as-library WidgetFeeds.swift Tests/WidgetFeedParsingTests.swift -o /tmp/webby-support-checks/widget-feeds && /tmp/webby-support-checks/widget-feeds`

Output: `PASS: weather rounding, missing daily values, invalid and overflowing temperatures never crash`

## Existing feature checks

- `python3 Tests/test_profile_store.py`: PASS fresh install, atomic saves, previous-good recovery, profile identity retained; corrupt files never treated as empty install.
- `python3 Tests/test_wallpaper_sets.py`: PASS original/duplicate isolation, effects/restoration, tab glass, references, rename/restart persistence, unknown selection, active/inactive deletion and last-pair protection.
- `python3 Tests/test_homepage_layouts.py`: PASS 9,315 mixed-size layout cases, boundaries/overlaps; featured layouts produce different sizes.
- `python3 Tests/test_scientific_calculator.py`: PASS 20 scientific/precedence/answer cases and 7 invalid/bounded input cases.
- `python3 Tests/test_suggestion_worker.py`: PASS profile isolation, Fuse recency, routing, revision updates, cancellation, 10k entries, unsafe URL filtering.
- `swiftc -parse-as-library WebbyOnboardingState.swift Tests/OnboardingStateTests.swift -o /tmp/webby-support-checks/onboarding` then executable: PASS first-run gating, ten steps, Back, interruption recovery, skip, completion, schema version.
- `swiftc -parse-as-library CalendarFeed.swift Tests/CalendarSnapshotCacheTests.swift -o /tmp/webby-support-checks/calendar-cache` then executable: PASS immediate restoration, profile/source/month isolation, URL secrecy, invalidation.
- `swiftc -parse-as-library CalendarFeed.swift Tests/CalendarFeedTests.swift -o /tmp/webby-support-checks/calendar-feed` then executable with a temporary resource folder containing CalendarFeed.js and Vendor/ical.js/ical.es5.min.cjs: PASS recurrence/COUNT/exclusions/moved overrides/DST/all-day/folded Unicode/cancellations/empty/malformed input. PASS upcoming agenda events 18–20 years away, exclusions/cancellations, moved overrides, ongoing all-day.
- `swiftc -parse-as-library WidgetExtras.swift Tests/SpotifyCacheTests.swift -o /tmp/webby-support-checks/spotify-cache` then executable: PASS persisted track, paused startup, bounded 640px cover, URL isolation, corrupt cover retention.
- `git diff --check -- BrowserDownloads.swift WidgetFeeds.swift Tests/test_download_lifecycle.py Tests/WidgetFeedParsingTests.swift`: no output/errors.

## Session persistence measurement (existing implementation, not a new speedup)

Commands: `python3 Tests/build_session_persistence_bench.py /tmp/webby-support-checks/session` and `/tmp/webby-support-checks/session/session-bench`.

Output: coalescingAndShutdownPassed=true, optimization=-O, workingSetBoundChecks=3500.

| Page records | Synchronous encode/defaults p95 ms | Current enqueue p95 ms |
|---|---:|---:|
| 80 | 2.3319166685 | 0.1450416676 |
| 800 | 7.6323750000 | 0.0490833336 |
| 5000 | 50.0134583344 | 0.1256249998 |

These measure synchronous encode/persist versus enqueue work on this Mac, excluding snapshot collection. They do not measure page loading, startup, total browser CPU, renderer memory, or a comparison with another browser.

## Warnings and remaining scope

Standalone download builds emit existing WKDownloadDelegate main-actor conformance warnings under the installed Swift SDK. Calendar builds emit the existing deprecated kSecUseAuthenticationUIFail warning. Both builds succeed. No real credentials or keychain prompts were approved. Authenticated third-party widget providers, physical controls and cross-machine behavior remain outside these supporting checks. Full product build and main browser harness are owned by the root agent.

## Frozen supporting source timestamps

No further production edits after these timestamps (America/Los_Angeles):

- BrowserDownloads.swift: 2026-11-10 17:43:35 PST; SHA-256 `7f25db0998e014bce561464e3d8acee7ba0c850fc94cb3735339cbf8ecd97016`.
- WidgetFeeds.swift: 2026-11-10 17:38:38 PST; SHA-256 `4fe3e686b25ed5d6b905a91ea9b486b60c6627e5eac88d356081e6e541759b82`.
- BrowserWallpaper.swift: 2026-11-10 17:44:08 PST; SHA-256 `80de09d7b8047cbac44c6241ed41638e3210dccc0f55db421fcafe23b20825b1`.

The full candidate build must start after 17:44:08 PST to include every supporting fix. Download lifecycle check reran and passed after the final downloads edit; full output is in `download-lifecycle.log` beside this report. Final supporting `git diff --check` passed.

## Measured wallpaper failure scheduling fix

An invalid local movie fixture reached AVPlayerItem status 2 (`failed`). Before the fix, the actual wallpaper scheduler continued ticking 21 times in one second. `BrowserWallpaper.swift` now stops its timer after terminal video failure and allows replacing that wallpaper normally. After the fix: 0 failed-video ticks in one second; valid static wallpaper also 0 ticks in two seconds; paused GIF 0 ticks in one second; GIF resume and static resize passed. The candidate test also replaces the failed movie with a valid still image and asserts recovery.

Saved exact temporary probe sources: `WallpaperBaselineProbe.swift` and `WallpaperCandidateProbe.swift`; raw outputs: `wallpaper-baseline.json` and `wallpaper-candidate.json`. `Tests/build_wallpaper_scheduling_probe.py` now includes the failed-video regression/recovery assertions. These standalone probes stub unused theme/backdrop and WebKit-background helpers. To keep scheduling checks deterministic when another app occludes the test window, the temporary probes use window attachment rather than OS occlusion for their visible predicate. The production visibility/occlusion code is unchanged. The initial unmodified environment-dependent probe did not complete its assertions, so only the controlled visibility probe supports the numeric comparison. Candidate retained assertions; baseline temporary assertions were converted to diagnostics for observation. Hidden-wallpaper candidate result recorded one late callback in two seconds, not a continuing timer; no broad hidden-zero assertion is made.

Compile each saved probe from the repository with:

```
swiftc -O -parse-as-library /private/tmp/webby-audit-20261110/WallpaperCandidateProbe.swift -framework AppKit -framework WebKit -framework AVFoundation -framework CoreImage -framework ImageIO ../work/code-background-target/aarch64-apple-darwin/release/libwebby_code_background.a -lc++ -o /tmp/webby-support-checks/wallpaper-candidate
/tmp/webby-support-checks/wallpaper-candidate /tmp/webby-support-checks/wallpaper-candidate-results
```

Same invocation applies to the saved baseline probe with separate output paths. The comparison measures scheduler wakeups after a broken local wallpaper; it does not establish page-load, startup or overall-browser CPU improvements.
