import AppKit

/// A pure-modifier chord (e.g. Control+Option) that toggles a hotkey action.
/// Presets keep the settings UI simple while covering the combos people actually
/// use. Reused for every configurable chord (dictate, dictate+submit, session
/// start/stop), so `off` lets any individual hotkey be disabled.
enum DictationChord: String, CaseIterable, Sendable {
    case off
    case controlOption
    case commandOption
    case controlCommand
    case optionShift
    case controlOptionShift
    case commandControlOption

    var label: String {
        switch self {
        case .off: return "Off"
        case .controlOption: return "⌃⌥  Control-Option"
        case .commandOption: return "⌘⌥  Command-Option"
        case .controlCommand: return "⌃⌘  Control-Command"
        case .optionShift: return "⌥⇧  Option-Shift"
        case .controlOptionShift: return "⌃⌥⇧  Ctrl-Opt-Shift"
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
        case .controlOptionShift: return [.control, .option, .shift]
        case .commandControlOption: return [.command, .control, .option]
        }
    }
}

/// Fires `onChord(id)` once each time one of the configured modifier chords is
/// *tapped* — pressed together and then fully released, with no other key pressed
/// in between. That distinction keeps a Control+Option chord from firing when
/// Control+Option is merely the prefix of a real shortcut (⌃⌥→, ⌃⌥L, …): those
/// press a non-modifier key during the hold, so they don't count.
///
/// Multiple chords are registered at once. When one chord's flags are a subset of
/// another's (⌃⌥ vs ⌃⌥⇧), forming the larger chord passes through the smaller on
/// the way in and out — so we fire only the *most-specific* chord that was exactly
/// held during the hold, at the moment everything is released. That way holding
/// ⇧⌃⌥ never also triggers the plain ⌃⌥ action.
///
/// Global + local monitors so it works regardless of focus; global delivery needs
/// Accessibility. Passive — it never consumes events. The key monitor only sets a
/// boolean; it never inspects or records which key was pressed.
@MainActor
final class HotkeyMonitor {
    /// Called with the id of the chord that was cleanly tapped.
    var onChord: ((String) -> Void)?

    private struct Binding { let id: String; let flags: NSEvent.ModifierFlags }
    private var bindings: [Binding] = []
    private var matched: Binding?      // most-specific chord exactly held this hold
    private var usedWithKey = false    // a non-modifier key was pressed during the hold
    private var globalMonitor: Any?
    private var localMonitor: Any?
    // Only these participate in the exact-match, so Caps Lock / Fn don't interfere.
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    /// Register the active chords. Entries with nil/empty flags (Off) are dropped.
    /// Duplicate flag-sets keep the first entry so a collision fires one action
    /// deterministically instead of both.
    func setChords(_ chords: [(id: String, flags: NSEvent.ModifierFlags?)]) {
        var seen: [NSEvent.ModifierFlags] = []
        bindings = chords.compactMap { entry in
            guard let flags = entry.flags, !flags.isEmpty else { return nil }
            if seen.contains(flags) { return nil }
            seen.append(flags)
            return Binding(id: entry.id, flags: flags)
        }
        matched = nil
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
        matched = nil
        usedWithKey = false
    }

    // NSEvent monitors deliver on the main run loop, so this is main-actor safe.
    private func handle(_ event: NSEvent) {
        guard !bindings.isEmpty else { matched = nil; return }
        if event.type == .keyDown {
            // A non-modifier key pressed while any chord modifier is held means the
            // combo is a real shortcut prefix, not a bare chord tap — suppress.
            if !event.modifierFlags.intersection(Self.relevant).isEmpty { usedWithKey = true }
            return
        }
        let flags = event.modifierFlags.intersection(Self.relevant)
        if flags.isEmpty {
            // Full release ends the physical hold. Fire the most-specific chord
            // that was exactly held, but only on a clean tap (no other key).
            if let m = matched, !usedWithKey { onChord?(m.id) }
            matched = nil
            usedWithKey = false
            return
        }
        // Record an exact match, keeping the one with the most modifiers so a
        // superset chord (⌃⌥⇧) wins over its subset (⌃⌥) seen on the way in/out.
        if let hit = bindings.first(where: { $0.flags == flags }) {
            if matched == nil || hit.flags.rawValue.nonzeroBitCount > matched!.flags.rawValue.nonzeroBitCount {
                matched = hit
            }
        }
    }
}
