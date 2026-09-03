// Renders the app icon: a rounded squircle with a dark-to-indigo gradient and
// the SF Symbol microphone, at 1024 px. Run via build-app.sh; output → AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: the artwork sits inside ~82% of the canvas.
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = size * 0.02
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
shadow.set()
NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.20, alpha: 1).setFill()
path.fill()
NSShadow().set()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.24, alpha: 1),
])!
gradient.draw(in: path, angle: -70)

// Subtle top highlight.
let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.width * 0.02),
                             xRadius: rect.width * 0.21, yRadius: rect.width * 0.21)
NSColor.white.withAlphaComponent(0.06).setStroke()
highlight.lineWidth = size * 0.012
highlight.stroke()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: mic.size, flipped: false) { r in
        mic.draw(in: r)
        NSColor.white.setFill()
        r.fill(using: .sourceAtop)
        return true
    }
    let target = NSRect(x: (size - tinted.size.width) / 2, y: (size - tinted.size.height) / 2 + size * 0.01,
                        width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
