// Draws the installer's icon (1024 x 1024 PNG): a waveform on a rounded square.
//   swift make-icon.swift <out.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// The macOS icon grid: the shape inset by 100 px, corners of about 22 %
let shape = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
let path = NSBezierPath(roundedRect: shape, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.52, alpha: 1),
                    NSColor(red: 0.48, green: 0.24, blue: 0.78, alpha: 1)])!.draw(in: path, angle: 60)

// The waveform, white
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let white = NSImage(size: symbol.size)
    white.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    white.unlockFocus()
    let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)
    white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
