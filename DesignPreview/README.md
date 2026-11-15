# Lay X — Design Preview (Glass Studio)

A design preview app for checking how Lay X looks and feels on a real Mac. Mock data only. No MLX inference, downloads, database, file edits or API server.

## How to run

Requirements: macOS 14 or later, Xcode 15.3 or later (Swift 5.9 or later)

```bash
cd DesignPreview
swift run
```

Or open `Package.swift` in Xcode and run with ⌘R.

> When launched with `swift run`, macOS may ask for Input Monitoring permission the first time ⌥Space is used. If the hotkey doesn't respond, open Mini Chat from the "Chat" menu.

## What you can try

| Action | What happens |
|---|---|
| ⌘1–5 / ⌘, | Switch screens (Chat / Work / Models / Performance / API Server / Settings) |
| ⌘N | Start a new chat (empty state) |
| Send ⌘↩ or ⌥1–3 | Stream a mock answer (buffered and flushed every 30 ms) |
| esc | Stop generating |
| ⌘P | Toggle pinning (TEMP badge and sidebar section update) |
| ⌘I | Open/close the Inspector |
| ⌥Space | Show/hide Mini Chat. Return generates an answer, ⌘↩ moves it to the main window, esc dismisses (the chat is discarded unless pinned) |
| Work | Check and uncheck changes. Apply / Reject only show a toast (no files are written) |
| Models | Select a row to update the detail panel; download progress animates |
| Performance | Hover over the chart to see the crosshair and values; ⌘R runs a mock benchmark |
| API Server | Start/Stop; turning on LAN exposure asks for confirmation; add or revoke keys; requests keep arriving |
| Settings | Sliders, segmented controls and toggles are interactive |

## Structure

```
Sources/LayXDesignPreview/
  Theme.swift          Design tokens (color, type, spacing, radius, motion)
  Components.swift     Glass panes, accent glass, buttons, toggles, fields, keycaps, ribbon, code blocks
  MockData.swift       All mock data
  App.swift            App, window setup, AppState (mock streaming)
  RootView.swift       Window layout and sidebar
  ChatScreen.swift     Chat, empty state, composer, Inspector
  WorkScreen.swift     File tree, diff, proposed changes, approval bar
  ModelsScreen.swift   Storage, model table, downloads, details
  PerformanceScreen.swift  KPIs, Swift Charts, comparison table
  APIServerScreen.swift    Status, network, requests, clients, keys
  SettingsScreen.swift     Models & Inference
  MiniChat.swift       NSPanel, Mini Chat view, ⌥Space global hotkey
```

The design specification is in `../design/02-design-system.md`.
