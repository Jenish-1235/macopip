# MacoPiP

Picture-in-picture for any macOS window, floating over full-screen apps.
It shows a live, view-only mirror of the window you pin, made with ScreenCaptureKit. Your full-screen app keeps focus the whole time, and you can scroll the pinned window from the PiP.

## Install

You need macOS 14 or later and Xcode, or just the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Jenish-1235/macopip.git
cd macopip
./build.sh --install  # builds, copies MacoPiP.app to ~/Applications and launches it
```

`./build.sh` on its own only builds `build/MacoPiP.app`.

MacoPiP runs in the menu bar. It needs two permissions, each granted once in System Settings → Privacy & Security:

- **Screen & System Audio Recording**, to mirror windows. Grant it on first launch, then quit and reopen MacoPiP.
- **Accessibility**, to scroll the pinned window. MacoPiP asks for it the first time you scroll over a PiP.

If you have an Apple Development certificate, `build.sh` signs with it, and macOS keeps both permissions across rebuilds. Without one, the app is signed ad hoc, and you may need to grant the permissions again after each rebuild.

## Use

| Shortcut | Action |
| --- | --- |
| `⌃⌥P` | Pin or unpin the focused window |
| `⌃⌥O` | Pick a window to pin from a menu at the mouse pointer |
| `⌃⌥H` | Hide or show all PiP windows |
| `⌃⌥J` | Jump to the app of the last pinned window |

In the PiP window:

- Scroll up and down to scroll the real window.
- Drag the middle to move the PiP, and drag an edge to resize it. The aspect ratio stays the same.
- Double-click to jump to the real app.
- Hover to see the close, opacity and jump buttons.

The PiP hides itself while its source app is in front and comes back when you switch away.

### Chrome and other Chromium browsers

Chrome, Brave, Edge, Arc, Vivaldi and Opera pause windows that are hidden behind other apps, which freezes the PiP. When you pin one of their windows, MacoPiP offers to relaunch the browser with `--disable-backgrounding-occluded-windows` and `--restore-last-session`, then re-pins the window. The flag lasts only until the browser is quit, so MacoPiP asks again the next time.

## Limitations

- The PiP is view-only, apart from vertical scrolling. Clicks and typing aren't forwarded.
- Minimized windows can't be mirrored.
- Scroll forwarding uses a private CoreGraphics function (`CGEventSetWindowLocation`), so a future macOS update could break it.
