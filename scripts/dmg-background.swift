// The picture behind the disk image's window: Starlight on the left, Applications on the right,
// an arrow between, and one line of instructions. Light, because Finder draws the
// icons' names in black on any window with a picture, in Dark Mode too.
//
//   swift scripts/dmg-background.swift   → Resources/DMG/background.tiff (1x and 2x in one file)
//
// The icon positions here and in scripts/dmg-settings.py must match.
import AppKit

let size = CGSize(width: 660, height: 400)
let app = CGPoint(x: 180, y: 190), applications = CGPoint(x: 480, y: 190)  // icon centres, top-left origin
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/DMG")

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Top-left origin, like the window.
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)

    // A soft white, a touch darker at the bottom.
    let gradient = NSGradient(starting: NSColor(white: 0.995, alpha: 1), ending: NSColor(red: 0.945, green: 0.945, blue: 0.955, alpha: 1))!
    gradient.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    // The arrow, from the app to the folder.
    let arrowY = app.y, start = app.x + 86, end = applications.x - 86
    let ink = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.85)
    ink.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: start, y: arrowY))
    shaft.line(to: CGPoint(x: end, y: arrowY))
    shaft.lineWidth = 1.75
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: end - 9, y: arrowY - 8))
    head.line(to: CGPoint(x: end, y: arrowY))
    head.line(to: CGPoint(x: end - 9, y: arrowY + 8))
    head.lineWidth = 1.75
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // The one instruction, under the icons' names.
    let caption = NSAttributedString(string: "Drag Starlight into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(red: 0.53, green: 0.53, blue: 0.55, alpha: 1),
        .kern: -0.08,
    ])
    let captionSize = caption.size()
    // Text draws upright in a flipped context only through a flipped graphics context.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    caption.draw(at: CGPoint(x: (size.width - captionSize.width) / 2, y: 330))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let one = out.appendingPathComponent("background.png"), two = out.appendingPathComponent("background@2x.png")
try render(scale: 1).write(to: one)
try render(scale: 2).write(to: two)
// One TIFF with both sizes, so Retina screens get the sharp one.
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", one.path, two.path, "-out", out.appendingPathComponent("background.tiff").path]
try tiff.run()
tiff.waitUntilExit()
try? FileManager.default.removeItem(at: one)
try? FileManager.default.removeItem(at: two)
print("wrote", out.appendingPathComponent("background.tiff").path)
