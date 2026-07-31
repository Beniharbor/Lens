# Lens

A menu-bar utility: select a screen region like a normal screenshot, but
instead of an image you get the text inside it, copied straight to your
clipboard.

## How it works

- Press **⌘⇧2** (or your custom shortcut, set from the menu) and drag to
  select a region — same marquee UI as macOS's built-in ⌘⇧4.
- Lens hands that selection to `screencapture -i -c`, reads the resulting
  image off the clipboard, and runs it through Apple's on-device Vision
  OCR (`VNRecognizeTextRequest`).
- The recognized text replaces the image on the clipboard — just ⌘V.
- Press Esc during selection to cancel; nothing gets copied.

Everything runs locally via the Vision framework — no network calls, no API
keys.

## Menu bar icon states

- Lens mark (crop marks + caret, `Resources/LensMark.svg`) — idle
- `viewfinder` — selecting a region
- `ellipsis.circle` — recognizing text
- `checkmark.circle.fill` — copied (briefly)
- `exclamationmark.triangle.fill` — nothing recognized / an error (briefly)

## First run

macOS will prompt for **Screen Recording** permission the first time you
capture (System Settings → Privacy & Security → Screen Recording). This is
required for `screencapture` to work when launched from an app rather than
Terminal.

## Build

No Xcode project — Swift Package Manager + manual `.app` bundling.

```sh
Scripts/package.sh                  # build (release) to build/Lens.app
Scripts/package.sh release install  # build, copy to /Applications, relaunch
Scripts/package.sh debug            # debug build
```
