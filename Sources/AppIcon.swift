import AppKit
import SwiftUI

/// Starlight's app icon, on Apple's 1024 grid: the app's voice bars, white on a black tile. Nothing
/// else. The bars have the same proportions as the voice glyph Starlight shows everywhere.
struct AppIconArt: View {
    var inverted = false

    var body: some View {
        let tile = inverted ? Color.white : Color.black
        let ink = inverted ? Color.black : Color.white
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(tile)
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
            // A hairline so the black tile still has an edge on a dark Dock.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(ink.opacity(0.12), lineWidth: 2)
                .frame(width: 824, height: 824)
            VoiceBarsArt(ink: ink)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The voice glyph's five bars (5, 10.5, 15, 10.5, 5 on a 24 grid, 4 apart), scaled up.
private struct VoiceBarsArt: View {
    let ink: Color
    private let heights: [CGFloat] = [5, 10.5, 15, 10.5, 5]
    private let scale: CGFloat = 24

    var body: some View {
        HStack(spacing: 4 * scale - 2 * scale) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(ink).frame(width: 2 * scale, height: heights[i] * scale)
            }
        }
    }
}

enum AppIconRender {
    /// Writes AppIcon.iconset (every size macOS asks for) into `dir`, plus the inverted version
    /// as a 1024 preview.
    @MainActor static func write(to dir: URL) {
        let set = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let r = ImageRenderer(content: AppIconArt())
                r.scale = CGFloat(base * scale) / 1024
                guard let image = r.cgImage else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: set.appendingPathComponent(name))
            }
        }
        if let image = ImageRenderer(content: AppIconArt(inverted: true)).cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("AppIcon-white.png"))
        }
        print("wrote \(set.path)")
    }
}
