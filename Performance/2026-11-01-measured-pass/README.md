# Webby measured performance pass — November 1, 2026

The pass reduces UI-thread session-save work and unnecessary hidden-background activity. It preserves the existing visible animation physics, rendering resolution, glass colors/materials, profile stores and custom app icon. Functional checks passed. **A universal website-loading speedup, zero jitter, battery-life gain, or fastest-browser ranking was not established.** No live visual comparison of the user's signed-in pages was performed.

## Changes and checks

| Stage | Implementation | Evidence |
|---|---|---|
| Measurement | Honest compiler optimization labels; exact flags/source hashes/hardware/power/thermal manifests; raw selection samples; seeded arbitrary-URL ABBA driver. | Optimized `-O` builds; full raw reports below. No fixed-host timing assertions. |
| Session persistence | Immutable main-actor snapshot; serial utility encoding/writes; pending revision coalescing; synchronous final save at quit. | 80/800/5,000-page benchmarks; 1,000-revision newest-write and shutdown checks passed. |
| Selection/chrome | Avoid redundant visibility/alpha mutations, repeated same-tab layout, unchanged wallpaper geometry capture and quadratic tab-ID searches. | Matched regression timings, repeated noisy runs, unchanged motion/geometry assertions. Existing cached previews retained. |
| Background scheduling | Stop widget/wallpaper/ASCII timers when their consumers are hidden; stop still/paused artwork polling; wake on visibility, resize, profile and Reduce Motion changes. Mini-window archive service remains alive. | Real native renderer/loop counters; GIF/ASCII resume, cached artwork and resize checks passed. Visible render cadence retained. |
| Generic glass fallback | Bounded first-shell breadth queue; remove redundant media-ancestor traversal. Existing CSS recipes and colors retained. | 30,000 direct siblings: **30,002 → 23 shell queue insertions**, identical style/rect counts and resulting surface. Instrumented install 249 → 244 ms is a single synthetic sample, not a real-site speedup claim. Visible 600-panel fallback converged before/after with identical surface/text. |
| Working set | Soft 12–48 resident-view target based on physical memory; increase an over-budget eligible idle-eviction batch from 2 toward 4. | 3,500 policy-bound checks; existing dirty/editor/media/capture/split/pin/keep-loaded protections passed. User timeout and disabling behavior retained. No absolute memory-cap claim. |
| Existing paths retained | Narrow title/favicon/progress updates, normal HTTP cache policy, profile-owned WebKit stores, early compiled tracker rules, feed visibility guards, IDE lazy launch/release. | Audited; no forced stale-cache reads, speculative authenticated preloads, site-specific benchmark shortcuts, or engine/security flag changes. |

## Focused measurements

| Metric | Before | Candidate |
|---|---:|---:|
| 80-page encoding/write versus enqueue CPU p95 | 0.798 ms | 0.018 ms |
| Vertical tab selection CPU p95, latest matched 45-call run | 2.74 ms | 2.27 ms |
| Horizontal tab selection CPU p95, same run | 2.75 ms | 2.71 ms |
| Hidden wallpaper timer callbacks, nominal 2-second sample | 8 | 0 |
| Still wallpaper callbacks, nominal 2-second sample | 9 | 0 |
| Paused GIF callbacks, nominal 1-second sample | 4 | 0 |
| Active GIF callbacks, nominal 1-second sample | 21 | 21 |
| Hidden ASCII callbacks, nominal 2-second sample | 22 | 0 |
| ASCII callbacks while dragging, nominal 1-second sample | 11 | 0 |
| Visible ASCII callbacks, nominal 1-second sample | 10 | 10 |

These are measured scopes, not full-browser speed claims. Session snapshot collection remains on the main actor and is not included in the encoding/enqueue microbenchmark. Timer observation intervals use scheduled sleeps and may resume late. Repeated tab tests showed substantial system variance; the latest point estimates do not establish statistical significance or input-to-display latency. Full WebKit renderer/GPU resource use was not attributed.

## Real public website results

The same six HTTPS URLs were shuffled with seed 20261101, rotated across rounds, and run in baseline/candidate/candidate/baseline order. Both main builds used the same **1472 × 930** content viewport, enabled glass/Geist/compiled tracker rules, isolated logged-out stores, and ordinary cache semantics. Each build has 24 visits: four per URL. Fresh-session and repeat visits are recorded separately in raw data; first visits are **not** fully cold because OS caches are uncontrolled.

Median milliseconds, baseline → candidate:

| URL | Native request/setup → load completion | First contentful paint | Interpretation |
|---|---:|---:|---|
| https://www.bbc.com/ | 1845 → 2027 | 1016 → 1008 | Four logged-out visits per build; mixed fresh-session/repeat visits. |
| https://github.com/explore | 1069 → 1003 | 428 → 430 | Four logged-out visits per build; mixed fresh-session/repeat visits. |
| https://developer.mozilla.org/en-US/ | 682 → 760 | 203 → 194 | Four logged-out visits per build; mixed fresh-session/repeat visits. |
| https://stackoverflow.com/questions | excluded | excluded | Challenge and actual-content visits mixed; all retained in raw results. |
| https://www.wikipedia.org/ | 382 → 377 | 182 → 185 | Four logged-out visits per build; mixed fresh-session/repeat visits. |
| https://www.apple.com/ | 938 → 1008 | 466 → 477 | Four logged-out visits per build; mixed fresh-session/repeat visits. |

**The results are mixed.** Later assets and network/server timings vary; FCP is close across most sites. The sample does not prove that any individual site will always load faster. A successful load event also does not prove that a signed-in app is usable. Challenge samples are excluded from the comparative table, not erased from results.

There are 72 sample records under matched-viewport protocols: 48 main visits, 12 no-glass diagnostic visits and 12 matched-viewport native-WK control visits. The first minimal-WK control used a 972px-high viewport and is retained but excluded from matched comparisons; it was rerun as `control-minimal-wk-matched.json` at 1472 × 930. This native control has a separate lightweight host; it is not Safari and host CPU must not be interpreted as total WebKit CPU. See `control-notes.json`.

## Appearance, interaction and data protection

The combined candidate passed the native regression suite: inputs/widgets, group creation/collapse/rename, Command-click links, profile ownership/Fuse transitions, restored/suspended tabs, four-pane and IDE splits, suggestions, typography/CSP, real PiP/fullscreen/media state, hover/address controls, finger tracking/cancellation/interruptions and unchanged geometry. Fifteen **domain-shaped compatibility fixtures** also passed; these are not fifteen live website benchmarks.

No visible animation constants, wallpaper resolution/effects, glass color values, favicon handling, normal data-store identity, cookies or keychain credentials were replaced. The app was not quit by the installer. The release is staged/signed separately and its custom Finder icon is preserved during atomic replacement.

## Experiments not promoted to speed claims

- Snapshot mode: 40 alternating snapshots of a real Wikipedia page had identical 1700 × 1000 PNG hashes. Median callback latency was essentially unchanged; p95 worsened when skipping screen updates. No preview-mode change shipped.
- Occluded wide-page probes timed out. They remain under `raw/excluded-exploratory`; their scheduling/visibility conditions do not establish visible-page speed.
- The Instruments Animation Hitches run reported an unsupported GPU counter profile and lost events; the target did not finish its test report before termination. The index/log are retained but no compositor-FPS, zero-hitch, or GPU-power result is claimed. See [Apple's render-pipeline explanation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).
- Startup click-to-usable latency, real signed-in workflows, total renderer/GPU memory, energy consumption and battery life were not measured in this pass. WebKit's visibility/cache behavior informs the design; see [WebKit's power guidance](https://webkit.org/blog/8970/how-web-content-can-affect-power-usage/).

## Reproduce and inspect

- [Benchmark instructions](../../Tests/PERFORMANCE.md)
- [Raw real-site runs](real-world/summary.json) and [run conditions](real-world/manifest.json)
- [Final selection/functional report](raw/final2-regression.json)
- [Exact candidate build flags and hashes](raw/final2-build-manifest.json)
- [Session and policy checks](raw/session-final.json)
- [This pass's diff against the pre-task files](this-pass.diff) (repository already had unrelated changes)

Raw JSON includes failures, timeouts, page titles, viewport, Navigation/Paint Timing where available, host CPU and rAF gaps. **rAF gaps are frame opportunities, not compositor FPS.** Use a reliable render-pipeline trace for a genuine animation-hitch claim.

The installed build passed code-signature verification. See [installation record](installation.json). The running app was not quit or relaunched; reopen Webby when ready to use the new native code. The test-only in-shell minimal-control layout was corrected after detecting the viewport mismatch; normal baseline/candidate load-path measurements are unaffected.

## Subsequent wallpaper correction

A switching race escaped the first pass: an in-flight render could leave the next static wallpaper pending after polling stopped. The follow-up fix and failing/passing tests are recorded in [Wallpaper switching regression fix](../2026-11-01-wallpaper-switching/README.md). Original benchmark records above remain unchanged.
