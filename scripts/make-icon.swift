#!/usr/bin/env swift
//
// make-icon.swift — renders Resources/AppIcon.icns.
//
// The icon is generated rather than committed as opaque artwork so it can be
// adjusted by editing values here instead of round-tripping through a design
// tool. Run it with `make icon`; the .icns it produces IS committed, so a
// normal build never has to run this.
//
// WHY THE APP NEEDS AN ICON AT ALL:
// tmux-switcher is an LSUIElement agent, so it has no Dock tile and no
// app-switcher entry — but it is still listed, with its icon, in
// System Settings > General > Login Items and in
// System Settings > Privacy & Security > Accessibility (which every user has
// to visit to grant the permission the app cannot work without). With no
// CFBundleIconFile those lists show a blank generic placeholder, which reads
// as a broken or untrustworthy app precisely where a user is being asked to
// hand over Accessibility access.
//
// Each size is rendered from scratch rather than downsampled from 1024, so
// the 16pt and 32pt variants stay crisp instead of turning to mush.

import AppKit

// Each size is drawn on its own canvas, so all geometry is expressed as a
// fraction of the canvas and scaled up at draw time.
private let iconMargin: CGFloat = 0.098      // macOS squircles sit inset from the canvas
private let cornerRadiusRatio: CGFloat = 0.185

private struct Pill {
    let widthRatio: CGFloat
    let centerY: CGFloat        // fraction of the squircle, 0 = bottom
    let color: NSColor
}

// Three stacked capsules with the middle one lit: the HUD's own shape
// language, which is what the app actually draws. The accent is tmux's status
// green, so the icon reads as "a tmux thing" at a glance.
private let pills: [Pill] = [
    Pill(widthRatio: 0.44, centerY: 0.745, color: NSColor(calibratedWhite: 1.0, alpha: 0.28)),
    Pill(widthRatio: 0.62, centerY: 0.500, color: NSColor(calibratedRed: 0.38, green: 0.85, blue: 0.45, alpha: 1.0)),
    Pill(widthRatio: 0.44, centerY: 0.255, color: NSColor(calibratedWhite: 1.0, alpha: 0.28)),
]

private func drawIcon(into context: CGContext, canvas: CGFloat) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = canvas * iconMargin
    let side = canvas - inset * 2
    let box = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * cornerRadiusRatio

    // --- Background squircle -------------------------------------------------
    let squircle = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0).cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: box.minX, y: box.maxY),
        end: CGPoint(x: box.minX, y: box.minY),
        options: []
    )
    context.restoreGState()

    // A hairline highlight along the top edge keeps the shape from reading as
    // a flat black slab on a dark desktop.
    context.saveGState()
    context.addPath(squircle)
    context.setLineWidth(max(1.0, canvas * 0.004))
    context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.14).cgColor)
    context.strokePath()
    context.restoreGState()

    // --- Session pills -------------------------------------------------------
    let pillHeight = side * 0.118
    for pill in pills {
        let width = side * pill.widthRatio
        let rect = CGRect(
            x: box.midX - width / 2,
            y: box.minY + side * pill.centerY - pillHeight / 2,
            width: width,
            height: pillHeight
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: pillHeight / 2,
            cornerHeight: pillHeight / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(pill.color.cgColor)
        context.fillPath()
    }
}

private func renderPNG(canvas: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvas,
        pixelsHigh: canvas,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    drawIcon(into: graphicsContext.cgContext, canvas: CGFloat(canvas))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(canvas)px PNG\n".utf8))
        exit(1)
    }
    return data
}

// --- Entry point -------------------------------------------------------------

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

// The names iconutil expects; anything else is silently ignored by it.
let variants: [(file: String, canvas: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    let data = renderPNG(canvas: variant.canvas)
    let path = "\(outputDirectory)/\(variant.file)"
    guard FileManager.default.createFile(atPath: path, contents: data) else {
        FileHandle.standardError.write(Data("failed to write \(path)\n".utf8))
        exit(1)
    }
}

print("rendered \(variants.count) variants into \(outputDirectory)")
