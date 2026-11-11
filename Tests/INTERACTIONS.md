Run the interaction checks against a built Webby bundle:

```sh
python3 Tests/check-engine-interactions.py popup --app /path/to/Webby.app
python3 Tests/check-engine-interactions.py native --app /path/to/Webby.app
```

The popup check exercises queued navigation while Chromium is opening, an
explicit request superseding a queued destination, and a native popup that
retains the original form POST, `window.opener`, and `window.close()`.

The native check needs an active desktop session. It drags across text and
sends AppKit Edit menu keyboard shortcuts to real WebKit and Chromium views.
It verifies both clipboard data and the edited input, then restores the original
clipboard. Exit 77 means the session did not grant the test app a key window.

Both checks use an isolated copy of the app, temporary profiles, a loopback
fixture server, and CEF's mock keychain.
