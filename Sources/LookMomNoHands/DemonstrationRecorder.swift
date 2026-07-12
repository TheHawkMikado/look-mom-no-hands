import AppKit

/// Records the user's actual clicks and keystrokes while they demonstrate a task
/// ("watch me do this"), and renders them as narrated steps for a Procedure.
/// Global event monitors OBSERVE input to other apps (they never intercept it);
/// they require the Accessibility permission the app already holds. Each click is
/// resolved to the UI element under the cursor so the narration says "click the
/// 'Save' button in Mail", not brittle raw coordinates.
@MainActor
final class DemonstrationRecorder {
    private var monitors: [Any] = []
    private var steps: [String] = []
    private var typedBuffer = ""

    var isRecording: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        steps = []
        typedBuffer = ""
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { _ in
            // NSEvent.mouseLocation is Cocoa global (y-up); capture it now, on the
            // event, then hop to the main actor to resolve + record.
            let cocoa = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.recordClick(atCocoa: cocoa) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { event in
            // NSEvent isn't Sendable — pull the fields out before hopping actors.
            let chars = event.characters ?? ""
            let code = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.recordKey(chars: chars, keyCode: code,
                                command: flags.contains(.command),
                                option: flags.contains(.option),
                                control: flags.contains(.control),
                                shift: flags.contains(.shift))
            }
        }) { monitors.append(m) }
    }

    /// Stops observing and returns the narrated steps in order.
    func stop() -> [String] {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        flushTyping()
        return steps
    }

    private func recordClick(atCocoa point: NSPoint) {
        guard isRecording else { return }
        flushTyping()
        // Cocoa is y-up from the primary display's bottom; AX hit-testing is y-down.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
        let quartz = CGPoint(x: point.x, y: primaryHeight - point.y)
        if let hit = ScreenController.elementLabel(atQuartz: quartz) {
            let label = hit.label.isEmpty ? "" : " \"\(hit.label)\""
            steps.append("In \(hit.app), click the \(hit.role)\(label).")
        } else {
            // No AX element (canvas/game/remote desktop). A raw x,y isn't replayable
            // (the executor clicks by label/vision), so record an honest, actionable
            // note instead of a coordinate that would silently fail on replay.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app"
            steps.append("Click the intended control in \(app) — I couldn't identify it automatically, so describe which one when you run this.")
        }
    }

    private func recordKey(chars: String, keyCode: UInt16, command: Bool, option: Bool, control: Bool, shift: Bool) {
        guard isRecording else { return }
        switch Self.describeKey(chars: chars, keyCode: keyCode, command: command, option: option, control: control, shift: shift) {
        case .typed(let s):
            // Fail-closed redaction: capture typing only into a confirmed plain text
            // field. A password field, or anything we can't positively classify,
            // records a marker once — never the secret — so credentials can't reach
            // procedures.json or a planner prompt through an AX blind spot.
            if ScreenController.shouldRedactFocusedTyping() {
                if !typedBuffer.hasSuffix(Self.redactionMark) { typedBuffer += Self.redactionMark }
            } else {
                typedBuffer += s
            }
        case .special(let name):
            flushTyping()
            steps.append("Press \(name).")
        case .backspace:
            if typedBuffer.isEmpty { steps.append("Press delete.") } else { typedBuffer.removeLast() }
        case .ignore:
            break
        }
    }

    static let redactionMark = "«hidden text»"

    enum KeyAction: Equatable {
        case typed(String)      // plain character — accumulate into a "Type …" step
        case special(String)    // enter/tab/shortcut — its own step
        case backspace
        case ignore
    }

    /// Pure translation of one key event into a narration action — unit-tested.
    nonisolated static func describeKey(chars: String, keyCode: UInt16,
                                        command: Bool, option: Bool, control: Bool, shift: Bool = false) -> KeyAction {
        if command || control || option {   // a real shortcut (option too: cmd/ctrl/opt combos)
            var mods: [String] = []
            if command { mods.append("cmd") }
            if control { mods.append("ctrl") }
            if option { mods.append("option") }
            if shift { mods.append("shift") }   // was dropped — cmd+shift+t ≠ cmd+t
            // Resolve the base key from the physical key code (shift/option-independent)
            // so "cmd+shift+4" isn't recorded as "cmd+$".
            let key = specialName(for: keyCode) ?? baseChar(for: keyCode) ?? chars.lowercased()
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .ignore }
            return .special("\(mods.joined(separator: "+"))+\(cleaned)")
        }
        if let name = specialName(for: keyCode) { return .special(name) }
        if keyCode == 51 { return .backspace }
        guard !chars.isEmpty else { return .ignore }
        // Arrow/function keys arrive as private-use scalars — not typed text.
        if chars.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) { return .ignore }
        return .typed(chars)
    }

    // The unmodified character for a physical key code (US layout letters/digits),
    // so a shortcut's base key is stable regardless of shift/option.
    private nonisolated static func baseChar(for keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i",
            38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q",
            15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9"
        ]
        return map[keyCode]
    }

    private nonisolated static func specialName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: return "enter"
        case 48: return "tab"
        case 53: return "escape"
        case 126: return "up arrow"
        case 125: return "down arrow"
        case 123: return "left arrow"
        case 124: return "right arrow"
        default: return nil
        }
    }

    private func flushTyping() {
        let t = typedBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        typedBuffer = ""
        guard !t.isEmpty else { return }
        steps.append("Type \"\(t)\".")
    }
}
