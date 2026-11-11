# Webby Agent

Press **⌘⇧J**, or choose **File → Open Webby Agent**. On a website, the panel slides in beside the page and the shortcut closes it again. Each browser tab keeps its own panel and conversation. Switching tabs hides that panel, and returning restores it. Use **Float Agent** in the panel header to move the same conversation to a separate window, and **Dock to Tab** to return it. On the home screen, Agent opens as a tab. A conversation keeps streaming while its panel is hidden.

The embedded agent works in background tabs and shows progress in the chat. Its tabs carry your selected pet. When you select one, the page gets an outline in your profile’s gradient. The **Agent Tabs** button lets you jump to a tab in another profile or release the markers. The panel uses your pet and thinking animation as it streams.

Stop interrupts the current turn. Paste an image into the composer to attach it. Use Shift-Return for a new line and Return to send.

Codex connects to an already-running server. Its default endpoint is `~/.codex/app-server-control/app-server-control.sock` (under `CODEX_HOME` when set). To use another server that speaks the Codex app-server WebSocket protocol on a Unix socket, launch Webby with `WEBBY_AGENT_SOCKET` set to its absolute socket path. The server must support dynamic tools and the socket must be private to your account.

## Chat controls

Use the **clock** for Chat History and the **gear** for Agent Settings. Chat History searches and pages through chats on Codex-compatible providers. Use the native agent’s history for Antigravity, Cursor, and Claude Code. Webby chats created from this version can resume in place. Open an existing Codex chat to read it, then use **Continue in Webby** to start a separate chat from the loaded messages, or **Open in Codex** to return to the original shared Codex conversation.

**Provider** offers Codex, Antigravity, Cursor, Claude Code, and configured Codex-compatible sockets. Antigravity, Cursor, and Claude Code use their signed-in local CLIs and support text chat and Webby browser actions. Antigravity and Cursor load their model catalogs from the CLI. Claude Code offers Sonnet, Opus, and Haiku aliases. Thinking effort is available when the provider exposes a setting. Glass pickers show the current selection, and longer lists can be filtered by typing. Use the arrow keys and Return to choose an option. **Default Mode** saves Browse or Plan for the current Webby profile. Plan permits Webby’s page inspection tools and asks for a plan.

**Summon Shortcut** changes the in-app toggle. Its default is **⌘⇧J**, and **⌘ + a key** is supported. Type `/` anywhere in a draft to show commands. Keep typing to filter, use ↑ or ↓ to move the highlight, and press Return or Tab to run a command. Escape dismisses suggestions. Use `/agents` or `/provider` for providers, `/model` for models, `/mode` for Browse or Plan, `/effort` for thinking effort, and `/shortcut` for the summon shortcut. Agent replies and loaded assistant messages support Markdown, including tables and formatted code blocks.

## Use Webby from another local agent

Open **Agent Settings** and enable **Local CLI**. **Copy CLI Path** copies a shell-quoted path to the binary bundled with Webby. Use that path in place of `webby` in the examples, or put a symlink named `webby` on your PATH.

```sh
webby help
webby profiles
webby open https://example.com PROFILE_ID webkit
webby tabs
webby wait TAB_ID
webby snapshot TAB_ID
webby click TAB_ID 'button[aria-label="Next"]'
webby fill TAB_ID '#search' 'example'
webby press TAB_ID Enter
webby eval TAB_ID 'document.title'
webby download TAB_ID https://example.com/report.pdf
webby downloads
```

Give a shell-capable agent the CLI path and tell it to start with `webby help`. Commands return one JSON object with `ok` and either `result` or `error`. An error sets a nonzero exit status. `webby json -` takes the same command and arguments as a JSON object on stdin. Use stable IDs from `profiles` and `tabs`. Site engine rules and the profile’s download permissions apply. Navigation and downloads start asynchronously. Use `wait` after navigation and `downloads` for the download ID, status, and path. Use `@active` in place of a tab ID when you want to target the current tab.

`snapshot` returns visible text and CSS selectors from the top-level document. `eval` accepts a JavaScript expression, including an async IIFE, and returns a JSON-compatible value. `press` dispatches a page keyboard event and supports basic Enter-to-submit on forms. Websites can require trusted input for some operations. `screenshot` returns a PNG as base64.

Local CLI is opt-in and uses an account-private Unix socket. It needs no Accessibility or Screen Recording grant. Any local process running as your account can use the CLI while it’s enabled, with access to Webby’s open profile sessions and pages. Disable Local CLI in the Agent tab to close the socket.

## Run the local integration check

Build Webby, then run the fixture with the two app paths. The fixture uses disposable profiles and its own local HTTP server.

```sh
python3 Tests/build_performance_harness.py /tmp/webby-agent-tests
python3 Tests/check-agent.py /tmp/webby-agent-tests/WebbyTests.app ./Webby.app
```
