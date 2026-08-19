// Renders the DMG window background (600x400 pt @2x): an arrow between the
// app-icon and Applications drop positions, plus a caption.
// Usage: swift scripts/render-dmg-background.swift <output.png>
import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 600, height: 400)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = size // 144 dpi so Finder shows it crisp on Retina

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

func drawCentered(_ text: String, at center: NSPoint, attributes: [NSAttributedString.Key: Any]) {
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.size()
    string.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

// Arrow between the two icon slots (icons sit at x=150 and x=450,
// Finder-y 160 from the top => AppKit-y 240 from the bottom).
drawCentered("→", at: NSPoint(x: 300, y: 240), attributes: [
    .font: NSFont.systemFont(ofSize: 64, weight: .light),
    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
])
drawCentered("Drag WindowSwitcher into Applications", at: NSPoint(x: 300, y: 56), attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
])

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("Rendered \(output)")
