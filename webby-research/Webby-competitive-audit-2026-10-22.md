# Webby competitive capability audit

**Audit date:** October 22, 2026. **Scope:** the current native AppKit/WKWebView Webby source, not the isolated Chromium prototype. “DLR” is provisionally interpreted as Dia/Arc. This is a broad product-level inventory, not a claim to enumerate every engine API, platform variant, experiment, or future release.

## Executive assessment

Webby has many advanced ideas already. Its competitive deficit is primarily completeness, trust, interoperability, and consistency. Profiles, Fuse, four-pane splits, flexible tabs, widget canvases, terminal/IDE tools, custom backgrounds and motion already exist. Do not spend another cycle rebuilding those as if absent.

The most consequential gaps are dependable recovery and updates, browser essentials, extensions/password-manager compatibility, private browsing/site-data controls, a searchable settings/commands experience, and cross-device continuity. More decorative widgets cannot substitute for those.

“Why people love a browser” below is an interpretation of the product's appeal, not a user-research finding. Official feature descriptions do not establish that a product is faster, universally preferred, or better in every category. No new cross-browser benchmark was performed in this audit.

## Status and priorities

- **Present:** an implementation was located; this does not establish production parity.
- **Partial:** a narrower implementation exists or clear product gaps remain.
- **Missing:** no dedicated user-facing implementation was found in the reviewed source.
- **Unverified:** inherited engine support or behavior needs explicit validation; absence of a host method does not prove absence of support.
- **P0:** baseline trust/reliability or a major daily blocker. **P1:** competitive completeness. **P2:** differentiated/optional work. **Keep/Improve/Protect:** existing capability. **Strategic/Defer:** separate substantial decisions.

## Browser strengths and what Webby should learn

| Browser | Product appeal | Best lessons for Webby |
|---|---|---|
| Dia | Familiar browser plus in-context assistance and polished daily interactions | Context-aware workflows, clear states, restrained chrome and work reduction during tab switching. |
| Arc | Organization and intentional navigation | Predictable spaces, explicit link routing, deliberate previews and recoverable archives. |
| Vivaldi | Deep configurable workflows | Discoverable settings, command chains, saved work arrangements and user control. |
| Chrome | Broad ecosystem and familiar workflows | Compatibility, extensions, resource controls and diagnostics. |
| Safari | Integrated Apple experience | Account separation, device continuity and platform-standard controls; WKWebView alone does not supply Safari's full UI. |
| Firefox | Extensibility and privacy controls | Reading tools, portable data and understandable privacy boundaries. |
| Brave | Privacy defaults with visible controls | Maintained blocking, site exceptions and low-friction recovery when a site breaks. |
| Edge | Work and reading tools | Useful accessibility, PDF/reading workflows and resource visibility. |
| Opera | Built-in convenience tools | Media controls and quick access, while resisting unnecessary feature clutter. |
| Zen | Focused, configurable workspace UI | Compact chrome, workspace organization and intentional link previews. |

These are derived from the official references linked in each matrix section and the source catalog below. Browser features vary by release, OS, plan, and region. Arc's documented sync exclusions matter: it is not a reference for syncing every type of data. Dia's changelog reports phasing out its older Memory feature, so this audit does not propose copying that legacy architecture merely because older marketing still mentions it.

## Capability matrix

### Trust, recovery, and compatibility

Competitor references: [Dia](https://www.diabrowser.com/changelog), [Safari profiles](https://support.apple.com/en-ie/105100), [Vivaldi](https://vivaldi.com/features/). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Release crash/compatibility gate | Partial | P0 | Dia | Keep real command-click, popup, OAuth, downloads, profiles and Fuse regression fixtures; gate releases on them. |
| Renderer-crash recovery UI | Missing | P0 | Product baseline | Handle terminated web content explicitly; offer reload without losing tab identity or account. |
| Crash-safe session journal | Partial | P0 | Product baseline | Current metadata restore is not a transactional recovery journal; persist atomically with generations. |
| Named session snapshots and rollback | Missing | P1 | Vivaldi | Save recoverable workspaces separately from automatic restore. |
| Session fidelity beyond URLs | Partial | P0 | Product baseline | Restore splits, focused panes, tab order and scroll; do not promise preservation of unsaved web-app state. |
| Large-session restoration | Partial | P1 | Product baseline | Current restore caps at 80 pages; replace silent truncation with an explicit scalable policy. |
| Safe signed update pipeline | Missing | P0 | Product baseline | Add authenticated update checks, release channels and rollback; current build script only signs locally. |
| Website compatibility matrix | Unverified | P0 | Product baseline | Test OAuth, payments, conferencing, file upload, fullscreen, pointer lock, accessibility and media. |
| Profile-store isolation audit | Partial | P0 | Safari profiles | Imported profiles get distinct stores on macOS 14+; non-imported profiles currently return the default store. |
| Clear loading/failed/offline/discarded states | Partial | P0 | Dia | Every tab must have a recoverable visible state; renderer death must not become a blank page. |

### Performance and resource management

Competitor references: [Chrome diagnostics](https://support.google.com/chrome/answer/1385029?hl=en), [Chrome performance](https://support.google.com/chrome/answer/12929150?hl=en), [Dia](https://www.diabrowser.com/changelog). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Lazy session restore | Present | Keep | Chrome performance | Already implemented; preserve metadata and cached icons before page loading. |
| Idle-tab discarding | Present | Improve | Chrome performance | Already implemented with form/media exclusions; tune policy against real working sets. |
| Battery-aware resource policy | Missing | P1 | Chrome performance | Reduce optional animations, widget refresh and background activity on battery or Low Power Mode. |
| Inactive-profile resource budgets | Partial | P1 | Dia | Current discard works per tab; prioritize entire inactive profiles without evicting calls or edits. |
| Per-tab CPU/memory task view | Missing | P1 | Chrome diagnostics | Expose measurable resource use where APIs permit; label process estimates honestly. |
| Adaptive memory pressure handling | Partial | P1 | Chrome performance | Existing pressure callbacks discard small batches; tune latency and safety with stress tests. |
| Network preconnect/preload policy | Missing | P2 | Chrome performance | Speculate conservatively only after measuring benefit, memory and privacy cost. |
| Background-work suspension | Partial | P1 | Product baseline | Audit wallpaper/video/widget/preview work when hidden; use engine-supported lifecycle features. |
| Main-thread frame and input budgets | Partial | P0 | Dia | Measure p95/p99 input latency and frame misses in release builds on real hardware. |
| Native row virtualization | Missing | P1 | Product baseline | Current row reuse helps; huge tab sets still need viewport-bounded view counts. |
| Bounded caches and stale-while-refresh widgets | Present | Keep | Product baseline | Favicon and widget caching already exist; maintain invalidation and size limits. |
| Automated cross-browser benchmarks | Missing | P0 | Product baseline | Same machine, pages, warm/cold cache, tab count and power mode; measure startup, memory, energy and scrolling. |

### Everyday browser essentials

Competitor references: [Brave](https://brave.com/features/), [Edge](https://explore.microsoft.com/en-us/edge/features?cat=productivity), [Firefox](https://www.mozilla.org/en-US/firefox/features/). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Private/guest browsing UI and lifecycle | Missing | P0 | Firefox | Use intentionally nonpersistent stores and separate history/credentials; do not confuse profiles with privacy. |
| Third-party extensions | Missing | P1 | Brave | Investigate modern WKWebExtensionController or Chromium; installation and compatibility are substantial work. |
| Password-manager interoperability | Missing | P0 | Brave | Test 1Password/Bitwarden and platform autofill paths; do not assume Safari extensions work in WKWebView. |
| Passwords saved in Keychain | Present | Keep | Product baseline | Current imported/saved credentials use Keychain. |
| Password generation and save/update workflow | Partial | P1 | Firefox | Complete inline suggestions and password-change handling, not just manual filling. |
| Passkeys, security keys and OTP autofill | Unverified | P0 | Edge | WebKit may support parts; audit end-to-end host integration before promising support. |
| Address/contact/payment autofill | Missing | P1 | Edge | Add explicit secure storage, field matching and user control. |
| Reader mode | Missing | P1 | Firefox | Extract readable article content with typography controls. |
| Built-in page translation | Missing | P1 | Firefox | Choose privacy, language coverage and offline behavior deliberately. |
| Read aloud and reading controls | Missing | P2 | Edge | Use accessible speech controls and a clean article view. |
| Per-site zoom and default zoom UI | Missing | P1 | Product baseline | Persist zoom per origin with keyboard/menu controls. |
| Printing and PDF export UI | Missing | P1 | Product baseline | Expose WKWebView printing/PDF capabilities with a native flow. |
| PDF viewer/editor parity | Unverified | P1 | Firefox | Engine display is not a full PDF search, form, annotation and save workflow. |
| Full-page/region screenshot tools | Missing | P2 | Edge | Provide capture, copy, save and optional annotation. |
| Reading list and offline article saving | Missing | P2 | Brave | Separate read-later items from bookmarks. |

### Tabs, workspaces, and navigation

Competitor references: [Arc](https://resources.arc.net/hc/en-us/sections/19211839689111-Organize), [Arc previews](https://resources.arc.net/hc/en-us/sections/19211965457687-Multitask), [Arc routing](https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing), [Dia](https://www.diabrowser.com/changelog), [Firefox](https://www.mozilla.org/en-US/firefox/features/), [Opera](https://help.opera.com/en/latest/features/), [Safari profiles](https://support.apple.com/en-ie/105100), [Vivaldi](https://vivaldi.com/features/), [Zen splits](https://docs.zen-browser.app/user-manual/split-view). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Vertical and horizontal tab layouts | Present | Keep | Vivaldi | Already available; improve overflow, small-window and keyboard behavior. |
| Profiles and Fuse ownership | Present | Protect | Safari profiles | Webby differentiator: mixed visible tabs must retain original sessions and history routing. |
| Independent workspaces inside one account | Partial | P1 | Vivaldi | Separate task organization from cookie/account profiles. |
| Four-pane split layouts and IDE splits | Present | Keep | Zen splits | Already implemented; focus, save and restoration fidelity need continuing tests. |
| Named split/workspace presets | Partial | P1 | Vivaldi | Pins can preserve some split state; add reusable named layouts and restore controls. |
| Tab groups and collapse | Present | Improve | Opera | Keep grouping discoverable; add bulk operations and predictable drag targets. |
| Nested folders and project trees | Missing | P2 | Arc | Offer optional folder organization without forcing a second hierarchy on everyone. |
| Multi-select tabs and bulk actions | Missing | P1 | Opera | Shift/Cmd selection, move, close, group, save and copy URLs. |
| Duplicate-tab discovery and merge | Missing | P1 | Product baseline | Normalize conservatively; never merge different profiles or unsaved forms automatically. |
| Tab renaming and manual labels | Partial | P2 | Vivaldi | Pinned names exist; expose consistent rename for ordinary tabs and split groups. |
| Automatic archive with undo | Missing | P2 | Arc | Keep archival distinct from memory unloading and user closing. |
| Explicit domain-to-profile routing rules | Partial | P1 | Arc routing | Fuse recency routing exists; add visible override rules, previews and account badges. |
| External link and default-browser routing | Missing | P0 | Arc routing | Register and safely handle incoming URLs, profile selection and startup races. |
| Peek/Glance link overlay | Partial | P1 | Arc previews | Hover preview exists; add an intentional interactive overlay with open-as-tab/split controls. |
| Fast recent-tab switcher | Present | Improve | Dia | Already exists; improve previews, keyboard ordering and discoverability. |
| Recently closed tabs | Present | Keep | Product baseline | Cmd-Shift-T exists; add searchable history of closures if useful. |
| Complete bookmark organization | Partial | P1 | Firefox | Current library/import is simpler than folders, tags, editing, export and bulk management. |
| Cross-window tab movement | Missing | P2 | Product baseline | Floating tabs exist; full browser windows and tear-off tab movement are a separate feature. |

### Appearance, interaction, and customization

Competitor references: [Arc](https://resources.arc.net/hc/en-us/sections/19211839689111-Organize), [Dia](https://www.diabrowser.com/changelog), [Vivaldi](https://vivaldi.com/features/), [Vivaldi chains](https://help.vivaldi.com/desktop/shortcuts/command-chains/). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Searchable native Settings window | Missing | P0 | Vivaldi | Grouped status menus are not a searchable settings product; add categories, deep links and reset. |
| Unified command palette | Partial | P1 | Vivaldi chains | Search suggestions and shortcuts exist; index actions, tabs, settings and history together. |
| User-editable shortcut map | Missing | P1 | Vivaldi chains | Add conflict detection, per-context scopes, import/export and reset. |
| Command chains/macros | Missing | P2 | Vivaldi chains | Compose safe browser actions into reusable commands. |
| Editable toolbars and menu layouts | Missing | P2 | Vivaldi | Allow optional controls, reorder and clean presets. |
| Optional mouse gestures | Partial | P2 | Vivaldi chains | Profile swipes exist; customizable action gestures would be separate and off by default. |
| Density, spacing and typography presets | Missing | P1 | Product baseline | Comfortable/compact modes, larger text and consistent click targets. |
| Consistent contrast and focus states | Partial | P0 | Dia | Audit glass, icons, selected tabs and keyboard focus with real content. |
| Profile swipes and interruptible motion | Present | Improve | Dia | Recently implemented; real-device recordings and frame measurements still required. |
| Live tab/page color blending | Partial | P1 | Dia | Current CSS top-edge probe does not sample image/video or full composited pixels. |
| Per-site glass/appearance exceptions | Partial | P1 | Product baseline | Global glass switches exist; add site presets, temporary bypass and one-click recovery. |
| Visual site customization | Partial | P2 | Arc | Global glass is not an editor for per-site fonts, colors, spacing or hidden elements. |
| Theme presets and custom gradients | Present | Keep | Vivaldi | Already implemented; add shareable presets, restore defaults and preview-before-save. |
| Wallpaper and effect composition | Present | Keep | Product baseline | Images, effects and richer backgrounds exist; maintain visibility/power budgets. |
| Resizable widget canvas | Present | Improve | Product baseline | Already implemented; expose clear controls, alignment, recovery and per-profile templates. |
| Reduced-motion support | Present | Keep | Product baseline | Keep cancellation and nonanimated state changes correct. |
| High contrast, VoiceOver and keyboard-only parity | Unverified | P0 | Product baseline | Audit the whole flow, not just individual accessible labels. |
| IME, RTL and localization coverage | Unverified | P1 | Dia | Test composition, multilingual URLs, layout direction and truncated labels. |

### Privacy and security

Competitor references: [Brave](https://brave.com/features/), [Brave Shields](https://brave.com/shields/), [Firefox](https://www.mozilla.org/en-US/firefox/features/), [Firefox isolation](https://support.mozilla.org/en-US/kb/total-cookie-protection-and-website-breakage-faq), [Safari profiles](https://support.apple.com/en-ie/105100). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Maintained blocker lists and exceptions | Partial | P0 | Brave Shields | Current FastRules.json has eight rules; add updates, site exceptions and breakage recovery. |
| Phishing/malware warning coverage | Unverified | P0 | Brave Shields | Determine WebKit defaults and host gaps; do not assume either zero protection or Safari parity. |
| HTTPS-only controls and connection details | Missing | P1 | Brave | Expose upgrades, certificate information and understandable exception handling. |
| Permission enforcement and indicators | Partial | P0 | Product baseline | Camera/mic have native callbacks; several other policies are script-based and need an enforcement audit. |
| Per-site data/cookie/storage manager | Missing | P0 | Firefox isolation | Inspect and clear one site without logging out unrelated profiles. |
| Clear browsing data by type/time/profile | Missing | P0 | Firefox | Separate cache, cookies, history and credentials with clear consequences. |
| Fingerprint/tracker privacy controls | Partial | P1 | Brave Shields | Engine protections are inherited; no demonstrated Brave-equivalent product layer. |
| Tracking-parameter removal | Missing | P2 | Brave | Strip known tracking parameters with site-safe exceptions. |
| Cookie-banner management | Missing | P2 | Brave | Existing Google prompt suppression is not general cookie-consent handling. |
| Profile credential-boundary audit | Partial | P0 | Safari profiles | Test Fuse, splits, moved tabs, popups, downloads and imported cookies. |
| Download provenance and quarantine audit | Unverified | P0 | Product baseline | Verify quarantine metadata, dangerous files, naming and sandbox destination handling. |
| Secure data export/delete controls | Missing | P1 | Product baseline | Give users a way to back up and remove Webby-specific data without touching Chrome. |

### Cross-device and portability

Competitor references: [Dia Chat](https://www.diabrowser.com/download/thanks), [Edge](https://explore.microsoft.com/en-us/edge/features?cat=productivity), [Firefox](https://www.mozilla.org/en-US/firefox/features/). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Encrypted bookmark/history/settings sync | Missing | P1 | Firefox | Design keys, conflict resolution, deletion semantics and account recovery first. |
| Tab handoff and send-to-device | Missing | P2 | Edge | Requires another client or a deliberate bridge, not only a desktop button. |
| Mobile companion | Missing | P2 | Product baseline | Browser or lightweight tab inbox; major separate delivery scope. |
| Windows/Linux clients | Missing | Strategic | Product baseline | Current AppKit UI cannot simply be copied cross-platform. |
| Broad browser import/export | Partial | P1 | Dia Chat | Chrome import exists; add portable bookmarks, sessions and settings export with previews. |
| Sync conflict and recovery UI | Missing | P1 | Product baseline | Required if sync ships; never silently overwrite a profile or tab collection. |

### Downloads, media, and built-in tools

Competitor references: [Edge](https://explore.microsoft.com/en-us/edge/features?cat=productivity), [Opera](https://help.opera.com/en/latest/features/), [Vivaldi](https://vivaldi.com/features/). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Download persistence and Finder reveal | Present | Keep | Product baseline | Already implemented; preserve existing useful Finder-first behavior. |
| Pause/resume/retry download queue | Missing | P1 | Product baseline | Failure callback receives resume data but currently does not retain it. |
| Download destination preferences | Partial | P1 | Product baseline | Add ask-each-time, profile folders and filename collision policy. |
| Native PiP and floating tabs | Present | Improve | Opera | Both exist; distinguish real video PiP from floating the entire tab. |
| Tab mute and centralized media control | Missing | P1 | Edge | Expose playing/capture state and reliable controls without interrupting calls. |
| Conferencing and screen-share robustness | Unverified | P0 | Product baseline | Audit permissions, popup flows, media transitions, display selection and tab unloading exclusions. |
| Native web-app installation/dedicated app windows | Missing | P2 | Product baseline | Specify cookies, notifications, dock identity and external-link behavior. |
| Arbitrary sidebar web panels | Missing | P2 | Vivaldi | Keep quick reference sites accessible without occupying a split pane. |
| Notes, calculator, music, system widgets | Present | Keep | Product baseline | Already implemented; improve consistency instead of duplicating tools. |
| RSS/feed reader | Missing | P2 | Vivaldi | Optional integrated subscriptions, unread state and article view. |
| Full calendar/mail client | Partial | Defer | Vivaldi | Calendar feed widget is not an editable calendar or complete mail client. |
| VPN/proxy service | Missing | Defer | Opera | Operational/security service commitment; not a UI checkbox. |
| Developer inspector and network tooling UI | Missing | P1 | Product baseline | Engine capability is not a discoverable inspector workflow; audit supported public APIs. |
| Embedded terminal and Java IDE | Present | Keep | Product baseline | Existing differentiator; keep resource and permission boundaries explicit. |

### AI and research workflows

Competitor references: [Arc](https://resources.arc.net/hc/en-us/sections/19211839689111-Organize), [Dia](https://www.diabrowser.com/changelog), [Dia Chat](https://www.diabrowser.com/download/thanks). Implementation assessments are from Webby source.

| Capability | Webby | Priority | Reference / benchmark | Recommended action or limitation |
|---|---|---|---|---|
| Page/selection-aware assistant | Missing | P2 | Dia Chat | The Codex launcher is not a browser-context assistant. |
| Multi-tab questions and citations | Missing | P2 | Dia Chat | Extract only chosen tab context with visible citations and account boundaries. |
| Reusable prompts/Skills | Missing | P2 | Dia Chat | Optional saved workflows; give users editing and data-sharing controls. |
| In-place writing/refinement actions | Missing | P2 | Dia Chat | Make changes previewable and undoable; require authorization for external actions. |
| Research collections and visual boards | Missing | P2 | Arc | Collect links, excerpts and captures without adding another permanent sidebar mode. |
| Semantic history/research search | Missing | P2 | Dia | Existing suggestions are lexical; semantic indexing needs opt-in retention and profile isolation. |
| AI execution receipts and controls | Missing | P2 | Dia | If AI ships, show what pages it read and what it changed; treat page content as untrusted. |

## Recommended build order

### 1. Earn daily-driver trust

Build a signed release/recovery pipeline; test website/account compatibility; complete private browsing, site-data clearing, external-link handling, zoom/print, and password/passkey workflows. Establish reliable tab/session recovery. Do not silently migrate existing cookie stores. Any new store-isolation scheme needs backups and an explicit migration plan.

### 2. Make the existing interface coherent

Create one action registry that drives menu items, the command palette, shortcuts, and settings search. Add a native settings window with clear categories, profile/global scope labels, previews, reset, and direct links. Finish bulk tab operations, bookmark management and download retry. Test VoiceOver, keyboard focus, IME, contrast, reduced motion and small-window layouts.

### 3. Measure and improve speed

Use optimized builds on the same hardware and workload as the comparison browsers. Capture input-to-present latency, frame misses, cold/warm launch, navigation responsiveness, memory, energy and idle CPU. Separate cache-warm results from cold results. Test 10, 50 and 200 tabs; Fuse/profile switches; media calls; long editing sessions; large downloads; low memory; laptop battery mode; different display refresh rates. Set regression budgets from baselines rather than promising “zero lag.”

Webby already has safe discarding and cached metadata. Improve those policies before adding speculative preloading that could increase memory, network traffic and privacy exposure. Do not assume engine-level Chromium scheduling features can be recreated with JavaScript timers in WKWebView.

### 4. Decide the ecosystem strategy

Extensions, third-party password managers, sync and platform reach can determine whether people can switch at all. Modern WebKit exposes WKWebExtensionController; this is a real integration route, not automatic Chrome Web Store compatibility. Check deployment targets, API coverage, packaging, permissions, storage, background execution and real extension tests. A Chromium route changes those tradeoffs but adds engine distribution, update, sandbox and maintenance work. The AppKit UI is not a trivial cross-platform port.

### 5. Add differentiators after the baseline

Prioritize explicit profile routing, reusable split/workspace presets, intentional Peek overlays, optional sidebar panels and reader mode. Add browser-context AI only if it solves an actual user workflow. Keep Webby's Fuse/account ownership, glass workspace and embedded tools as the product's identity.

## Appearance principles that would materially improve Webby

1. Use shared spacing, icon, typography, radius, contrast and focus tokens across all controls.
2. Offer a calm default; advanced effects and tools should not compete with page content.
3. Preserve stable geometry while loading; reuse tab icons and existing page content.
4. Keep gestures reversible and interruptible with no queued animation backlog.
5. Make profile/account ownership visible before an action, especially in Fuse and cross-profile splits.
6. Put settings in one searchable home; context menus should expose relevant shortcuts into it.
7. Give every transient state a clear exit: preview, popup, split, floating tab, failed load and widget edit mode.
8. Provide site-specific appearance exceptions: overriding arbitrary third-party CSS will always need escape hatches.

## Features to avoid copying blindly

Full mail clients, VPN services, crypto/reward systems, shopping integrations, social messengers, a second IDE, and multiple overlapping AI systems are not required for Webby to compete. Some suit competitors' audiences; each adds maintenance, privacy, startup, navigation and support costs. Keep optional features unloaded until needed.

## Concrete source findings

- `outputs/BrowserApp.swift`: profile/Fuse navigation, tabs, splits, groups, find, session metadata, unloading, permission policy, native menu and keyboard actions.
- `outputs/ChromeImport.swift`, `BrowserPasswords.swift`, `ChromeSessions.swift`: importer and credential/storage boundaries. The current `BrowserSpace.dataStore` returns `.default()` when `chromeDirectory` is nil; imported profiles use an identifier-backed store on macOS 14+, and fall back to a nonpersistent store on older systems. This is a design/migration risk to audit, not proof of a current observed leak.
- `outputs/FastRules.json`: eight bundled third-party blocking rules, not a demonstrated maintained multi-list blocking product.
- `outputs/BrowserDownloads.swift`: progress, history, collision-safe filenames and Finder reveal; failure resume data is currently ignored.
- `outputs/BrowserPerformance.swift`, `ChromeTone.js`: bounded favicon cache, page-activity tracking and a selected-tab CSS color probe. CSS sampling is not pixel-accurate image/video/gradient matching.
- `outputs/WidgetCanvas.swift`, `CalendarFeed.swift`, `WidgetExtras.swift`, `BrowserWallpaper.swift`: substantial existing canvas, calendar, music and customization work.
- `outputs/Tests`: isolated native browser regression fixtures. These are valuable, but do not establish measured superiority over competing release browsers.
- `outputs/build.sh`: local build/signing flow; no complete authenticated auto-update/notarized distribution pipeline was found here.
- The README contains older behavior descriptions; this audit favors implementation evidence over README claims.

## Evidence limits

This is static source review plus official-source research. It does not establish actual user preference, full compatibility, security certification, real-world extension support, or head-to-head performance. “Missing” means not found in the reviewed Webby host implementation; many web-platform capabilities are inherited from WebKit and need testing rather than being reimplemented. No code, app bundle, cookies, accounts or settings were modified for this research.

## Official source catalog

- [Dia](https://www.diabrowser.com/changelog)
- [Dia Chat](https://www.diabrowser.com/download/thanks)
- [Arc](https://resources.arc.net/hc/en-us/sections/19211839689111-Organize)
- [Arc routing](https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing)
- [Arc previews](https://resources.arc.net/hc/en-us/sections/19211965457687-Multitask)
- [Arc sync](https://resources.arc.net/hc/en-us/articles/20272860828823-Arc-Sync)
- [Vivaldi](https://vivaldi.com/features/)
- [Vivaldi chains](https://help.vivaldi.com/desktop/shortcuts/command-chains/)
- [Chrome performance](https://support.google.com/chrome/answer/12929150?hl=en)
- [Chrome diagnostics](https://support.google.com/chrome/answer/1385029?hl=en)
- [Safari profiles](https://support.apple.com/en-ie/105100)
- [Firefox](https://www.mozilla.org/en-US/firefox/features/)
- [Firefox isolation](https://support.mozilla.org/en-US/kb/total-cookie-protection-and-website-breakage-faq)
- [Brave](https://brave.com/features/)
- [Brave Shields](https://brave.com/shields/)
- [Edge](https://explore.microsoft.com/en-us/edge/features?cat=productivity)
- [Opera](https://help.opera.com/en/latest/features/)
- [Zen](https://zen-browser.app/)
- [Zen splits](https://docs.zen-browser.app/user-manual/split-view)
- [WebKit extensions](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller)

**Inventory size:** 112 capability rows across 9 categories.
