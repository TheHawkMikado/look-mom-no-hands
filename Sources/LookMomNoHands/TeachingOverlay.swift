import SwiftUI
import AppKit

/// The on-screen coaching for teach-on-miss: a floating banner asking the user to
/// click the control we couldn't find, and — once they do — a colored box flashed
/// around the element we learned, so they can see exactly what got captured. Both
/// are borderless, non-activating, click-through panels: they never steal focus or
/// intercept the very click we're waiting for.
@MainActor
final class TeachingOverlay {
    private var bannerPanel: NSPanel?
    private var boxPanel: NSPanel?
    private var hideBoxTask: Task<Void, Never>?

    // MARK: Prompt banner

    /// Shows (or updates) the "click it and I'll remember" banner, centered near
    /// the top of the screen with the mouse.
    func showPrompt(_ text: String) {
        let panel = bannerPanel ?? makeBanner()
        bannerPanel = panel
        (panel.contentView as? NSHostingView<TeachingBanner>)?.rootView = TeachingBanner(text: text)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 44))
        positionBannerTopCenter(panel)
        panel.orderFrontRegardless()
    }

    func hidePrompt() { bannerPanel?.orderOut(nil) }

    private func makeBanner() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // never eat the teaching click
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: TeachingBanner(text: ""))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func positionBannerTopCenter(_ panel: NSPanel) {
        // Prefer the screen the mouse is on (where the user is working).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Confirmation box

    /// Flashes a highlight box around an element frame (AX/top-left origin) to
    /// confirm what was learned, then fades it out.
    func flashBox(aroundAX frameAX: CGRect, color: NSColor) {
        hideBoxTask?.cancel()
        let cocoa = cocoaRect(fromAX: frameAX).insetBy(dx: -4, dy: -4)
        let panel = boxPanel ?? makeBox()
        boxPanel = panel
        panel.setFrame(cocoa, display: true)
        (panel.contentView as? NSHostingView<HighlightBox>)?.rootView =
            HighlightBox(color: Color(nsColor: color))
        panel.orderFrontRegardless()
        hideBoxTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.boxPanel?.orderOut(nil)
        }
    }

    private func makeBox() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: HighlightBox(color: .green))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    func hideAll() {
        hideBoxTask?.cancel(); hideBoxTask = nil
        bannerPanel?.orderOut(nil)
        boxPanel?.orderOut(nil)
    }

    /// AX rects are top-left origin from the primary display; NSWindow frames are
    /// bottom-left in Cocoa space.
    private func cocoaRect(fromAX ax: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return NSRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}

private struct TeachingBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.point.up.left.fill")
                .foregroundColor(.white).font(.system(size: 14, weight: .semibold))
            Text(text)
                .foregroundColor(.white).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.95))
        )
        .padding(4)
    }
}

private struct HighlightBox: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(color, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.12)))
    }
}
