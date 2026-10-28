import QuartzCore
import SwiftUI

/// The notch's outline, drawn as one path: it hangs from the top of the screen, flares into the
/// screen edge with a small concave curve at each top corner, and rounds off at the bottom.
///
/// Nothing in the shape animates by itself. Its corners follow the size it's drawn at: the more
/// the notch has grown past the hardware notch, the rounder it gets, so the corners soften
/// smoothly as it opens and tighten again as it closes.
struct NotchShape: Shape {
    /// The hardware notch (the closed size).
    var notchSize: CGSize
    /// Small cards that only grow a little keep tighter corners.
    var isWidthFineTuning = false

    /// 0 at the closed size, 1 once grown by `span`, eased so the corners settle gently.
    private func growth(_ value: CGFloat, from start: CGFloat, span: CGFloat) -> CGFloat {
        let t = min(max((value - start) / span, 0), 1)
        return t * t * (3 - 2 * t)  // smoothstep
    }

    /// Bottom corners: about the hardware notch's own radius when closed, much rounder open.
    func bottomRadius(in rect: CGRect) -> CGFloat {
        let closed = min(10, notchSize.height * 0.3)
        let open: CGFloat = isWidthFineTuning ? 18 : 36
        return closed + (open - closed) * growth(rect.height, from: notchSize.height, span: 110)
    }

    /// Top flares: barely there when closed, wider as the notch spreads out.
    func flareRadius(in rect: CGRect) -> CGFloat {
        let closed = max(min(rect.height - bottomRadius(in: rect), 6), 0)
        return closed + (20 - closed) * growth(rect.width, from: notchSize.width, span: 340)
    }

    func path(in rect: CGRect) -> Path {
        NotchTrace.log(rect)
        let flare = flareRadius(in: rect)
        let bottom = min(bottomRadius(in: rect), rect.height / 2, rect.width / 2)
        // How far a cubic's handles reach to round a corner; a bit past a circle's 0.552 for a
        // softer, squircle-like corner.
        let k: CGFloat = 0.62

        var p = Path()
        // Top edge, left flare: from the screen edge, curving down into the left side.
        p.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + flare),
                   control1: CGPoint(x: rect.minX - flare * (1 - k), y: rect.minY),
                   control2: CGPoint(x: rect.minX, y: rect.minY + flare * (1 - k)))
        // Left side, then the bottom-left corner.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        p.addCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                   control1: CGPoint(x: rect.minX, y: rect.maxY - bottom * (1 - k)),
                   control2: CGPoint(x: rect.minX + bottom * (1 - k), y: rect.maxY))
        // Bottom edge, then the bottom-right corner.
        p.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                   control1: CGPoint(x: rect.maxX - bottom * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - bottom * (1 - k)))
        // Right side, up into the right flare and back out along the top.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + flare))
        p.addCurve(to: CGPoint(x: rect.maxX + flare, y: rect.minY),
                   control1: CGPoint(x: rect.maxX, y: rect.minY + flare * (1 - k)),
                   control2: CGPoint(x: rect.maxX + flare * (1 - k), y: rect.minY))
        // Back across the top, 1pt above the screen so no sliver of wallpaper shows.
        p.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY - 1))
        p.addLine(to: CGPoint(x: rect.minX - flare, y: rect.minY - 1))
        p.closeSubpath()
        return p
    }
}

/// `STARLIGHT_TRACE=1` prints every size the shape is drawn at, one line per frame, for checking
/// animations frame by frame.
enum NotchTrace {
    static let enabled = Dev.env("STARLIGHT_TRACE") != nil
    /// The size the shape was last drawn at, for the close watchdog (AppDelegate).
    nonisolated(unsafe) static var lastDrawn: CGSize = .zero

    static func log(_ rect: CGRect) {
        lastDrawn = rect.size
        guard enabled else { return }
        print(String(format: "shape,%.3f,%.2f,%.2f,%.2f,%.2f", CACurrentMediaTime() * 1000, rect.minX, rect.minY, rect.width, rect.height))
        fflush(stdout)
    }
    static func mark(_ label: String) {
        guard enabled else { return }
        print(String(format: "mark,%.3f,", CACurrentMediaTime() * 1000) + label)
        fflush(stdout)
    }
}
