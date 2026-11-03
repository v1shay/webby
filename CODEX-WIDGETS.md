Codex Chats replaces the old terminal launcher. Codex Usage is a separate widget.
Both use the normal Webby canvas, glass material, opacity and resize controls.

The running com.openai.codex app supplies the shared daemon's location. Webby
connects natively to app-server-control.sock with an RFC 6455 HTTP upgrade at
/rpc, then masked WebSocket JSON-RPC messages. The raw socket/proxy does NOT
accept newline JSON; the original implementation timed out for that reason.
No proxy/helper process is needed. Connections close after each bounded batch.

Only a missing/refused socket permits fallback to `codex app-server daemon
start`. That command uses Codex's shared daemon startup lock and is idempotent;
it does not create a Webby-specific server. A permissions, identity, handshake
or protocol failure never triggers fallback. No server is stopped, restarted,
updated or bootstrapped. No login, auth.json read, separate model runtime or
HTTP/OpenAI API session is created. The shared daemon is managed by Codex and
is not killed by Webby on exit; other apps may be using it.

One shared coordinator updates both widgets at most once per minute while they
are visible and Webby is active. A private, bounded snapshot provides immediate
cached display. Failed refreshes retain the saved data with its timestamp.
Switching Codex account/workspace clears the old usage windows before updating.
Usage values come from account/rateLimits/read; missing data is never converted
into a fabricated zero-used/100%-remaining allowance.

Recent chats use thread/list on the existing daemon. An optional local fallback
reads only up to 256 indexed metadata candidates from Codex's state_5.sqlite,
returning 32 recent, non-archived parent chats. It is read-only, off the main
actor, uses a short busy timeout, never scans transcripts, and disables itself
if the expected schema/index is absent. It never alters Codex's database.

Choose a chat explicitly before sending. The composer keeps a separate draft
and recipient per Webby profile; Codex chats and usage belong to the shared
Codex app account, not a browser-profile-specific Codex login. Refreshing or
archiving a selected chat never silently chooses a different recipient.

Sending uses thread/queue/add over the private Unix WebSocket. No prompt is passed to a
shell, URL, process arguments or log. After acknowledgment, Webby opens the
installed app's codex://threads/wake/<uuid> and codex://threads/<uuid> links.
The app resumes the queue and owns execution/approvals. Webby never invokes
turn/start, changes a model/sandbox/approval policy, or answers tool requests.
Failures preserve drafts and never automatically retry ambiguous submissions.
The queue/wake integration is based on the installed app's generated protocol
schema and shipped deep-link handler; it may need adaptation for future apps.

The widgets do not start Kai or replace/restart Kai's existing integration.
They use the already available Codex app daemon directly. If it isn't running,
they may start the same shared daemon once, as requested, instead of maintaining
a private runtime. Private stdin-only servers cannot be attached to safely.

Validation: Tests/CodexAppWidgetsChecks.swift covers protocol data fixtures,
usage/null handling, account separation, safe deep links, bounded read-only
SQLite metadata, absent-daemon behavior and persisted offline snapshots. RFC
6455 acceptance/masking/fragment/ping fixtures cover the transport. The native
socket fixture test is Tests/test_codex_socket.py; it never accesses real Codex
or starts agents. Native composer checks are included in the browser harness.
Live socket access/native UI testing were blocked by this session's permissions;
no test prompt was sent to any real chat and live delivery is not yet verified.

If the installed widget only shows local recent chats, run the read-only probe
from a normal Terminal (the coding-agent sandbox may block Codex's private Unix
socket even when Webby has access):

    python3 outputs/diagnose-codex-widgets.py

It reports socket ownership/modes and the failing RPC stage without printing
chat/account contents or credentials. It never starts a server or sends prompts.
The result is saved to work/codex-widget-diagnostic.json. A socket is accepted
when owned by the current user and protected either by its own permissions or
by an owner-only parent directory; default socket mode bits inside Codex's
private daemon directory must not be mistaken for public access.

Install using the user's normal signing key:

    sh outputs/install-codex-widgets.sh

Then relaunch Webby manually. The installer leaves the running app and all
browser profile/sign-in data alone. Never install the ad-hoc preview over the
normal signed app.
