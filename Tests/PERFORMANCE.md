# Reproducible Webby performance checks

Use an optimized, isolated test application. The normal app and its authenticated profiles are never launched, quit, reset or imported by these commands.

```sh
WEBBY_TEST_OPTIMIZATION=-O python3 Tests/build_performance_harness.py /private/tmp/webby-bench/candidate
python3 Tests/run_real_world_benchmarks.py \
  --baseline-app /private/tmp/webby-bench/baseline/WebbyTests.app \
  --candidate-app /private/tmp/webby-bench/candidate/WebbyTests.app \
  --corpus /absolute/path/to/public-urls.json \
  --output /private/tmp/webby-bench/results --rounds 3 --seed 20261101
```

Run from the repository's `outputs` directory. The corpus is any JSON array of HTTPS URLs. Keep the same input and seed for comparisons. There are no host-specific timing thresholds or success exceptions. The checked corpus is a sample, not a required website list. Never include secret URLs in a report intended for sharing.

`WEBBY_TEST_BASELINE_DIR` optionally supplies original runtime source files. Files not present there use the current tree; the build manifest hashes the exact compiled Swift and injected JavaScript. Save a complete source snapshot for comparisons beyond a small isolated change.

## What is measured

- ABBA ordering: baseline, candidate, candidate, baseline; each run rotates the seeded site order over successive visits.
- Time from requesting a new tab through WebKit load completion, including native tab setup. This is not time to a fully useful signed-in web app.
- Navigation/Paint Timing entries where supported, final URL, page title, DOM/resource counts, viewport, timeout and evaluation errors.
- Browser-host CPU during the load interval and cumulative host peak RSS. These exclude WebKit's separate renderer, networking and GPU processes. Do not sum or label these numbers as total browser resource use.
- Sixty requestAnimationFrame opportunities after load, with a three-second collection bound. These are not compositor FPS, scrolling smoothness, interaction-to-next-paint or physical display latency.
- Existing native regression tests measure synchronous tab-selection CPU, suggestion work, and behavior of groups, profiles, Fuse, splits, media, controls, typography and motion cancellation. Selection CPU excludes input delivery and the compositor. Nearest-rank p95 and raw selection samples are included in the corrected report.
- Optional controls: a Webby page with glass injection off and a WKWebView without Webby user scripts in the same browser shell. These are diagnostic controls, not measurements of Safari or Chrome. Check recorded viewport dimensions and page titles before comparing.

Fresh visits use a new ephemeral WebKit store per run. Repeat visits reuse that store and respect ordinary server cache policies. OS DNS/TLS caches, network/server variance, thermal conditions and background user activity are uncontrolled. Do not label the first visit a fully cold load. Build manifests and run manifests record optimization, source hashes, hardware, OS, compiler, power and thermal reports.

Failures, timeouts, challenge titles and missing measurements remain in results. A challenge page must not be counted as a successful fast website load. Small samples are reported as medians and ranges; they do not establish a world record or a population p95.

## Focused checks

```sh
python3 Tests/build_session_persistence_bench.py /private/tmp/webby-session
/private/tmp/webby-session/session-bench
python3 Tests/build_wallpaper_scheduling_probe.py BrowserWallpaper.swift /private/tmp/WallpaperProbe.swift
python3 Tests/build_ascii_scheduling_probe.py ASCIIBackgrounds.swift /private/tmp/ASCIIProbe.swift
```

The session builder reads the actual writer/policy implementation rather than duplicating it. It checks newest-write coalescing, synchronous shutdown persistence, 80/800/5,000-page encoding/enqueue timings, and working-set batch bounds. Main-thread snapshot collection is outside this microbenchmark and remains main-actor work.

The wallpaper and ASCII probe builders emit standalone native sources. Build with `swiftc -O -parse-as-library`; link the wallpaper probe with AppKit, WebKit, AVFoundation, CoreImage, ImageIO, and `work/code-background-target/release/libwebby_code_background.a -lc++`. The ASCII probe needs AppKit/JavaScriptCore and an isolated `.app` resource directory containing `ASCIIArtworks.json`/`ASCIIEngine.js`. Their unused settings typography/transition styling is stubbed; the original timer, decoding/rendering, hide/resume and resize paths run. Counters are injected into temporary test copies only.

`SnapshotLatencyProbe.swift` accepts any URL and an output JSON path. It alternates snapshot modes in ABBA order and records callback latency, dimensions and PNG hashes. It is an experiment, not a shipped preview change.

## Smoothness and power evidence

Actual animation hitches require render-pipeline measurements, not just JavaScript timing. See [Apple's hitch documentation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app). Use Instruments Animation Hitches / Time Profiler on a separate diagnostic run; tracing itself changes timings. Reject traces with lost events, missing target work or unsupported counters. There is no validated total-GPU, battery-life or compositor-FPS claim from the November 1 run.

Visibility suspension follows [WebKit's power guidance](https://webkit.org/blog/8970/how-web-content-can-affect-power-usage/). Preserve HTTP cache policy, profile data-store isolation, active media, dirty/embedded editors, captures, terminal/IDE sessions and user keep-loaded preferences. A soft resident-view target cannot guarantee an absolute memory limit because protected pages and renderer heaps vary.
