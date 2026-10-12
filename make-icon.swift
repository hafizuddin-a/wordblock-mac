import AppKit
// Regenerates WordBlock.icns: swiftc make-icon.swift -o /tmp/icongen && /tmp/icongen /tmp/WordBlock.iconset && iconutil -c icns /tmp/WordBlock.iconset -o WordBlock.icns

// Rounded dark square, a white keycap with a "W", and a red slash through it ("blocked key").
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let bg = NSBezierPath(roundedRect: NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88), xRadius: s*0.2, yRadius: s*0.2)
    NSGradient(starting: NSColor(red: 0.22, green: 0.26, blue: 0.40, alpha: 1), ending: NSColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1))!.draw(in: bg, angle: -90)

    let cap = NSRect(x: s*0.22, y: s*0.24, width: s*0.56, height: s*0.52)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s*0.025); shadow.shadowBlurRadius = s*0.04; shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: cap, xRadius: s*0.1, yRadius: s*0.1).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let font = NSFont.systemFont(ofSize: s*0.34, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(red: 0.12, green: 0.14, blue: 0.24, alpha: 1)]
    let str = NSAttributedString(string: "W", attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: cap.midX - sz.width/2, y: cap.midY - sz.height/2))

    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: s*0.20, y: s*0.80)); slash.line(to: NSPoint(x: s*0.80, y: s*0.20))
    slash.lineWidth = s*0.075; slash.lineCapStyle = .round
    NSColor(red: 0.93, green: 0.26, blue: 0.27, alpha: 1).setStroke()
    slash.stroke()
    img.unlockFocus()

    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
