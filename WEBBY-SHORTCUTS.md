# Webby shortcuts

Webby feature commands use Command–Shift plus a mnemonic letter. Standard browser and editing commands keep their familiar bindings.

| Shortcut | Action |
| --- | --- |
| ⌘⇧F | Toggle Fuse |
| ⌘⇧W | Cycle saved wallpaper pairs |
| ⌘⇧I | New IDE tab (previously ⌘⌥I) |
| ⌘T | New tab; new compact window when Mini Webby is focused |
| ⌘W | Close current browser tab / Mini window |
| ⌘⇧T | Reopen last closed tab |
| ⌘L | Focus address/search; focuses the IDE when its tab is selected |
| ⌘R | Reload web page |
| ⌘F | Find in page / IDE editor |
| ⌘G / ⌘⇧G | Next / previous find match |
| ⌘S | Split with previous tab; save file when IDE is active |
| ⌘1…8 | Select browser tab 1…8 |
| ⌘9 | Select last browser tab |
| ⌃1 / ⌃2 | Switch to first / second profile |
| ⌃Tab / ⌃⇧Tab | Recent-tab switcher, forward / backward; release Control to commit |
| Return / Escape | Accept / cancel recent-tab switcher |
| ⌘\ | Show/hide tabs in either layout; hover the left/top edge to reveal hidden tabs |
| ⌘Y | History |
| ⌘O | Keep Mini page in the main browser |
| ⌥Space | Open Mini Webby globally; configurable in its menu |
| ⌘-click link | Open link in a background tab |
| ⌘⌥-click link | Open link in Mini Webby |
| ⌘Z / ⌘⇧Z | Undo / redo; browser tab-layout undo when content is not editing |
| ⌘X / ⌘C / ⌘V / ⌘A | Cut / copy / paste / select all |
| ⌘Q | Quit Webby |
| Escape | Release game pointer lock; dismiss applicable overlays |
| ⌃C | Interrupt terminal command |

The IDE also provides its workbench command palette (⌘⇧P), quick file opening (⌘P), and debugger commands (F5 / F9 / F10 / F11, subject to macOS function-key settings). Webby's global ⌘⇧F remains reserved for Fuse; use the workbench Search view or command palette for Search in Files. Browser tab-selection and close shortcuts remain browser-owned.

Only Mini Webby's shortcut is currently user-configurable. Other menu actions without an assigned shortcut do not have an undocumented key combination.

Hover the address/search button briefly to reveal the address bar without focusing it. It retreats after you leave; clicking/typing keeps editing active.

Disable automatic link previews under **Tabs & Search → Link Glances on Hover**.

## Rendering engines

- **⇧⌘E** switches the current tab between WebKit and Chromium. A loaded page asks before reloading; an empty tab switches immediately.
- **⌥⇧⌘E** opens a new tab using the other engine.
- Click the search icon in either address field to switch engines.
- Choose **Default Rendering Engine** in Webby Settings to set the engine for new tabs. Existing tabs keep their engine.
- Blue/cyan gradients indicate WebKit; blue/green/yellow/red gradients indicate Chromium. Tab underlines retain the engine color in the background.

Each engine has separate website storage and sign-ins. Switching reloads the URL; unsaved page state does not transfer.
