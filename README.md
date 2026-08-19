# WindowSwitcher

A window-level `⌘⇥` alternative for macOS. Every window is a card — grouped
by app, in a persistent always-on-top palette.

- **All windows at a glance** — compact grid, apps A→Z, stable layout; pin
  favorite apps to the top
- **Persistent palette** — stays open while you work: hop between windows,
  close them, drag it anywhere; it reopens where you left it
- **Everything switchable** — minimized, fullscreen, other displays, other
  Spaces
- **Native & light** — Swift + AppKit/SwiftUI, event-driven, near-zero idle
  CPU, no screen capture, nothing leaves your Mac

## Install

Requires macOS 14+ (Apple silicon, or build from source).

1. Download the latest [release](https://github.com/WeihangGuo/WindowSwitcher/releases),
   unzip, move to `/Applications`.
2. First open: right-click → **Open** (the app isn't notarized).
3. Grant the Accessibility permission when asked, then press `⌥⇥`.

## Controls

| Input | Action |
|---|---|
| `⌥⇥` | open / close the palette (configurable, never moves selection) |
| `⇥` `⇧⇥` arrows | move selection |
| `↩` or click | switch to window — palette stays open |
| `⌘W` or hover ✕ | close window |
| `⎋` | close the palette (while it has keyboard focus) |

Settings (menu-bar icon → Settings…): custom shortcut, pinned apps, optional
`⌘⇥`-style switch-on-modifier-release mode, column count.

## Build

```bash
scripts/make-app.sh
```

Command Line Tools are enough — no Xcode required.

**Developer note:** builds are ad-hoc signed, so every rebuild invalidates
the Accessibility grant. Reset with
`tccutil reset Accessibility dev.window-manager.WindowSwitcher` and re-grant,
or sign with a stable identity to avoid this entirely.

## License

[MIT](LICENSE)
