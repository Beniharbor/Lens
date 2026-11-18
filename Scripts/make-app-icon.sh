#!/bin/bash
# Regenerates Resources/Lens.icns — the blue folder with the Lens mark — from
# the same drawing code the running app uses for its Dock tile (DockIcon.swift),
# so the icon looks the same whether or not Lens is running.
# Re-run after a macOS update changes the system folder artwork.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

let arguments = CommandLine.arguments
let icon = DockIcon.make(mark: NSImage(contentsOfFile: arguments[1]))
let iconset = arguments[2]
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
SWIFT

mkdir "$WORK/Lens.iconset"
swiftc -o "$WORK/render" Sources/Lens/DockIcon.swift "$WORK/main.swift"
"$WORK/render" Sources/Lens/Resources/LensMark.svg "$WORK/Lens.iconset"
iconutil -c icns "$WORK/Lens.iconset" -o Resources/Lens.icns
echo "==> Wrote Resources/Lens.icns"
