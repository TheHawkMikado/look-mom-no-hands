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

    /// Centre-lines, thumb first then index→pinky — also the visual left-to-right
    /// order the animated menu-bar states sweep through.
    private static let strokes: [(from: CGPoint, to: CGPoint)] = [
        (CGPoint(x: 344, y: 654), CGPoint(x: 255, y: 486)),   // thumb
        (CGPoint(x: 434, y: 430), CGPoint(x: 434, y: 654)),   // index
        (CGPoint(x: 546, y: 370), CGPoint(x: 546, y: 654)),   // middle
        (CGPoint(x: 658, y: 410), CGPoint(x: 658, y: 654)),   // ring
        (CGPoint(x: 770, y: 490), CGPoint(x: 770, y: 654)),   // pinky
    ]

    static var capsuleCount: Int { strokes.count }

    private static func capsule(_ i: Int, lineWidth: CGFloat) -> Path {
        var line = Path()
        line.move(to: strokes[i].from)
        line.addLine(to: strokes[i].to)
        return line.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private static func fitTransform(for rect: CGRect) -> CGAffineTransform {
        let box = designBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - box.midX * scale,
                                             y: rect.midY - box.midY * scale))
    }

    /// The five capsules as separate fitted paths so each can carry its own
    /// colour — what the animated menu-bar states need.
    static func fittedCapsules(in rect: CGRect, lineWidth: CGFloat = 62) -> [Path] {
        let transform = fitTransform(for: rect)
        return strokes.indices.map { capsule($0, lineWidth: lineWidth).applying(transform) }
    }

    func path(in rect: CGRect) -> Path {
        var glyph = Path()
        for i in Self.strokes.indices {
            glyph.addPath(Self.capsule(i, lineWidth: lineWidth))
        }

        if slashed {
            let slash = Path { p in
                p.move(to: CGPoint(x: 256, y: 678))
                p.addLine(to: CGPoint(x: 772, y: 346))
            }
            glyph = glyph
                .subtracting(slash.strokedPath(StrokeStyle(lineWidth: lineWidth * 1.9, lineCap: .round)))
                .union(slash.strokedPath(StrokeStyle(lineWidth: lineWidth * 0.9, lineCap: .round)))
        }

        return glyph.applying(Self.fitTransform(for: rect))
    }
}

/// Menu-bar icon states. Colour carries the state so it reads at a glance:
/// grey slash = off, purple hand = standby (listening for the wake word),
/// purple sweep = live command session, red sweep = recording/dictation.
enum MenuBarMark: Equatable {
    case off
    case standby
    case active(step: Int)
    case dictating(step: Int)
}

extension NSImage {
    /// Menu-bar image of the mark for a given state.
    ///
    /// `.off` stays a template image — pure black on transparent — so macOS
    /// recolours the slashed glyph for light/dark menu bars exactly as before.
    /// The coloured states are deliberately NOT templates: purple/red is the
    /// information, so the system must not repaint it.
    static func brandMark(height: CGFloat, state: MenuBarMark) -> NSImage {
        let aspect = 614.0 / 400.0
        let size = NSSize(width: (height * aspect).rounded(), height: height)

        switch state {
        case .off:
            let image = NSImage(size: size, flipped: true) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.addPath(MarkShape(slashed: true).path(in: rect).cgPath)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                return true
            }
            image.isTemplate = true
            return image
        case .standby:
            return colouredMark(size: size, colour: .systemPurple, highlight: nil)
        case .active(let step):
            return colouredMark(size: size, colour: .systemPurple, highlight: step)
        case .dictating(let step):
            return colouredMark(size: size, colour: .systemRed, highlight: step)
        }
    }

    /// A rounded plate in the state colour with the hand knocked out in white —
    /// bare coloured strokes vanish against a busy menu bar, a filled plate
    /// doesn't. `highlight` nil = every capsule solid white; otherwise that
    /// capsule burns at full strength while the rest sit dimmed — the
    /// level-meter sweep reads as white light moving across the plate.
    private static func colouredMark(size: NSSize, colour: NSColor, highlight: Int?) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let plate = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.28,
                               cornerHeight: rect.height * 0.28, transform: nil)
            ctx.addPath(plate)
            ctx.setFillColor(colour.cgColor)
            ctx.fillPath()

            let glyphRect = rect.insetBy(dx: 3, dy: 2.5)
            for (i, capsule) in MarkShape.fittedCapsules(in: glyphRect).enumerated() {
                let alpha: CGFloat = (highlight == nil || highlight == i) ? 1 : 0.4
                ctx.addPath(capsule.cgPath)
                ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
