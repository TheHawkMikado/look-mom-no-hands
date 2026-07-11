import AppKit

/// A pure-modifier chord (e.g. Control+Option) that toggles dictation. Presets
/// keep the settings UI simple while covering the combos people actually use.
enum DictationChord: String, CaseIterable, Sendable {
    case off
    case controlOption
    case commandOption
    case controlCommand
    case optionShift
    case commandControlOption

    var label: String {
        switch self {
        case .off: return "Off"
        case .controlOption: return "⌃⌥  Control-Option"
        case .commandOption: return "⌘⌥  Command-Option"
        case .controlCommand: return "⌃⌘  Control-Command"
        case .optionShift: return "⌥⇧  Option-Shift"
        case .commandControlOption: return "⌘⌃⌥  Cmd-Ctrl-Opt"
        }
    }

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .controlOption: return [.control, .option]
        case .commandOption: return [.command, .option]
        case .controlCommand: return [.control, .command]
        case .optionShift: return [.option, .shift]
        case .commandControlOption: return [.command, .control, .option]
        }
    }
}

/// Fires `onToggle` once each time the configured modifier chord is *tapped* —
/// pressed together and then released cleanly, with no other key pressed in
/// between. That distinction is what keeps a Control+Option chord from firing
/// when Control+Option is merely the prefix of a real shortcut (⌃⌥→, ⌃⌥L, …):
/// those press a non-modifier key during the hold, so they don't count. This is
/// the VoiceDash press-to-start / press-again-to-stop gesture. Global + local
/// monitors so it works regardless of focus; global delivery needs Accessibility.
/// Passive — it never consumes events. The key monitor only sets a boolean; it
/// never inspects or records which key was pressed.
@MainActor
final class HotkeyMonitor {
    var onToggle: (() -> Void)?

    private var chord: NSEvent.ModifierFlags?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var engaged = false        // the chord is exactly held right now
    private var usedWithKey = false    // a non-modifier key was pressed during the hold
    // Only these participate in the exact-match, so Caps Lock / Fn don't interfere.
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    func setChord(_ flags: NSEvent.ModifierFlags?) {
        chord = flags
        engaged = false
        usedWithKey = false
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        engaged = false
        usedWithKey = false
    }

    // NSEvent monitors deliver on the main run loop, so this is main-actor safe.
    private func handle(_ event: NSEvent) {
        guard let chord, !chord.isEmpty else { engaged = false; return }
        if event.type == .keyDown {
            if engaged { usedWithKey = true }   // the chord was a shortcut prefix
            return
        }
        let flags = event.modifierFlags.intersection(Self.relevant)
        if flags == chord {
            if !engaged { engaged = true; usedWithKey = false }
        } else if engaged {
            engaged = false
            // Fire only on a clean release: a chord key was let go (remaining
            // flags ⊂ chord, not another modifier added) and no other key was
            // pressed while held. Adding a modifier or pressing a key cancels.
            if !usedWithKey, chord.isSuperset(of: flags) {
                onToggle?()
            }
        }
    }
}
