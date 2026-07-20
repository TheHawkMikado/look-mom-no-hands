import SwiftUI
import AppKit

/// Holds the high-rate recording signals — the ~43 Hz mic level and the
/// per-partial "what I'm hearing" tail — separate from AppCoordinator so they
/// invalidate only the views that show them, not the menu bar and dashboard.
@MainActor
final class RecorderMeter: ObservableObject {
    @Published var level: Float = 0
    @Published var heard = ""
}

/// A small floating HUD shown only while recording/processing (like Wisprflow's
/// pill): a live waveform, elapsed time, and stop/cancel. A borderless
/// non-activating panel so it never steals focus from the app you're dictating
/// into. Draggable; its position is remembered.
@MainActor
final class RecorderPill {
    private var panel: NSPanel?

    /// Anchors to the top-right of `windowFrameAX` (AX/top-left coords) — the window
    /// the user is working in — then stays draggable. Falls back to the screen's
    /// top-right if no window frame is available.
    func show(coordinator: AppCoordinator, near windowFrameAX: CGRect?) {
        if panel == nil { panel = makePanel(coordinator: coordinator) }
        guard let panel else { return }
        panel.setFrameOrigin(topRightOrigin(pillSize: panel.frame.size, windowAX: windowFrameAX))
        panel.orderFrontRegardless()   // show without activating our app
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel(coordinator: AppCoordinator) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 232, height: 66),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // draggable
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: RecorderPillView(coordinator: coordinator, meter: coordinator.meter))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// AX rects use a top-left origin measured from the primary display; NSWindow
    /// origins are bottom-left in Cocoa space. Convert, then place the pill just
    /// inside the window's top-right corner.
    private func topRightOrigin(pillSize: NSSize, windowAX: CGRect?) -> NSPoint {
        let margin: CGFloat = 10
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        if let w = windowAX {
            let x = w.maxX - pillSize.width - margin
            let y = (primaryHeight - w.minY) - pillSize.height - margin   // window top edge, in Cocoa
            return NSPoint(x: x, y: y)
        }
        // No window: top-right of the main screen's visible area.
        guard let vf = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(x: vf.maxX - pillSize.width - margin, y: vf.maxY - pillSize.height - margin)
    }
}

private struct RecorderPillView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var meter: RecorderMeter
    @State private var bars: [Float] = Array(repeating: 0.05, count: 22)
    @State private var now = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if coordinator.phase == .recording {
                    Button(action: { coordinator.cancelRecording() }) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white).frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)

                    waveform
                        .frame(maxWidth: .infinity)

                    Text(elapsed).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85))

                    Button(action: { coordinator.stopRecording() }) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white).frame(width: 22, height: 22)
                            .background(Circle().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Processing state.
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Processing…").foregroundColor(.white.opacity(0.9)).font(.caption)
                    Spacer()
                }
            }
            .frame(height: 36)
            // Live tail of what's being heard — frozen text here means the
            // recognizer isn't capturing, which used to be invisible until stop.
            if coordinator.phase == .recording {
                Text(meter.heard.isEmpty ? "listening…" : meter.heard)
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.65))
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .padding(5)
        .onChange(of: meter.level) { level in
            bars.removeFirst()
            bars.append(max(0.05, level))
        }
        .onReceive(clock) { now = $0 }
    }

    private var waveform: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(height: max(2, CGFloat(v) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: bars)
        }
        .frame(height: 22)
    }

    private var elapsed: String {
        guard let start = coordinator.recordingStartedAt else { return "0:00" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
