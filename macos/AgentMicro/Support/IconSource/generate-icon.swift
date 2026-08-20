#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func color(
    _ red: CGFloat,
    _ green: CGFloat,
    _ blue: CGFloat,
    _ alpha: CGFloat = 1
) -> NSColor {
    NSColor(
        calibratedRed: red / 255,
        green: green / 255,
        blue: blue / 255,
        alpha: alpha
    )
}

private func scaledRect(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    scale: CGFloat
) -> NSRect {
    NSRect(
        x: x * scale,
        y: y * scale,
        width: width * scale,
        height: height * scale
    )
}

private func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "AgentMicroIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create the icon bitmap."]
        )
    }

    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
            domain: "AgentMicroIcon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not create the graphics context."]
        )
    }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    let bodyRect = scaledRect(
        x: 82,
        y: 92,
        width: 860,
        height: 860,
        scale: scale
    )
    let bodyRadius = 190 * scale

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18 * scale),
        blur: 34 * scale,
        color: color(0, 0, 0, 0.34).cgColor
    )
    color(38, 41, 47).setFill()
    NSBezierPath(
        roundedRect: bodyRect,
        xRadius: bodyRadius,
        yRadius: bodyRadius
    ).fill()
    context.restoreGState()

    let faceRect = bodyRect.insetBy(dx: 22 * scale, dy: 22 * scale)
    color(49, 53, 61).setFill()
    let face = NSBezierPath(
        roundedRect: faceRect,
        xRadius: 169 * scale,
        yRadius: 169 * scale
    )
    face.fill()
    color(105, 111, 122, 0.72).setStroke()
    face.lineWidth = max(1, 4 * scale)
    face.stroke()

    let keySize: CGFloat = 142
    let gap: CGFloat = 42
    let gridSize = (keySize * 3) + (gap * 2)
    let gridOriginX = (1024 - gridSize) / 2
    let gridOriginY = (1024 - gridSize) / 2 + 10

    for row in 0..<3 {
        for column in 0..<3 {
            let x = gridOriginX + CGFloat(column) * (keySize + gap)
            let y = gridOriginY + CGFloat(row) * (keySize + gap)
            let shadowRect = scaledRect(
                x: x,
                y: y - 8,
                width: keySize,
                height: keySize,
                scale: scale
            )
            let keyRect = scaledRect(
                x: x,
                y: y,
                width: keySize,
                height: keySize,
                scale: scale
            )
            let radius = 31 * scale

            color(14, 16, 19, 0.48).setFill()
            NSBezierPath(
                roundedRect: shadowRect,
                xRadius: radius,
                yRadius: radius
            ).fill()

            color(210, 214, 221).setFill()
            let key = NSBezierPath(
                roundedRect: keyRect,
                xRadius: radius,
                yRadius: radius
            )
            key.fill()
            color(244, 246, 249, 0.82).setStroke()
            key.lineWidth = max(0.75, 4 * scale)
            key.stroke()

            let inset = 22 * scale
            let highlightRect = keyRect.insetBy(dx: inset, dy: inset)
            color(232, 235, 240, 0.72).setFill()
            NSBezierPath(
                roundedRect: highlightRect,
                xRadius: 17 * scale,
                yRadius: 17 * scale
            ).fill()
        }
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "AgentMicroIcon",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode the icon as PNG."]
        )
    }
    return data
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift APPICONSET_DIRECTORY\n", stderr)
    exit(64)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for variant in variants {
    let destination = outputDirectory.appendingPathComponent(variant.filename)
    try makeIcon(pixels: variant.pixels).write(to: destination, options: .atomic)
}
