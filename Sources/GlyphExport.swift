import AppKit
import SwiftUI

/// `Starlight --export-glyphs <dir>`: every glyph, frame by frame, as sprite sheets for the style
/// guide: white on transparent, one row per glyph, one column per frame.
///
///   glyphs-hover.png   the hover motion, rest → hover pose (easeOutBack over 0.42 s)
///   glyphs-loop.png    the glyphs that keep moving while active, one seamless period
///   glyphs-draw.png    the glyphs that draw themselves on (0.4 s)
///   glyphs.json        names, row order, frame counts and rates
@MainActor
enum GlyphExport {
    static let all: [(String, Glyph.Kind)] = [
        ("voice", .voice), ("note", .note), ("noteLive", .noteLive), ("noteAnswered", .noteAnswered), ("history", .history),
        ("sliders", .sliders), ("screen", .screen), ("screen2", .screen2), ("spring", .spring), ("keycap", .keycap), ("spark", .spark),
        ("check", .check), ("alert", .alert), ("cross", .cross), ("folder", .folder), ("file", .file), ("trash", .trash),
        ("rewind", .rewind), ("close", .close), ("external", .external), ("key", .key), ("search", .search), ("calc", .calc),
        ("memory", .memory), ("puzzle", .puzzle), ("globe", .globe), ("posts", .posts), ("agent", .agent), ("battery", .battery),
        ("headphones", .headphones), ("bluetooth", .bluetooth), ("mouse", .mouse), ("play", .play), ("pause", .pause),
        ("next", .next), ("previous", .previous), ("export", .export), ("copy", .copy), ("terminal", .terminal),
        ("todo", .todo), ("shield", .shield), ("gauge", .gauge),
    ]
    /// Drawn at 48pt, rendered at 2×: 96px cells.
    static let size: CGFloat = 48
    static let hoverFrames = 14   // 0.42 s at 30 fps, plus the rest frame
    static let fps = 30.0
    /// One period of each moving glyph's motion (seconds), so the loop has no seam.
    static let periods: [String: Double] = ["voice": 2 * .pi / 7, "globe": 2 * .pi / 2.4, "agent": 1.2, "spring": 1.0]
    static let drawFrames = 13    // 0.4 s at 30 fps

    static func export(to dir: URL) {
        Render.isRendering = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Hover: every glyph.
        sheet(rows: all.map { name, kind in
            (0..<hoverFrames).map { f in GlyphPose(amount: Glyph.easeOutBack(Double(f) / Double(hoverFrames - 1)), phase: 0, drawn: 1, level: 0.72) }
                .map { (kind, $0) }
        }, to: dir.appendingPathComponent("glyphs-hover.png"))
        // Loops.
        let moving = all.filter { $0.1.isPeriodic }
        let loopFrames = moving.map { max(8, Int(((periods[$0.0] ?? 1.2) * fps).rounded())) }
        sheet(rows: zip(moving, loopFrames).map { item, count in
            let period = periods[item.0] ?? 1.2
            return (0..<count).map { f in (item.1, GlyphPose(amount: 1, phase: period * Double(f) / Double(count), drawn: 1, level: 0.72)) }
        }, to: dir.appendingPathComponent("glyphs-loop.png"))
        // Draw-on.
        let drawing = all.filter { $0.1.drawsOn }
        sheet(rows: drawing.map { _, kind in
            (0..<drawFrames).map { f in (kind, GlyphPose(amount: 0, phase: 0, drawn: Glyph.easeOut(Double(f) / Double(drawFrames - 1)), level: nil)) }
        }, to: dir.appendingPathComponent("glyphs-draw.png"))

        let index: [String: Any] = [
            "cell": Int(size * 2), "size": Int(size), "fps": fps,
            "hover": ["names": all.map(\.0), "frames": hoverFrames, "seconds": 0.42],
            "loop": ["names": moving.map(\.0), "frames": loopFrames, "periods": moving.map { periods[$0.0] ?? 1.2 }],
            "draw": ["names": drawing.map(\.0), "frames": drawFrames, "seconds": 0.4],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("glyphs.json"))
        }
        print("wrote \(dir.path)")
    }

    private static func sheet(rows: [[(Glyph.Kind, GlyphPose)]], to url: URL) {
        let columns = rows.map(\.count).max() ?? 1
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let (kind, pose) = rows[r][c]
                        Canvas { context, canvas in
                            GlyphArt.draw(kind, pose: pose, size: size, in: &context, canvas: canvas)
                        }
                        .frame(width: size, height: size)
                    }
                }
            }
        }
        .frame(width: size * CGFloat(columns), height: size * CGFloat(rows.count), alignment: .topLeading)
        .foregroundStyle(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return print("render failed \(url.lastPathComponent)") }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
