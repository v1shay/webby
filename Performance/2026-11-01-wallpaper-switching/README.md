# Wallpaper switching regression fix

The performance pass stopped static wallpaper polling without accounting for changes made while a render was already in flight. Resetting the profile or wallpaper set invalidated the old frame; its completion discarded that frame but never scheduled the newer request. A paused HTML/video first frame could also lack a readiness wakeup.

The fix explicitly resumes the newest pending render when a superseded job completes. A transient timer stays alive during first-frame preparation, including when motion is disabled, and stops after a static/paused frame is ready. Visibility/home-state changes are applied before deciding whether a wakeup is needed. Rendering resolution, effects, glass and profile settings are unchanged.

A native test holds the actual renderer queue with a semaphore while switching profiles and wallpaper-set settings. The old implementation fails both switching assertions cleanly (expected exit 1); the fixed implementation renders the latest requests. Paused HTML and video first frames, GIF resume and resize also pass. Hidden/static/paused backgrounds report zero idle timer callbacks in the focused checks. Tests use isolated signed app bundles and random disposable profile IDs; no production settings are read or changed.

- [Failing old image-switch test](before-images.json)
- [Passing fixed switching/media test](after-full.json)
- [Localized source change](fix.diff)
- [Installation record](installation.json)

Reproduce with `Tests/build_wallpaper_switching_probe.py`, using the same native-probe link libraries as `Tests/PERFORMANCE.md`. Run the emitted executable in a signed isolated app bundle, passing an output directory and `Tests/Fixtures/video.mp4`. Set `WEBBY_WALLPAPER_IMAGES_ONLY=1` for the image-only negative control. The test-only counter measures timer callbacks, not explicit render wakeups.

The signed release was installed without quitting or relaunching Webby. Reopen the app when ready to load the fix.
