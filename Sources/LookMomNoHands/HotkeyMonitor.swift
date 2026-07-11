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

/// Fires `onToggle` once each time the configured modifier chord is engaged (all
/// its keys pressed together) — the VoiceDash press-to-start / press-again-to-stop
/// gesture. Global + local monitors so it works regardless of which app is
/// focused; global delivery needs Accessibility (already required for control).
/// Passive: it never consumes the event, so the chord still does whatever it
/// normally would in other apps (Control+Option alone does nothing, by design).
@MainActor
final class HotkeyMonitor {
    var onToggle: (() -> Void)?

    private var chord: NSEvent.ModifierFlags?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var engaged = false
    // Only these participate in the exact-match, so Caps Lock / Fn don't interfere.
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    func setChord(_ flags: NSEvent.ModifierFlags?) {
        chord = flags
        engaged = false
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event.modifierFlags)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event.modifierFlags)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        engaged = false
    }

    // NSEvent monitors deliver on the main run loop, so this is main-actor safe.
    private func handle(_ modifierFlags: NSEvent.ModifierFlags) {
        guard let chord, !chord.isEmpty else { engaged = false; return }
        // Exact match: a Control+Option chord must NOT fire on Control+Option+Cmd.
        let satisfied = modifierFlags.intersection(Self.relevant) == chord
        if satisfied, !engaged {
            engaged = true
            onToggle?()
        } else if !satisfied {
            engaged = false   // require a release before the next toggle (debounce)
        }
    }
}
