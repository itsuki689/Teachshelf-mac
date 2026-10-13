#!/usr/bin/env swift
import AppKit
import Foundation

// Vector drawing keeps every icon size crisp without a third-party dependency.
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func roundRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func stroke(_ from: NSPoint, _ to: NSPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: from)
    path.line(to: to)
    color.setStroke()
    path.stroke()
}

func drawIcon() {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    NSGradient(starting: color(0xFFFCF6), ending: color(0xEAE6D9))!.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let tileBorder = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 190, yRadius: 190)
    tileBorder.lineWidth = 3
    NSColor.white.withAlphaComponent(0.70).setStroke()
    tileBorder.stroke()

    NSGraphicsContext.saveGraphicsState()
    let shelfShadow = NSShadow()
    shelfShadow.shadowColor = color(0x234B47).withAlphaComponent(0.18)
    shelfShadow.shadowBlurRadius = 30
    shelfShadow.shadowOffset = NSSize(width: 0, height: -24)
    shelfShadow.set()
    roundRect(NSRect(x: 219, y: 269, width: 586, height: 46), radius: 17, fill: color(0x235D58))
    NSGraphicsContext.restoreGraphicsState()

    // Left book: deep teal cloth spine, a paper cap, and two gold title rules.
    roundRect(NSRect(x: 258, y: 314, width: 149, height: 409), radius: 19, fill: color(0xE5DFCF))
    roundRect(NSRect(x: 251, y: 305, width: 139, height: 416), radius: 18, fill: color(0x286D64))
    roundRect(NSRect(x: 251, y: 305, width: 21, height: 416), radius: 10, fill: color(0x1F5D56))
    stroke(NSPoint(x: 296, y: 641), NSPoint(x: 348, y: 641), color: color(0xD4DAB8), width: 10)
    stroke(NSPoint(x: 296, y: 610), NSPoint(x: 334, y: 610), color: color(0xD4DAB8), width: 7)
    stroke(NSPoint(x: 291, y: 346), NSPoint(x: 353, y: 346), color: color(0x9ABCAE), width: 5)

    // Tall central book: warm ochre, set slightly forward.
    roundRect(NSRect(x: 443, y: 315, width: 144, height: 484), radius: 19, fill: color(0xFAF6E8))
    roundRect(NSRect(x: 428, y: 305, width: 140, height: 490), radius: 18, fill: color(0xD5AA63))
    roundRect(NSRect(x: 428, y: 305, width: 22, height: 490), radius: 10, fill: color(0xC79851))
    roundRect(NSRect(x: 466, y: 590, width: 67, height: 120), radius: 6, fill: color(0xF8EBCB))
    stroke(NSPoint(x: 482, y: 680), NSPoint(x: 519, y: 680), color: color(0xB18F53), width: 6)
    stroke(NSPoint(x: 482, y: 657), NSPoint(x: 508, y: 657), color: color(0xB18F53), width: 5)
    stroke(NSPoint(x: 467, y: 346), NSPoint(x: 530, y: 346), color: color(0xF0DCB4), width: 5)

    // A leaning coral book makes the silhouette distinct at Dock sizes.
    NSGraphicsContext.saveGraphicsState()
    let tilted = NSAffineTransform()
    tilted.translateX(by: 628, yBy: 308)
    tilted.rotate(byDegrees: 12)
    tilted.concat()
    roundRect(NSRect(x: 8, y: 9, width: 132, height: 375), radius: 18, fill: color(0xF7EFDE))
    roundRect(NSRect(x: 0, y: 0, width: 127, height: 375), radius: 17, fill: color(0xBC7060))
    roundRect(NSRect(x: 0, y: 0, width: 19, height: 375), radius: 9, fill: color(0xAB6153))
    stroke(NSPoint(x: 40, y: 296), NSPoint(x: 87, y: 296), color: color(0xFFE2C3), width: 8)
    stroke(NSPoint(x: 40, y: 270), NSPoint(x: 74, y: 270), color: color(0xFFE2C3), width: 6)
    stroke(NSPoint(x: 36, y: 41), NSPoint(x: 92, y: 41), color: color(0xDEAA90), width: 5)
    NSGraphicsContext.restoreGraphicsState()

    // Shelf lip lies in front of the books, with a soft highlight.
    roundRect(NSRect(x: 219, y: 271, width: 586, height: 48), radius: 16, fill: color(0x28655E))
    stroke(NSPoint(x: 238, y: 309), NSPoint(x: 786, y: 309), color: color(0x609087), width: 4)
}

let resources = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TeachshelfIcon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let chunkTypes = ["16-1": "icp4", "16-2": "ic11", "32-1": "icp5", "32-2": "ic12",
                  "128-1": "ic07", "128-2": "ic13", "256-1": "ic08", "256-2": "ic14",
                  "512-1": "ic09", "512-2": "ic10"]
var chunks = Data()
func bigEndianLength(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let destination = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: destination)
        chunks.append(chunkTypes["\(size)-\(scale)"]!.data(using: .ascii)!)
        chunks.append(bigEndianLength(png.count + 8))
        chunks.append(png)
        if pixels == 1024 {
            try png.write(to: resources.appendingPathComponent("AppIcon.png"))
        }
    }
}

// The ICNS container stores the original PNG representations without recompression.
var icns = "icns".data(using: .ascii)!
icns.append(bigEndianLength(chunks.count + 8))
icns.append(chunks)
let iconURL = resources.appendingPathComponent("AppIcon.icns")
try icns.write(to: iconURL)
guard let icon = NSImage(contentsOf: iconURL), !icon.representations.isEmpty else {
    fatalError("生成的图标无法由 AppKit 读取。")
}
print("已生成 \(iconURL.path)，包含 \(icon.representations.count) 个尺寸。")
