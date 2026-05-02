import AppKit
import Foundation

enum IconError: Error {
    case missingOutputPath
    case pngEncodingFailed(String)
    case iconutilFailed(Int32)
}

guard CommandLine.arguments.count == 2 else {
    throw IconError.missingOutputPath
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("sdimport-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryRoot.appendingPathComponent("SDImport.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: temporaryRoot)
}

let representations: [(points: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png")
]

for representation in representations {
    let pixels = representation.points * representation.scale
    let image = drawIcon(size: CGFloat(pixels))
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw IconError.pngEncodingFailed(representation.name)
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(representation.name, isDirectory: false))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw IconError.iconutilFailed(iconutil.terminationStatus)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let cornerRadius = size * 0.22
    let backgroundRect = bounds.insetBy(dx: size * 0.065, dy: size * 0.065)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.72, alpha: 1)
        ]
    )
    gradient?.draw(in: backgroundPath, angle: 315)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    backgroundPath.lineWidth = max(1, size * 0.018)
    backgroundPath.stroke()

    let cardRect = NSRect(
        x: size * 0.27,
        y: size * 0.22,
        width: size * 0.46,
        height: size * 0.56
    )
    let cardPath = NSBezierPath(
        roundedRect: cardRect,
        xRadius: size * 0.055,
        yRadius: size * 0.055
    )
    NSColor.white.withAlphaComponent(0.92).setFill()
    cardPath.fill()

    NSColor(calibratedRed: 0.06, green: 0.25, blue: 0.78, alpha: 1).setStroke()
    cardPath.lineWidth = max(1, size * 0.025)
    cardPath.stroke()

    let notchWidth = size * 0.16
    let notchHeight = size * 0.12
    let notchRect = NSRect(
        x: cardRect.maxX - notchWidth,
        y: cardRect.maxY - notchHeight,
        width: notchWidth,
        height: notchHeight
    )
    NSColor(calibratedRed: 0.06, green: 0.25, blue: 0.78, alpha: 1).setFill()
    notchRect.fill()

    NSColor(calibratedRed: 0.06, green: 0.25, blue: 0.78, alpha: 1).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = max(2, size * 0.05)
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: size * 0.50, y: size * 0.64))
    arrow.line(to: NSPoint(x: size * 0.50, y: size * 0.38))
    arrow.move(to: NSPoint(x: size * 0.38, y: size * 0.50))
    arrow.line(to: NSPoint(x: size * 0.50, y: size * 0.38))
    arrow.line(to: NSPoint(x: size * 0.62, y: size * 0.50))
    arrow.stroke()

    return image
}
