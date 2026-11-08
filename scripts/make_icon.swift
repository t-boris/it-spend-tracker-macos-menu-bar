#!/usr/bin/env swift
// Generates the app icon set with CoreGraphics (no third-party tools).
// Usage: swift scripts/make_icon.swift ITSpendTracker/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

typealias Stop = (hex: UInt32, alpha: CGFloat, at: CGFloat)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [Stop]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { srgb($0.hex, $0.alpha) } as CFArray,
               locations: stops.map { $0.at })!
}

/// Superellipse close to the macOS app-icon "squircle".
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// Draws the icon on a 1024-point canvas (the context is scaled to the requested pixel size).
func drawIcon(_ ctx: CGContext, pixels: Int) {
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Body with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: srgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(srgb(0x14174A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Background: indigo at the top to deep navy at the bottom, with light from above.
    ctx.drawLinearGradient(gradient([(0x6A5CF5, 1, 0), (0x2A2D8F, 1, 0.55), (0x14174A, 1, 1)]),
                           start: CGPoint(x: 330, y: 924), end: CGPoint(x: 700, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.30, 0), (0xFFFFFF, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 640, options: [])

    // Baseline under the bars.
    ctx.setFillColor(srgb(0xFFFFFF, 0.22))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 200, y: 258, width: 624, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.fillPath()

    // Rising monthly bars; older months are dimmer.
    let heights: [CGFloat] = [150, 225, 300, 375]
    let alphas: [CGFloat] = [0.70, 0.82, 0.92, 1.0]
    for (i, height) in heights.enumerated() {
        let rect = CGRect(x: 216 + CGFloat(i) * 158, y: 290, width: 118, height: height)
        let bar = CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: srgb(0x000000, 0.30))
        ctx.addPath(bar)
        ctx.setFillColor(srgb(0x4FD1E8))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(bar)
        ctx.clip()
        ctx.setAlpha(alphas[i])
        ctx.drawLinearGradient(gradient([(0xE6FCFF, 1, 0), (0x4FD1E8, 1, 1)]),
                               start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    // Coin sitting on the tallest bar.
    let center = CGPoint(x: 749, y: 752), radius: CGFloat = 104
    let coin = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: srgb(0x000000, 0.40))
    ctx.addPath(coin)
    ctx.setFillColor(srgb(0xF2A413))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(coin)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFEE9C, 1, 0), (0xF2A413, 1, 1)]),
                           start: CGPoint(x: center.x - radius, y: center.y + radius),
                           end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(srgb(0xB8700A, 0.55))
    ctx.setLineWidth(8)
    ctx.strokeEllipse(in: CGRect(x: center.x - 82, y: center.y - 82, width: 164, height: 164))

    // The "$" mark.
    let font = NSFont.systemFont(ofSize: 134, weight: .heavy)
    let text = NSAttributedString(string: "$", attributes: [.font: font, .foregroundColor: NSColor(cgColor: srgb(0x7A4300, 0.92))!])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    // Thin light rim on the body edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawIcon(ctx, pixels: pixels)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make_icon.swift <AppIcon.appiconset directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(render(pixels: points * scale), to: directory.appendingPathComponent(name))
        entries.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(entries.count) icons to \(directory.path)")
