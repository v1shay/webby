# Code background engine

Source: /Users/vishayagarwal/Documents/ChatGPT/rust-agents/src/background.rs
Snapshot SHA256: 444d66aa6a7800bf44a90994d451a37be70434b440061382ac154e5063c3c9d2

`src/effects.rs` retains Code's resize, pixel effects, Haze, haze sampling, and smootherstep functions verbatim. Code ports the dark-theme effects from MonoCode commit 889579b61c2342cc27751092ff0effbe9ec8e162 (Copyright 2026 Nick, MIT; license retained here). `upstream/background.rs` preserves the complete source workflow as a reference. Webby's C ABI, directional fade extension, AppKit settings, managed media storage, asynchronous renderer, and AVFoundation video host are integration code. No GPUI or private native APIs are used.
