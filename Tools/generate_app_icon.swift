#!/usr/bin/env swift
// Renders the 1024x1024 app icon: a rising bar chart with a spark on a deep green gradient.
// Usage: swift Tools/generate_app_icon.swift FinSightAI/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let gradient = CGGradient(
    colorsSpace: space,
    colors: [color(0.05, 0.36, 0.30), color(0.02, 0.16, 0.20)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

let heights: [CGFloat] = [210, 320, 440, 580]
let barWidth: CGFloat = 130
let gap: CGFloat = 48
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (1024 - totalWidth) / 2
let baseline: CGFloat = 200
for (index, height) in heights.enumerated() {
    let rect = CGRect(x: x, y: baseline, width: barWidth, height: height)
    let alpha = 0.55 + 0.15 * CGFloat(index)
    context.setFillColor(color(0.62, 0.95, 0.80, min(alpha, 1)))
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 38, cornerHeight: 38, transform: nil))
    context.fillPath()
    x += barWidth + gap
}

// Four-point spark above the tallest bar.
let center = CGPoint(x: x - barWidth / 2 - gap, y: baseline + heights.last! + 95)
let spark = CGMutablePath()
let outer: CGFloat = 88, inner: CGFloat = 22
for point in 0..<8 {
    let angle = CGFloat(point) * .pi / 4 - .pi / 2
    let radius = point % 2 == 0 ? outer : inner
    let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    point == 0 ? spark.move(to: p) : spark.addLine(to: p)
}
spark.closeSubpath()
context.setFillColor(color(1, 1, 1))
context.addPath(spark)
context.fillPath()

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
