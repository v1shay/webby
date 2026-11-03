GitHub widgets share Webby's existing glass material, opacity settings, canvas
movement, resize handle, profile storage and reduced-motion-aware fades.

Add Widget exposes seven separate cards:

- Open PRs: your authored open pull requests, including drafts.
- Contributions: a real GitHub contribution calendar, with recent weeks shown
  when the card is narrow and the yearly total retained.
- Recently Visited: repository visits in that Webby profile, seeded from its
  existing browsing history, capped at 30. No token required.
- Repositories: up to 30 accessible repositories, ordered by latest push.
- Assigned Issues: your assigned open issues.
- Starred Repos: up to 30 most recently starred repositories.
- GitHub Activity: recent events from followed people and watched repositories.
  GitHub's event feed is delayed; it is not a real-time notification stream.

Connect from menu bar → Widgets & Backgrounds → GitHub Connection, or click the
GitHub mark in any card. Tokens stay in macOS Keychain, separately per profile;
they are never injected into pages or saved in defaults, resources or source.
Use a fresh token. A classic token's `repo` scope includes write privileges even
though the widgets only read data. Fine-grained tokens can restrict access to
selected repos with Pull requests, Issues and Starring read permissions as
needed. Contributions come from GraphQL and reflect the token's visibility.
Private organization repositories may require organization approval/SSO.

Snapshots load from disk off the main actor. Lists remain visible while a refresh
runs or fails. Requests deduplicate per profile/card; no more than three host
connections run concurrently. Visible cards refresh at five-minute intervals;
inactive/hidden cards start no polling requests. Failed requests back off, and
rate-limited accounts pause for at least 15 minutes. Native static skeletons
use no shimmer/display-link timers. No per-frame network or disk operations.
Each snapshot is bounded to 600 KB, in a private Application Support directory.
Disconnect clears remote snapshots and cancels their pending requests. Local
visits remain until the browser profile is deleted. Replacing the connection
clears the old account's snapshots before showing the new account.

List cards become compact counters when tiny, single-column lists at ordinary
sizes and two-column lists when wide. View all opens the full GitHub page;
Recently Visited exposes all cached shortcuts through a native menu.

Run `sh outputs/install-github-widgets.sh` from the workspace to build/install
with Webby's normal signing key. The installer leaves the running app alone;
relaunch manually. An ad-hoc preview must not replace the normal signed app.

Validation: Tests/GitHubWidgetsHarness.swift exercises API response decoding,
GraphQL failure handling, graph geometry, URL sanitization, cache persistence,
history seeding, bounded/deduplicated recents, file permissions and isolation.
Authenticated live API access and native visual checks require the user's
connection/desktop and are not covered by those headless fixture checks.
