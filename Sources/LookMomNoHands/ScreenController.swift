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

        var description: String {
            switch self {
            case .notTrusted: return "Accessibility permission not granted"
            case .elementNotFound(let t): return "couldn't find “\(t)” on screen"
            case .noFrontApp: return "no frontmost application"
            case .missingDirection: return "scroll command arrived without a direction"
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
        case .click, .type, .scroll:
            // macOS silently discards synthetic events from untrusted processes —
            // fail loudly instead of logging a success that never happened.
            guard isTrusted else { throw ControlError.notTrusted }
        case .openApp, .dictateStart, .none:
            break
        }
        switch action.kind {
        case .click:  try click(target: action.target)
        case .type:   type(text: action.text)
        case .scroll:
            // The direction is a typed schema field; guessing (e.g. defaulting to
            // .down) would scroll the wrong way and report success.
            guard let direction = action.direction else { throw ControlError.missingDirection }
            scroll(direction: direction)
        case .openApp: openApp(named: action.target)
        case .dictateStart, .none: break // handled by the coordinator, not here
        }
    }

    static func click(target: String) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ControlError.noFrontApp }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let needle = target.lowercased()
        guard let element = findElement(in: root, matching: needle, depth: 0),
              let center = center(of: element) else {
            throw ControlError.elementNotFound(target)
        }
        clickMouse(at: center)
    }

    static func type(text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // One event pair per character, in UTF-16 units — a character above the
        // BMP (emoji, astral CJK) is a surrogate pair that must be posted whole;
        // truncating to a single unit types a garbage glyph.
        for character in text {
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

    static func scroll(direction: ScrollDirection) {
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

    static func openApp(named name: String) {
        // `open -a` resolves fuzzy app names the way Spotlight does.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", name]
        try? proc.run()
    }

    // MARK: - Accessibility tree search

    private static func findElement(in element: AXUIElement, matching needle: String, depth: Int) -> AXUIElement? {
        if depth > 40 { return nil } // guard against pathological trees

        if let label = descriptiveText(of: element)?.lowercased(), label.contains(needle),
           isClickable(element) {
            return element
        }
        for child in children(of: element) {
            if let hit = findElement(in: child, matching: needle, depth: depth + 1) { return hit }
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
