#!/usr/bin/env swift
/// Generates NetWatch.icns using AppKit.
/// Usage: swift make_icon.swift <output_dir>
/// Output: <output_dir>/AppIcon.icns

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/netwatch_icon"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))

    // Background: dark navy gradient
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.05, green: 0.10, blue: 0.22, alpha: 1), // deep navy
            CGColor(red: 0.08, green: 0.18, blue: 0.38, alpha: 1), // mid blue
        ] as CFArray,
        locations: [0, 1]
    )!

    // Rounded rect clip
    let radius = size * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    ctx.drawLinearGradient(gradient,
        start: CGPoint(x: size * 0.2, y: size),
        end:   CGPoint(x: size * 0.8, y: 0),
        options: [])

    // Subtle inner glow ring
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.15))
    ctx.setLineWidth(size * 0.015)
    let inset = size * 0.04
    let glowPath = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
    ctx.addPath(glowPath)
    ctx.strokePath()

    // Draw wifi arcs (3 arcs + dot)
    let cx = size * 0.5
    let cy = size * 0.30    // lower center — arcs fan upward
    let dotR = size * 0.055

    // Draw from largest to smallest so colors overlap correctly
    let arcColors: [CGColor] = [
        CGColor(red: 0.2,  green: 0.6,  blue: 1.0,  alpha: 0.35),
        CGColor(red: 0.35, green: 0.72, blue: 1.0,  alpha: 0.60),
        CGColor(red: 0.55, green: 0.85, blue: 1.0,  alpha: 0.85),
    ]
    let arcRadii: [CGFloat] = [size * 0.40, size * 0.27, size * 0.14]
    let arcWidth = size * 0.055
    // Counterclockwise from ~36° through 90° (top) to ~144° — arcs point UP
    let startAngle: CGFloat = .pi / 5           // ~36°
    let endAngle:   CGFloat = .pi - .pi / 5     // ~144°

    for (i, (r, color)) in zip(arcRadii, arcColors).enumerated() {
        _ = i
        ctx.setStrokeColor(color)
        ctx.setLineWidth(arcWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: cx, y: cy),
                   radius: r,
                   startAngle: startAngle,
                   endAngle: endAngle,
                   clockwise: false)
        ctx.strokePath()
    }

    // Center dot
    let dotGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.6, green: 0.9, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    let dotRect = CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    ctx.drawRadialGradient(dotGradient,
        startCenter: CGPoint(x: cx, y: cy + dotR * 0.3),
        startRadius: 0,
        endCenter:   CGPoint(x: cx, y: cy),
        endRadius:   dotR,
        options: [])

    img.unlockFocus()
    return img
}

// Write PNGs
var pngPaths: [Int: String] = [:]
for size in sizes {
    let img = drawIcon(size: CGFloat(size))
    guard let tiff = img.tiffRepresentation,
          let bmp  = NSBitmapImageRep(data: tiff),
          let png  = bmp.representation(using: .png, properties: [:])
    else { continue }

    let path = "\(outDir)/icon_\(size)x\(size).png"
    try? png.write(to: URL(fileURLWithPath: path))
    pngPaths[size] = path
}

// Build iconset directory for iconutil
let iconsetDir = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let iconsetMap: [(filename: String, size: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for entry in iconsetMap {
    guard let src = pngPaths[entry.size] else { continue }
    let dst = "\(iconsetDir)/\(entry.filename)"
    try? FileManager.default.copyItem(atPath: src, toPath: dst)
}

// Run iconutil to produce .icns
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", "\(outDir)/AppIcon.icns"]
try? proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("✅ Icon written to \(outDir)/AppIcon.icns")
} else {
    print("⚠️  iconutil failed — app will use generic icon")
}
