#!/usr/bin/env swift
// Generates a macOS AppIcon.appiconset with a plain "P" monogram.
// Usage (from the repository root): swift Tools/make-app-icon.swift App/Assets.xcassets
import AppKit

let arguments = CommandLine.arguments
let catalog = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "App/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
let fileManager = FileManager.default
try fileManager.createDirectory(at: iconSet, withIntermediateDirectories: true)

let catalogContents = catalog.appendingPathComponent("Contents.json")
if !fileManager.fileExists(atPath: catalogContents.path) {
    let info: [String: Any] = ["info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: catalogContents)
}

func renderPNG(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw CocoaError(.fileWriteUnknown)
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(pixels)
    let inset = side * 0.1
    let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    NSColor(calibratedRed: 0.11, green: 0.30, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22).fill()
    let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .bold)
    let letter = NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor.white])
    let letterSize = letter.size()
    letter.draw(at: NSPoint(x: rect.midX - letterSize.width / 2, y: rect.midY - letterSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try renderPNG(pixels: size * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconSet.path)")
