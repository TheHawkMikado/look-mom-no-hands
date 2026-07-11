import SwiftUI
import AppKit

/// Holds just the ~43 Hz mic level, separate from AppCoordinator so the high-rate
/// updates invalidate only the pill's waveform — not the menu bar and dashboard.
@MainActor
final class RecorderMeter: ObservableObject {
    @Published var level: Float = 0
}

/// A small floating HUD shown only while recording/processing (like Wisprflow's
/// pill): a live waveform, elapsed time, and stop/cancel. A borderless
/// non-activating panel so it never steals focus from the app you're dictating
/// into. Draggable; its position is remembered.
@MainActor
final class RecorderPill {
    private var panel: NSPanel?
    private static let originKey = "recorderPillOrigin"

    func show(coordinator: AppCoordinator) {
        if panel == nil { panel = makePanel(coordinator: coordinator) }
        guard let panel else { return }
        positionIfNeeded(panel)
        panel.orderFrontRegardless()   // show without activating our app
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel(coordinator: AppCoordinator) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 232, height: 46),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: RecorderPillView(coordinator: coordinator, meter: coordinator.meter))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        // Persist the position whenever the user drags it.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                let o = panel.frame.origin
                UserDefaults.standard.set([o.x, o.y], forKey: Self.originKey)
            }
        }
        return panel
    }

    private func positionIfNeeded(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [CGFloat], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
            return
        }
        // Default: bottom-center of the main screen.
        guard let screen = NSScreen.main else { return }
        let f = panel.frame
        let x = screen.visibleFrame.midX - f.width / 2
        let y = screen.visibleFrame.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct RecorderPillView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var meter: RecorderMeter
    @State private var bars: [Float] = Array(repeating: 0.05, count: 22)
    @State private var now = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
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
        .padding(.horizontal, 10)
        .frame(height: 46)
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
