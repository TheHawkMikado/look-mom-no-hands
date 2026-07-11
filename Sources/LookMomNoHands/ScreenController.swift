import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Executes screen actions via the Accessibility tree (to locate elements) and
/// CGEvent (to synthesize input). Requires the app to be granted Accessibility
/// control in System Settings → Privacy & Security → Accessibility.
enum ScreenController {

    enum ControlError: Error, CustomStringConvertible {
        case notTrusted
        case elementNotFound(String)
        case noFrontApp
        case missingDirection
        case appLaunchFailed(String)
        case unknownKeystroke(String)

        var description: String {
            switch self {
            case .notTrusted: return "Accessibility permission not granted"
            case .elementNotFound(let t): return "couldn't find “\(t)” on screen"
            case .noFrontApp: return "no frontmost application"
            case .missingDirection: return "scroll command arrived without a direction"
            case .appLaunchFailed(let n): return "couldn't open “\(n)”"
            case .unknownKeystroke(let k): return "don't know the shortcut “\(k)”"
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the user (once) to grant Accessibility if not already trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Actions

    static func perform(_ action: ScreenAction) throws {
        switch action.kind {
        case .click, .type, .scroll, .keystroke:
            // macOS silently discards synthetic events from untrusted processes —
            // fail loudly instead of logging a success that never happened.
            guard isTrusted else { throw ControlError.notTrusted }
        case .openApp, .openURL, .dictateStart, .none:
            break
        }
        switch action.kind {
        case .click:  try click(target: action.target)
        case .type:   try type(text: action.text)
        case .scroll:
            // The direction is a typed schema field; guessing (e.g. defaulting to
            // .down) would scroll the wrong way and report success.
            guard let direction = action.direction else { throw ControlError.missingDirection }
            try scroll(direction: direction)
        case .openApp: try openApp(named: action.target)
        case .openURL: try openURL(action.url, inApp: action.target)
        case .keystroke: try keystroke(action.keys)
        case .dictateStart, .none: break // handled by the coordinator, not here
        }
    }

    static func click(target: String) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ControlError.noFrontApp }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let needle = target.lowercased()
        guard let element = try findElement(in: root, matching: needle, depth: 0),
              let center = center(of: element) else {
            throw ControlError.elementNotFound(target)
        }
        // Last gate before the irreversible part: Stop mid-walk must not click.
        try Task.checkCancellation()
        clickMouse(at: center)
    }

    static func type(text: String) throws {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // One event pair per character, in UTF-16 units — a character above the
        // BMP (emoji, astral CJK) is a surrogate pair that must be posted whole;
        // truncating to a single unit types a garbage glyph.
        for character in text {
            // Per-character so Stop interrupts a long paste mid-string instead of
            // finishing it into whatever window is now focused.
            try Task.checkCancellation()
            var units = Array(String(character).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    static func scroll(direction: ScrollDirection) throws {
        try Task.checkCancellation()
        let source = CGEventSource(stateID: .combinedSessionState)
        let step: Int32 = 6
        let (dy, dx): (Int32, Int32)
        switch direction {
        case .up:    (dy, dx) = (step, 0)
        case .down:  (dy, dx) = (-step, 0)
        case .left:  (dy, dx) = (0, step)
        case .right: (dy, dx) = (0, -step)
        }
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    static func openApp(named name: String) throws {
        // `open -a` resolves fuzzy app names the way Spotlight does.
        try runOpen(["-a", name], failureName: name)
    }

    static func openURL(_ raw: String, inApp app: String) throws {
        let url = normalizedURL(raw)
        guard !url.isEmpty else { throw ControlError.appLaunchFailed(raw) }
        // A named browser routes the URL there; otherwise the system default.
        try runOpen(app.isEmpty ? [url] : ["-a", app, url], failureName: url)
    }

    /// Bare hostnames ("youtube.com") become https URLs; anything with a scheme
    /// passes through untouched.
    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }

    private static func runOpen(_ arguments: [String], failureName: String) throws {
        // Launching is as irreversible as a click — a cancelled (stopped)
        // command must not do it, and a failed launch must surface, not vanish.
        try Task.checkCancellation()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = arguments
        proc.standardError = Pipe()   // keep `open`'s complaint off our stderr
        try proc.run()
        // run() only proves `open` spawned — an unresolvable name exits nonzero
        // afterward. Poll instead of waitUntilExit(): `open` normally exits in
        // tens of milliseconds, but a LaunchServices stall must not wedge the
        // session's command processing, and Stop (cancellation) must be able to
        // abandon the wait. Runs off the main actor, so the sleeps block no UI.
        // Monotonic deadline — wall-clock (Date) can step backward under NTP.
        let deadline = DispatchTime.now() + .seconds(10)
        while proc.isRunning {
            if Task.isCancelled || DispatchTime.now() > deadline {
                proc.terminate()
                throw ControlError.appLaunchFailed(failureName)
            }
            usleep(50_000)
        }
        guard proc.terminationStatus == 0 else { throw ControlError.appLaunchFailed(failureName) }
    }

    // MARK: - Keystrokes

    static func keystroke(_ spec: String) throws {
        guard let combo = parseKeystroke(spec) else { throw ControlError.unknownKeystroke(spec) }
        try Task.checkCancellation()
        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: true) {
            down.flags = combo.flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: false) {
            up.flags = combo.flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// "cmd+shift+t" → (keycode for t, [.maskCommand, .maskShift]). Returns nil
    /// for anything it can't map — the caller reports it rather than guessing.
    static func parseKeystroke(_ spec: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, flags)
    }

    // US-ANSI virtual keycodes (kVK_*) for the keys shortcuts actually use.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "esc": 53, "escape": 53,
        "delete": 51, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    // MARK: - Accessibility tree search

    private static func findElement(in element: AXUIElement, matching needle: String, depth: Int) throws -> AXUIElement? {
        if depth > 40 { return nil } // guard against pathological trees
        // The walk can grind for seconds on big AX trees (browsers, Electron);
        // checking per node is what lets Stop abandon it promptly.
        try Task.checkCancellation()

        if let label = descriptiveText(of: element)?.lowercased(), label.contains(needle),
           isClickable(element) {
            return element
        }
        for child in children(of: element) {
            if let hit = try findElement(in: child, matching: needle, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func isClickable(_ element: AXUIElement) -> Bool {
        guard let role = string(element, kAXRoleAttribute) else { return false }
        return ["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                "AXStaticText", "AXCell", "AXImage"].contains(role)
    }

    private static func descriptiveText(of element: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = string(element, attr), !s.isEmpty { return s }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    private static func clickMouse(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
