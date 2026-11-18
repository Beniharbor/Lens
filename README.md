# Lens

A Mac utility with two jobs:

1. **Copy text from the screen.** Select a screen region like a normal
   screenshot, but instead of an image you get the text inside it, copied
   straight to your clipboard.
2. **A better Downloads stack.** Click Lens in the Dock for a grid of your
   Downloads folder that, unlike the Dock's own stack, lets you select several
   files and drag them all out at once.

Everything runs locally — no network calls, no API keys.

## Copy text from the screen

- Press **⌘⇧2** (or your custom shortcut, set from the menu-bar menu) and drag
  to select a region — same marquee UI as macOS's built-in ⌘⇧4.
- Lens hands that selection to `screencapture -i -c`, reads the resulting
  image off the clipboard, and runs it through Apple's on-device Vision OCR
  (`VNRecognizeTextRequest`).
- The recognized text replaces the image on the clipboard — just ⌘V.
- Press Esc during selection to cancel; nothing gets copied.

### Menu bar icon states

- Lens mark (crop marks + caret, `Sources/Lens/Resources/LensMark.svg`) — idle
- `viewfinder` — selecting a region
- `ellipsis.circle` — recognizing text
- `checkmark.circle.fill` — copied (briefly)
- `exclamationmark.triangle.fill` — nothing recognized / an error (briefly)

## Dock grid

Keep Lens in the Dock (right-click its icon → Options → Keep in Dock), ideally
where the Downloads stack was. Click it to open the grid; click again or press
Esc to close. The first click after Lens launches only starts it. The grid
springs out of the Dock icon and stays anchored to it.

**Selecting and dragging** — Cmd-click, Shift-click, or drag a box around
files, then drag the selection into any app or folder.

**Keyboard**

| Keys | Action |
| --- | --- |
| Return / double-click | Open (a single folder opens inside the grid) |
| ⌘↑, ⌘[, Delete, ‹ button | Back to the parent folder |
| Space | Quick Look |
| ⌘A | Select all |
| ⌘C | Copy the files |
| ⌘⇧C | Copy the text in selected images/PDFs (same OCR as ⌘⇧2) |
| ⌘⌫ | Move to Trash |
| ⌘F, or just start typing | Search the folder by name |
| ⌘- / ⌘+ | Smaller / larger icons |
| Esc | Clear the search, then close |

**Right-click** a file for Open, Open With, Quick Look, Show in Finder, Copy,
Copy Text, Rename, Compress and Move to Trash; right-click empty space for
Open in Finder and Sort By.

**Window** — drag any edge to resize (remembered; reset from the menu-bar
menu). Footer: Small/Medium/Large icons, Open in Finder, and sort order (Date
Added, Date Modified, Name, Kind, Size). The pin button in the header keeps
the grid open while you work in other apps.

**New downloads** — files added since you last opened the grid get a blue dot,
and the Dock icon shows a badge with how many there are.

**Other folders** — menu-bar menu → Dock Grid Folder → Downloads, Desktop,
Documents, or Choose Folder….

The native Dock stack can't be given these features: it has no setting for
multi-selection, and changing the Dock itself would mean disabling System
Integrity Protection. Lens replaces it instead.

## Permissions

- **Screen Recording** — prompted on the first capture (System Settings →
  Privacy & Security → Screen Recording); `screencapture` needs it when
  launched from an app rather than Terminal.
- **Downloads / Desktop / Documents** — macOS asks once per folder the first
  time the grid shows it.

## Build

No Xcode project — Swift Package Manager + manual `.app` bundling.

```sh
Scripts/package.sh                  # build (release) to build/Lens.app
Scripts/package.sh release install  # build, copy to /Applications, relaunch
Scripts/package.sh debug            # debug build
Scripts/make-app-icon.sh            # regenerate Resources/Lens.icns (folder + Lens mark)
```

`Vendor/KeyboardShortcuts` has two local patches so it builds with Command
Line Tools alone: `#Preview` blocks are stripped, and the unused
`globalKeyboardShortcut` modifier is compiled out (`@State` is a macro whose
plugin ships only with Xcode).
