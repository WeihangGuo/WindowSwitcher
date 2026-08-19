# WindowSwitcher

A lightweight, window-level alternative to the macOS `⌘⇥` switcher. Where
`⌘⇥` shows one icon per application, WindowSwitcher shows **every switchable
window** as its own card, grouped by application. Apps are sorted
alphabetically (windows within an app by title) so every window has a stable,
predictable place — but the selection starts on your *previous* window, so a
quick open-and-`↩` still toggles between your two most recent windows.

Native Swift + AppKit + SwiftUI. No Electron, no web views, no polling —
near-zero CPU while idle.

## Using it

- Press **`⌥⇥`** (configurable) to open the switcher — no need to keep
  holding anything. The panel is a persistent overlay: it floats above every
  window, follows you across Spaces, and clicking into other apps does NOT
  dismiss it.
- Move through the grid with plain `⇥` / `⇧⇥` or the arrow keys.
- Press `↩` or click a card to switch to that window — **the palette stays
  open**, so you can hop between windows from it. It closes only when you
  press the shortcut again (a toggle — it never moves the selection) or
  press `⎋` while the palette has keyboard focus.
- **`⌘W`** closes the selected window (or click the ✕ that appears when
  hovering a card) — the switcher stays open so you can close several in
  a row.
- Pointer: hover to highlight, click to activate, scroll when the list is
  long. Drag the panel by the grip pill at its top (or any empty area) —
  it reopens where you left it.
- Prefer the `⌘⇥` model instead? Enable **"Switch on modifier release"** in
  Settings — then releasing `⌥` activates the selection, re-pressing the
  shortcut cycles, and a quick tap of `⌥⇥` bounces to the previous window.
- Minimized windows are restored before being focused; windows on other
  displays and Spaces are switched to automatically.

The menu-bar icon (⧉) gives you **Open Switcher**, **Settings…** and
**Quit**. Settings offers: a shortcut recorder (click the shortcut, press a
new combination), the sticky vs release-to-activate behavior toggle,
**pinned apps** (always listed before the alphabetical rest), and a manual
column-count override.

## Building

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode not needed).

```bash
scripts/make-app.sh
open build/WindowSwitcher.app
```

`swift build` alone produces a bare executable; the script wraps it into
`build/WindowSwitcher.app` with the proper `Info.plist` (background app, no
Dock icon) and an ad-hoc code signature.

## Accessibility permission

WindowSwitcher needs the macOS **Accessibility** permission to enumerate
windows, read their titles, and raise the one you pick. First launch opens an
onboarding window that links to
*System Settings → Privacy & Security → Accessibility* and detects the grant
live — no restart needed. No other permission is requested; no screen
contents are captured.

**Developer note:** the app is ad-hoc signed, so *every rebuild changes the
code hash and silently invalidates the TCC grant*. The Accessibility checkbox
will still look enabled while `AXIsProcessTrusted()` returns false, and the
system prompt will not reappear. Fix by removing WindowSwitcher from the
Accessibility list and re-adding it, or:

```bash
tccutil reset Accessibility dev.window-manager.WindowSwitcher
```

## Architecture

| Piece | Role |
|---|---|
| `WindowStore` | Event-driven window cache: `NSWorkspace` notifications + one `AXObserver` per app. All AX reads on a background queue with a global 0.5 s messaging timeout; hung apps are quarantined with backoff. |
| `SwitcherController` | The interaction session: non-activating key panel, release-to-activate, fast-tap, hold-to-cycle, single teardown path for every exit. |
| `HotkeyManager` | Carbon `RegisterEventHotKey` (no event tap, zero idle cost, works during secure input). |
| `WindowActivator` | Unminimize → raise → activate → verify-and-re-raise. |
| `SwitcherView` | SwiftUI grid in an `NSVisualEffectView` panel; light/dark automatic. |

### Why a cache instead of enumerate-on-open

`kAXWindowsAttribute` only returns windows on the **current** Space (plus
minimized windows). Windows on other Spaces — including fullscreen windows,
which live on their own Space — are invisible to fresh AX enumeration, but a
*cached* `AXUIElement` stays valid and raisable across Space changes. So the
store enumerates on launch, app launch, and every Space change; reconciles
non-destructively when the switcher opens (using the all-Spaces
`CGWindowList` as liveness ground truth); and back-fills cold-start windows
on unvisited Spaces via a feature-detected private API
(`_AXUIElementCreateWithRemoteToken`, the technique AltTab uses). If that SPI
ever disappears, the app degrades gracefully instead of crashing.

## Known limitations (v0.1)

- If the Dock setting *"When switching to an application, switch to a Space
  with open windows"* is disabled, macOS may not jump to another Space when
  activating a window there.
- `⌘⇥` itself cannot be used as the shortcut (the Dock consumes it first);
  the recorder rejects it. The `fn`/Globe key is not supported as a modifier.
- Accessibility text size does not yet influence the automatic column count.
- Windows of apps that expose no usable Accessibility interface (rare) cannot
  be listed.
