// Draws the MacroSIP app icon and writes packaging/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
//
// Source of truth: packaging/AppIcon.svg (1024 x 1024). The icon is a dial pad whose pressed keys
// trace the letter M: a green vertical gradient (#25CC98 to #07705A) on the standard macOS rounded
// square (824 px of 1024, corner radius 185), three dimmed keys (2, 8, 0), a white 44 px route
// through the other nine keys with round caps and joins, and white 44 px key dots. It is drawn
// here with CoreGraphics at 16...1024 px into an .iconset, then iconutil builds the .icns.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root.appendingPathComponent("packaging/AppIcon.icns").path

// Geometry in SVG units (1024 canvas, y down).
let canvas: CGFloat = 1024
let square = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185
let keyRadius: CGFloat = 44
let strokeWidth: CGFloat = 44
let columns: [CGFloat] = [312, 512, 712]
let rows: [CGFloat] = [290, 438, 586, 734]
let dimmedKeys = [CGPoint(x: 512, y: 290), CGPoint(x: 512, y: 586), CGPoint(x: 512, y: 734)]
let route = [CGPoint(x: 312, y: 734), CGPoint(x: 312, y: 290), CGPoint(x: 512, y: 438),
             CGPoint(x: 712, y: 290), CGPoint(x: 712, y: 734)]
let litKeys: [CGPoint] = columns.flatMap { x in rows.map { y in CGPoint(x: x, y: y) } }
    .filter { p in !dimmedKeys.contains(p) }

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let k = CGFloat(size) / canvas
    // SVG is y-down; CoreGraphics is y-up. Flip once, then draw in SVG units.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: k, y: -k)

    let squarePath = CGPath(roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Shadow (SVG: blur 5, offset 10 down, 30 % black). The context is flipped, so "down" is -y here.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 10, color: CGColor(gray: 0, alpha: 0.3))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(squarePath)
    ctx.fillPath()
    ctx.restoreGState()

    // Vertical gradient, light at the top.
    ctx.saveGState()
    ctx.addPath(squarePath)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0x25 / 255, green: 0xCC / 255, blue: 0x98 / 255, alpha: 1),
                  CGColor(srgbRed: 0x07 / 255, green: 0x70 / 255, blue: 0x5A / 255, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: square.minY), end: CGPoint(x: 512, y: square.maxY), options: [])
    ctx.restoreGState()

    // Dimmed keys.
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.18))
    for p in dimmedKeys {
        ctx.fillEllipse(in: CGRect(x: p.x - keyRadius, y: p.y - keyRadius, width: keyRadius * 2, height: keyRadius * 2))
    }

    // The M route.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: route[0])
    for p in route.dropFirst() { ctx.addLine(to: p) }
    ctx.strokePath()

    // Lit keys.
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for p in litKeys {
        ctx.fillEllipse(in: CGRect(x: p.x - keyRadius, y: p.y - keyRadius, width: keyRadius * 2, height: keyRadius * 2))
    }
    return ctx.makeImage()!
}

// MARK: - Iconset and icns

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "cannot write \(url.path)")
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("MacroSIP-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(render(size: points * scale), to: iconset.appendingPathComponent(name))
}
// A 1024 px preview next to the icns helps reviewing the artwork.
writePNG(render(size: 1024), to: URL(fileURLWithPath: outputPath).deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
try? fm.removeItem(at: work)
print("wrote \(outputPath)")
