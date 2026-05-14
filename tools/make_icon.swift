// make_icon.swift — produce Resources/AppIcon.icns from a 🚲 emoji passed
// through CICrystallize.
//
// Run once and commit the resulting .icns:
//   swift tools/make_icon.swift
//
// The emoji is rendered onto a rounded-square dark background at 1024×1024,
// passed through CICrystallize (a Voronoi-cell mosaic), then downsampled
// into every iconset size. iconutil compiles the iconset into AppIcon.icns
// next to Resources/.
//
// "For now" placeholder — design is intentionally simple. Replace with a
// proper icon when one's commissioned.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let canvasPx: CGFloat = 1024
let cornerRadiusFraction: CGFloat = 0.225  // ~macOS Big Sur app icon shape
let crystallizeRadius: Double = 36         // larger = chunkier facets
let emoji = "🚲"

// Resolve paths relative to the project root (the script's grandparent dir).
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")
let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// MARK: - Step 1: render emoji on a rounded dark background at native canvas

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let ctx = CGContext(
    data: nil,
    width: Int(canvasPx), height: Int(canvasPx),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: bitmapInfo.rawValue
) else {
    fatalError("could not create CGContext")
}

// Background: subtle dark-teal gradient inside a rounded square. The
// gradient gives CICrystallize more variation to fragment, which reads
// better post-filter than a flat color.
let bgRect = CGRect(x: 0, y: 0, width: canvasPx, height: canvasPx)
let cornerR = canvasPx * cornerRadiusFraction
ctx.saveGState()
let bgPath = CGPath(
    roundedRect: bgRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil
)
ctx.addPath(bgPath); ctx.clip()

let gradColors = [
    NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.13, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.30, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: canvasPx),
    end: CGPoint(x: canvasPx, y: 0),
    options: []
)
ctx.restoreGState()

// Emoji centered. NSGraphicsContext bridges into a CGContext for the
// AppKit text-drawing APIs we need to render Apple Color Emoji glyphs.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

let style = NSMutableParagraphStyle()
style.alignment = .center
let emojiFont = NSFont(name: "Apple Color Emoji", size: canvasPx * 0.78)
    ?? NSFont.systemFont(ofSize: canvasPx * 0.78)
let attrs: [NSAttributedString.Key: Any] = [
    .font: emojiFont,
    .paragraphStyle: style,
]
let attrStr = NSAttributedString(string: emoji, attributes: attrs)
let glyphSize = attrStr.size()
// Slight downward bias — the emoji glyph isn't perfectly vertically centered
// inside its bounding box.
let drawRect = CGRect(
    x: 0,
    y: (canvasPx - glyphSize.height) / 2 - canvasPx * 0.025,
    width: canvasPx,
    height: glyphSize.height
)
attrStr.draw(in: drawRect)
NSGraphicsContext.restoreGraphicsState()

guard let baseCG = ctx.makeImage() else {
    fatalError("could not snapshot CGContext")
}

// MARK: - Step 2: crystallize

let ciInput = CIImage(cgImage: baseCG)
let crystal = CIFilter.crystallize()
crystal.inputImage = ciInput
crystal.radius = Float(crystallizeRadius)
crystal.center = CGPoint(x: canvasPx / 2, y: canvasPx / 2)
guard let ciOut = crystal.outputImage?.cropped(to: ciInput.extent) else {
    fatalError("CICrystallize produced no output")
}

// Re-clip to the rounded-square mask so the crystallize doesn't paint
// outside the icon's silhouette.
let ciContext = CIContext(options: [.useSoftwareRenderer: false])
guard let crystalCG = ciContext.createCGImage(ciOut, from: ciInput.extent) else {
    fatalError("could not flatten crystallized CIImage to CGImage")
}

let maskCtx = CGContext(
    data: nil,
    width: Int(canvasPx), height: Int(canvasPx),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: bitmapInfo.rawValue
)!
maskCtx.saveGState()
maskCtx.addPath(bgPath); maskCtx.clip()
maskCtx.draw(crystalCG, in: bgRect)
maskCtx.restoreGState()
guard let finalCG = maskCtx.makeImage() else {
    fatalError("could not produce final masked image")
}

// MARK: - Step 3: write each iconset size

func writePNG(_ image: CGImage, at size: Int, name: String) throws {
    let dst = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: bitmapInfo.rawValue
    )!
    dst.interpolationQuality = .high
    dst.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = dst.makeImage() else {
        throw NSError(domain: "make_icon", code: 1)
    }
    let bitmapRep = NSBitmapImageRep(cgImage: scaled)
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 2)
    }
    try pngData.write(to: iconsetDir.appendingPathComponent("icon_\(name).png"))
    print("  wrote icon_\(name).png (\(size)px)")
}

// Apple's iconset spec for .icns. Each pair of (logical, @2x) ensures
// retina rendering at every Dock / Finder size.
let entries: [(logical: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]
for (logical, scale) in entries {
    let pixels = logical * scale
    let suffix = scale == 1 ? "" : "@2x"
    try writePNG(finalCG, at: pixels, name: "\(logical)x\(logical)\(suffix)")
}

// MARK: - Step 4: iconutil into .icns

let iu = Process()
iu.launchPath = "/usr/bin/iconutil"
iu.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]
try iu.run()
iu.waitUntilExit()
guard iu.terminationStatus == 0 else {
    fatalError("iconutil failed with exit code \(iu.terminationStatus)")
}

print("wrote \(icnsPath.path)")
