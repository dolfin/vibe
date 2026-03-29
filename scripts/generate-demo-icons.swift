#!/usr/bin/swift
/// Generates 512×512 app icons for demo packages.
/// Usage: swift scripts/generate-demo-icons.swift

import AppKit
import Foundation

struct IconSpec {
    let symbol: String
    let background: NSColor
    let output: String
}

let specs: [IconSpec] = [
    IconSpec(
        symbol: "checklist",
        background: NSColor(srgbRed: 0.06, green: 0.62, blue: 0.35, alpha: 1),   // emerald
        output: "examples/nodejs-todo/assets/icon.png"
    ),
    IconSpec(
        symbol: "note.text",
        background: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.08, alpha: 1),   // amber
        output: "examples/sqlite-notes/assets/icon.png"
    ),
    IconSpec(
        symbol: "bubble.left.and.bubble.right.fill",
        background: NSColor(srgbRed: 0.38, green: 0.33, blue: 0.93, alpha: 1),   // violet
        output: "examples/ws-chat/assets/icon.png"
    ),
]

let size = 512

for spec in specs {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let sz = CGFloat(size)
    let cgCtx = ctx.cgContext

    // Rounded-rect background (iOS icon shape: radius ≈ 22.37% of size)
    let radius = sz * 0.2237
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: sz, height: sz),
        cornerWidth: radius, cornerHeight: radius,
        transform: nil
    )
    cgCtx.addPath(bgPath)
    cgCtx.setFillColor(spec.background.cgColor)
    cgCtx.fillPath()

    // SF Symbol — white, centered, ~42% of icon size
    let pointSize = sz * 0.42
    let symConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symImage = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(symConfig) {
        let symSize = symImage.size
        let origin = NSPoint(
            x: (sz - symSize.width) / 2,
            y: (sz - symSize.height) / 2
        )
        symImage.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    // Write PNG
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("❌ Failed to encode PNG for \(spec.output)")
        continue
    }
    let url = URL(fileURLWithPath: spec.output)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    do {
        try pngData.write(to: url)
        print("✅ \(spec.output)")
    } catch {
        print("❌ \(spec.output): \(error)")
    }
}
