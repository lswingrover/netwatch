#!/usr/bin/env swift
/// Generates NetWatch.icns using AppKit.
/// Usage: swift make_icon.swift <output_dir>
/// Output: <output_dir>/AppIcon.icns
///
/// Design: deep navy gradient background (same family as MacWatch), white wifi
/// signal arcs (complementary to MacWatch's EKG — "network signal" vs "system vitals"),
/// blue accent dot at the source point. Same color palette, different motif.

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

    // ── Background: deep navy gradient (same as MacWatch) ──────────────────
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.055, green: 0.165, blue: 0.392, alpha: 1), // top navy  (14,42,100)
            CGColor(red: 0.024, green: 0.078, blue: 0.235, alpha: 1), // bottom    (6,20,60)
        ] as CFArray,
        locations: [0, 1]
    )!

    let radius = size * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    ctx.drawLinearGradient(gradient,
        start: CGPoint(x: size * 0.5, y: size),
        end:   CGPoint(x: size * 0.5, y: 0),
        options: [])

    // ── Wifi signal arcs ────────────────────────────────────────────────────
    // Three concentric arcs radiating upward — standard wifi orientation.
    // AppKit y-up: (0,0) = bottom-left. sourceY in lower portion so arcs open upward.
    // clockwise:true in AppKit y-up = CW in math coords = arc goes through north (top).
    //
    // Arc geometry: center at sourceX,sourceY. startAngle=225° (lower-left of circle),
    // endAngle=315° (lower-right). Clockwise through 180°→90°→0° = upward-opening arc.
    // Outermost radius * 2 ≈ 83% of icon width — matches MacWatch visual weight.

    // Source at 42% from bottom (just below vertical center).
    // Outer arc radius = 0.28×size → arcs fully contained, no clipping.
    // Outer arc top reaches 0.70 from bottom. All endpoints stay within icon bounds.
    // Line width matches MacWatch (size/32). Visual mass comparable to MacWatch waveform.
    let sourceX = size * 0.50
    let sourceY = size * 0.42
    let lw      = max(1.5, size / 32.0)

    let radii: [(CGFloat, CGFloat)] = [
        (size * 0.11, 0.92),   // innermost
        (size * 0.20, 0.80),   // middle
        (size * 0.28, 0.65),   // outermost
    ]

    for (r, alpha) in radii {
        let arcPath = NSBezierPath()
        // startAngle=225° (SW), endAngle=315° (SE), clockwise=true → arc passes through
        // north (top), producing an upward-opening wifi arc in AppKit y-up coords.
        arcPath.appendArc(
            withCenter: NSPoint(x: sourceX, y: sourceY),
            radius:     r,
            startAngle: 225,
            endAngle:   315,
            clockwise:  true
        )
        arcPath.lineWidth    = lw
        arcPath.lineCapStyle = .round
        NSColor(white: 1.0, alpha: alpha).setStroke()
        arcPath.stroke()
    }

    // ── Accent dot at the arc source point (same blue family as MacWatch) ──
    // Sits at sourceX, sourceY — the origin the arcs radiate from.
    let dotR = max(2.0, size / 28.0)

    let dotGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.72, green: 0.88, blue: 1.00, alpha: 1.0), // light blue
            CGColor(red: 0.39, green: 0.71, blue: 1.00, alpha: 1.0), // (100,180,255)
        ] as CFArray,
        locations: [0, 1]
    )!

    let dotRect = CGRect(x: sourceX - dotR, y: sourceY - dotR, width: dotR * 2, height: dotR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    ctx.drawRadialGradient(dotGradient,
        startCenter: CGPoint(x: sourceX, y: sourceY + dotR * 0.3),
        startRadius: 0,
        endCenter:   CGPoint(x: sourceX, y: sourceY),
        endRadius:   dotR,
        options: [])
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

// ── Write PNGs ──────────────────────────────────────────────────────────────

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

// ── Build .iconset and run iconutil ─────────────────────────────────────────

let iconsetDir = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
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
