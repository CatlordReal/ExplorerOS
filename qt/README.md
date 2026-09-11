# Explorer Link Qt viewer

This optional Qt desktop app controls one local Python simulator child through stdin/stdout. Python remains the authenticated protocol endpoint. Qt renders the 640×360 Glass canvas, connection state, cards, navigation, and input controls.

```sh
cmake -S qt -B qt/build -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt@6
cmake --build qt/build
EXPLOREROS_ROOT="$PWD" PYTHON="$PWD/.venv/bin/python" open qt/build/explorerlink-qt.app
```

Press **Start** to listen on `127.0.0.1:8765`. The generated pairing key appears masked. **Reveal** and **Copy key** are explicit local actions. The key stays in memory, never Qt settings or logs, and clears when the endpoint stops or fails. A key copied by this app is removed on stop only if the clipboard still contains that same key. Each new endpoint generates a fresh key; update companion pairing accordingly.

`EXPLOREROS_ROOT` selects the repository containing `simulator`; `PYTHON` selects an interpreter with `cryptography`. Stopping or closing asks this app's child to quit, waits briefly, then terminates only that child if needed. Process failures and exits update controls and clear session content. Stderr is drained without exposing arbitrary child output. Peer disconnect clears card and navigation data.

All ten Catppuccin/Sand themes are available. Light and Dark preserve a compatible selected theme or choose a readable variant in its family. On Qt 6.5+, System uses `QStyleHints::colorScheme` and reacts to OS appearance changes. Older Qt builds use the platform style's standard palette as a fallback.

**Manual** uses the selected theme. **Clock schedule** uses fixed local-hour phases. **Configured phases** uses the four local times entered below it; these are configured boundaries, not calculated astronomical events. Theme, appearance, switching mode and all four phase times persist. Phases must be ascending; otherwise the manual theme is used and the Switching tooltip explains the invalid order. No location is read. Headings and body text wrap and elide within the canvas.

Qt is a desktop viewer, not Android API 19 firmware. It cannot be flashed to Glass. Loopback is reachable by an iOS simulator on this Mac, not a physical iPhone over Wi-Fi; use a separately configured Python endpoint bound to a suitable local interface for physical-phone testing.

Validation: Qt build passed. An offscreen Qt smoke run exercised generated-key mask/reveal/copy, stop cleanup (canvas and owned clipboard), persisted phase edits and missing-Python failure. A running macOS Qt window was captured and inspected. These checks do not prove Glass hardware behavior.

## Synthetic capture examples

```sh
qt/build/explorerlink-qt.app/Contents/MacOS/explorerlink-qt --demo-output artifacts/qt-demo
```

The output directory must be new. This mode uses Qt's offscreen platform and the
same fragmented JSON event parser and widgets as the running viewer. It writes
640×360 canvas PNGs and full-window PNGs for a notification, note, route, and
cleared disconnected state. All text and connection status are synthetic fixtures;
no Python process, TCP listener, device, clipboard, or saved preferences are used.
These are actual Qt renders, not captures from Android or physical Glass.
