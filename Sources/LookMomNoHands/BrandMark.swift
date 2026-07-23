import AppKit
import SwiftUI

/// The app mark: four finger capsules rising in an arc plus a tilted thumb — a
/// raised hand and an audio level meter at the same time.
///
/// The five paths are the same ones in `Assets/mark.svg`, in that file's
/// `197 312 614 400` coordinate space, so the shipped SVGs and the glyph drawn
/// here can't drift apart. Change one, change both.
struct MarkShape: Shape {
    /// Menu-bar weight by default — thinner than the 76 the icon master uses, so
    /// the five bars stay separated at 15pt. Matches `menubar-template.svg`.
    var lineWidth: CGFloat = 62
    /// The "off" state: a slash across the mark, knocked out of it first so the
    /// two don't merge into a blob at menu-bar size.
    var slashed = false

    /// The SVG viewBox. Fitting to this (not to the ink) keeps the glyph the
    /// same size whether or not it's slashed.
    private static let designBox = CGRect(x: 197, y: 312, width: 614, height: 400)

    private static let bars: [(x: CGFloat, top: CGFloat)] = [
        (434, 430),   // index
        (546, 370),   // middle
        (658, 410),   // ring
        (770, 490),   // pinky
    ]

    func path(in rect: CGRect) -> Path {
        var centreLines = Path()
        centreLines.move(to: CGPoint(x: 344, y: 654))       // thumb
        centreLines.addLine(to: CGPoint(x: 255, y: 486))
        for bar in Self.bars {
            centreLines.move(to: CGPoint(x: bar.x, y: bar.top))
            centreLines.addLine(to: CGPoint(x: bar.x, y: 654))
        }

        let capsules = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        var glyph = centreLines.strokedPath(capsules)

        if slashed {
            let slash = Path { p in
                p.move(to: CGPoint(x: 256, y: 678))
                p.addLine(to: CGPoint(x: 772, y: 346))
            }
            glyph = glyph
                .subtracting(slash.strokedPath(StrokeStyle(lineWidth: lineWidth * 1.9, lineCap: .round)))
                .union(slash.strokedPath(StrokeStyle(lineWidth: lineWidth * 0.9, lineCap: .round)))
        }

        let box = Self.designBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        return glyph.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: rect.midX - box.midX * scale,
                                                 y: rect.midY - box.midY * scale)))
    }
}

extension NSImage {
    /// Menu-bar template image of the mark.
    ///
    /// Template means pure black on transparent: macOS recolours it for light and
    /// dark menu bars and inverts it while the panel is open, which it can only do
    /// if we never bake in a colour. `dimmed` therefore rides on the alpha
    /// channel — the template mask reads alpha, so a faded glyph stays faded in
    /// either appearance.
    static func brandMark(height: CGFloat, slashed: Bool, dimmed: Bool) -> NSImage {
        let aspect = 614.0 / 400.0
        let size = NSSize(width: (height * aspect).rounded(), height: height)

        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(MarkShape(slashed: slashed).path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.withAlphaComponent(dimmed ? 0.5 : 1).cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
