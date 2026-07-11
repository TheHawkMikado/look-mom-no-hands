import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

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
        case .click, .type, .scroll, .keystroke, .focusWindow, .switchTab:
            // macOS silently discards synthetic events from untrusted processes,
            // and window enumeration needs AX — fail loudly instead of logging a
            // success that never happened.
            guard isTrusted else { throw ControlError.notTrusted }
        case .openApp, .openURL, .dictateStart, .describeScreen, .none:
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
        case .focusWindow: try focusWindow(matching: action.target)
        case .switchTab: try switchTab(to: action.target)
        case .keystroke: try keystroke(action.keys)
        case .dictateStart, .describeScreen, .none: break // handled by the coordinator, not here
        }
    }

    // MARK: - Window focus

    struct WindowInfo { let app: String; let title: String; let window: AXUIElement; let runningApp: NSRunningApplication }

    /// Every on-screen window of every regular app, with its title (via AX — no
    /// Screen Recording permission needed, unlike CGWindowList names). Checks
    /// cancellation per app: a slow/hung app's synchronous AX query has no timeout,
    /// so without this Stop couldn't interrupt a stalled enumeration.
    static func openWindows() throws -> [WindowInfo] {
        var out: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            try Task.checkCancellation()
            guard let name = app.localizedName else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for w in windows {
                out.append(WindowInfo(app: name, title: string(w, kAXTitleAttribute) ?? "",
                                      window: w, runningApp: app))
            }
        }
        return out
    }

    /// Switches the frontmost browser to the tab whose title best matches. Presses
    /// the tab's AXRadioButton (more reliable than a geometric click on the tab bar).
    static func switchTab(to needle: String) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ControlError.noFrontApp }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let window = winRef as! AXUIElement?,
              let group = firstDescendant(of: window, role: "AXTabGroup", depth: 0) else {
            throw ControlError.elementNotFound(needle)
        }
        let n = needle.lowercased()
        var best: (el: AXUIElement, score: Int)?
        for tab in children(of: group) where string(tab, kAXRoleAttribute) == "AXRadioButton" {
            guard let title = string(tab, kAXTitleAttribute)?.lowercased(), !title.isEmpty else { continue }
            let s = elementMatchScore(label: title, needle: n, depth: 0, isTextInput: false)
            if s > 0, best == nil || s > best!.score { best = (tab, s) }
        }
        guard let hit = best?.el else { throw ControlError.elementNotFound(needle) }
        try Task.checkCancellation()
        AXUIElementPerformAction(hit, kAXPressAction as CFString)
    }

    /// Groups the flat window list into the app→window hierarchy, flags the
    /// frontmost app and each app's focused window, and (for browsers) fills in
    /// tab titles. Cancellable/bounded like `openWindows`. Runs off the main actor.
    static func environmentSnapshot(includeTabs: Bool = true) throws -> EnvSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        var byApp: [String: EnvApp] = [:]
        var order: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            try Task.checkCancellation()
            guard let name = app.localizedName else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // Bound every AX call to this app so one wedged process can't stall the
            // whole poll (AX has no default timeout; this poller runs unattended).
            AXUIElementSetMessagingTimeout(axApp, 0.4)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            // The app's focused window (to mark it in the hierarchy). Status-checked
            // + conditional cast: a backgrounded app can return kCFNull here, and a
            // force-cast of that would crash.
            // Type-ID check, not `as?`: a conditional CF downcast "always succeeds",
            // so kCFNull would slip through and later CFEqual would misbehave.
            var focusedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
            let focused: AXUIElement? = focusedRef.flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }

            let browser = includeTabs ? browserTabber(for: app.bundleIdentifier) : nil
            var envWindows: [EnvWindow] = []
            for w in windows {
                let title = string(w, kAXTitleAttribute) ?? ""
                let isFocused = focused.map { CFEqual($0, w) } ?? false
                let (tabs, active) = browser?(w) ?? ([], nil)
                envWindows.append(EnvWindow(app: name, title: title, focused: isFocused, tabs: tabs, activeTab: active))
            }
            if byApp[name] == nil { order.append(name) }
            byApp[name] = EnvApp(name: name, bundleID: app.bundleIdentifier,
                                 active: app.processIdentifier == front?.processIdentifier,
                                 windows: envWindows)
        }
        // Frontmost app first, then the rest in discovery order (stable partition —
        // sorted(by:) isn't stable, which would scramble the inactive tail).
        let list = order.compactMap { byApp[$0] }
        return EnvSnapshot(apps: list.filter { $0.active } + list.filter { !$0.active })
    }

    /// Browser tab reader for a bundle id, or nil for non-browsers. Reads the
    /// window's AXTabGroup children (titles) — no Automation permission needed,
    /// unlike AppleScript. Best-effort: a browser that doesn't expose an AXTabGroup
    /// just yields no tabs.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.apple.Safari"
    ]
    private static func browserTabber(for bundleID: String?) -> ((AXUIElement) -> ([String], String?))? {
        guard let bundleID, browserBundleIDs.contains(bundleID) else { return nil }
        return { window in
            guard let group = firstDescendant(of: window, role: "AXTabGroup", depth: 0) else { return ([], nil) }
            var titles: [String] = []
            var active: String? = nil
            for tab in children(of: group) where string(tab, kAXRoleAttribute) == "AXRadioButton" {
                guard let t = string(tab, kAXTitleAttribute), !t.isEmpty else { continue }
                titles.append(t)
                // AXValue == 1 marks the selected tab on most browsers.
                if let v = string(tab, kAXValueAttribute), v == "1" { active = t }
            }
            return (titles, active)
        }
    }

    private static func firstDescendant(of element: AXUIElement, role: String, depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        for child in children(of: element) {
            if string(child, kAXRoleAttribute) == role { return child }
            if let hit = firstDescendant(of: child, role: role, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// Raises the open window that best matches a spoken description ("the Look
    /// Mom No Hands VS Code") and makes it frontmost. Matches on app name + title,
    /// so "look-mom-no-hands — Visual Studio Code" resolves. Throws if it can't be
    /// brought forward, so a following type/keystroke never lands in the wrong app.
    static func focusWindow(matching query: String) throws {
        try Task.checkCancellation()
        let windows = try openWindows()
        let labels = windows.map { "\($0.app) \($0.title)" }
        guard let idx = bestWindowIndex(labels, query: query) else {
            throw ControlError.elementNotFound(query)
        }
        let hit = windows[idx]
        // Restore if minimized (AXRaise is a no-op on a minimized window), make it
        // the app's main window, raise it, then activate the app.
        AXUIElementSetAttributeValue(hit.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(hit.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
        hit.runningApp.activate(options: [])
        // Activation is async — wait (bounded, cancellation-aware) until the app is
        // actually frontmost so the next step's input goes to this window.
        let deadline = DispatchTime.now() + .milliseconds(800)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != hit.runningApp.processIdentifier {
            if Task.isCancelled { return }
            if DispatchTime.now() > deadline { throw ControlError.elementNotFound(query) }
            usleep(30_000)
        }
    }

    /// Index of the window label sharing the most words with the query (0 → nil).
    /// Pure — unit-tested.
    static func bestWindowIndex(_ labels: [String], query: String) -> Int? {
        let q = Set(tokens(query.lowercased()))
        guard !q.isEmpty else { return nil }
        var best: (idx: Int, score: Int)?
        for (i, label) in labels.enumerated() {
            let words = Set(tokens(label.lowercased()))
            let score = q.intersection(words).count
            if score > 0, score > (best?.score ?? 0) { best = (i, score) }
        }
        return best?.idx
    }

    static func click(target: String) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ControlError.noFrontApp }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let needle = target.lowercased()
        var best: ElementMatch?
        var budget = 4000   // bound the full-tree walk on big Electron/browser trees
        try findBestElement(in: root, matching: needle, depth: 0, budget: &budget, best: &best)
        guard let match = best, let center = center(of: match.element) else {
            throw ControlError.elementNotFound(target)
        }
        // Last gate before the irreversible part: Stop mid-walk must not click.
        try Task.checkCancellation()
        clickMouse(at: center)
        // A text field must actually hold focus for a following `type`/paste to
        // land. The geometric click alone can miss (inset/overlapped hit area or a
        // field that grabs focus on a child), so also set AX focus explicitly.
        if isTextInput(match.role) {
            AXUIElementSetAttributeValue(match.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Reading the screen

    struct Snapshot: Sendable {
        let app: String
        let title: String
        let url: String
        let elements: [(role: String, label: String)]

        /// Compact rendering for the model: what's on screen and what's clickable
        /// (by exact label, which the click executor then resolves precisely).
        var promptText: String {
            var s = "On screen now: \(app)"
            if !title.isEmpty { s += " — \(title)" }
            if !url.isEmpty { s += " (\(url))" }
            guard !elements.isEmpty else { return s }
            s += "\nClickable/visible elements (to click one, emit a click step with its exact label):"
            for e in elements {
                let role = e.role.replacingOccurrences(of: "AX", with: "").lowercased()
                s += "\n- \(role): \(e.label)"
            }
            return s
        }
    }

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXPopUpButton", "AXComboBox", "AXTab", "AXDisclosureTriangle"
    ]

    /// A bounded, cancellable read of the frontmost app's focused window: its
    /// title, URL (for browsers), and the interactive elements actually present —
    /// so the model clicks what's really there instead of guessing.
    static func focusedWindowSnapshot(maxElements: Int = 60) throws -> Snapshot? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        var window: AXUIElement?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success {
            window = (winRef as! AXUIElement?)
        }
        if window == nil, AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &winRef) == .success {
            window = (winRef as! AXUIElement?)
        }
        guard let window else { return Snapshot(app: name, title: "", url: "", elements: []) }

        var elements: [(role: String, label: String)] = []
        var url = ""
        try collectElements(window, depth: 0, cap: maxElements, into: &elements, url: &url)
        return Snapshot(app: name, title: string(window, kAXTitleAttribute) ?? "", url: url, elements: elements)
    }

    private static func collectElements(_ element: AXUIElement, depth: Int, cap: Int,
                                        into elements: inout [(role: String, label: String)],
                                        url: inout String) throws {
        if elements.count >= cap || depth > 30 { return }
        try Task.checkCancellation()
        if let role = string(element, kAXRoleAttribute) {
            if role == "AXWebArea", url.isEmpty, let u = axURL(element) { url = u }
            if interactiveRoles.contains(role), let label = descriptiveText(of: element), !label.isEmpty {
                elements.append((role, String(label.prefix(80))))
            }
        }
        for child in children(of: element) {
            if elements.count >= cap { return }
            try collectElements(child, depth: depth + 1, cap: cap, into: &elements, url: &url)
        }
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

    /// Puts text on the clipboard (so it's recoverable even without Accessibility).
    @discardableResult
    static func setClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    /// Sends ⌘V to paste the clipboard at the cursor. Needs Accessibility.
    static func sendPaste() throws {
        try keystroke("cmd+v")
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
        // `open -a` only matches the app's real name, so a spoken shorthand like
        // "Chrome" (the app is "Google Chrome") fails. Resolve to the actual
        // bundle by scanning the Applications folders first; fall back to letting
        // `open -a` try if we can't find it.
        if let path = resolveAppPath(name) {
            try runOpen([path], failureName: name)
        } else {
            try runOpen(["-a", name], failureName: name)
        }
    }

    static func openURL(_ raw: String, inApp app: String) throws {
        var site = raw
        var browser = app
        // The model sometimes swaps the fields (puts the site in the browser
        // slot). If the url is empty but the "browser" looks like a host, it's
        // the site; a real browser name has a space or no dot.
        if normalizedURL(site).isEmpty, looksLikeHost(browser) {
            site = browser
            browser = ""
        }
        let url = normalizedURL(site)
        guard !url.isEmpty else { throw ControlError.appLaunchFailed(raw) }
        // Resolve the browser name the same way ("Chrome" → "Google Chrome").
        if browser.isEmpty {
            try runOpen([url], failureName: url)                    // system default
        } else if let path = resolveAppPath(browser) {
            try runOpen(["-a", path, url], failureName: url)
        } else {
            try runOpen(["-a", browser, url], failureName: url)
        }
    }

    // MARK: - App-name resolution

    // Machine-wide, admin-installed apps. Ranked as a trust tier ABOVE the
    // user-writable ~/Applications so a planted ~/Applications/Chrome.app can't
    // hijack a "chrome" command away from the real /Applications/Google Chrome.
    private static let trustedAppDirectories = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities"
    ]
    private static let userAppDirectories = [NSHomeDirectory() + "/Applications"]

    /// Full path to an installed .app matching a spoken name, or nil. Trusted
    /// directories are matched first (ranked globally so an exact name beats a
    /// substring across them); ~/Applications is consulted only if nothing
    /// trusted matches.
    static func resolveAppPath(_ name: String) -> String? {
        for dirs in [trustedAppDirectories, userAppDirectories] {
            let candidates = appCandidates(in: dirs)
            if let match = bestAppMatch(candidates.map { $0.name }, query: name) {
                return candidates.first { $0.name == match }?.path
            }
        }
        return nil
    }

    private static func appCandidates(in dirs: [String]) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = []
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") { out.append((item, dir + "/" + item)) }
        }
        return out
    }

    /// Pure mirror of the tier precedence for testing: the first tier that yields
    /// any match wins, so a user-local exact name can't beat a trusted substring.
    static func firstTierMatch(_ tiers: [[String]], query: String) -> String? {
        for tier in tiers {
            if let match = bestAppMatch(tier, query: query) { return match }
        }
        return nil
    }

    /// Picks the best ".app" filename for a query, in descending quality:
    ///   1. exact stem ("safari" → "Safari.app")
    ///   2. query as a whole word in the name ("code" → "Visual Studio Code.app",
    ///      NOT "Xcode.app"; "chrome" → "Google Chrome.app")
    ///   3. plain substring, shortest name (last-resort fuzzy match)
    /// Within a tier the shortest stem wins ("Google Chrome" over "…Canary").
    /// Pure.
    static func bestAppMatch(_ files: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let stems = files.filter { $0.hasSuffix(".app") }
            .map { (file: $0, stem: String($0.dropLast(4)).lowercased()) }

        if let exact = stems.first(where: { $0.stem == q }) { return exact.file }

        let wholeWord = stems.filter { tokens($0.stem).contains(q) }
        if let best = wholeWord.min(by: { $0.stem.count < $1.stem.count }) { return best.file }

        return stems.filter { $0.stem.contains(q) }
            .min(by: { $0.stem.count < $1.stem.count })?.file
    }

    private static func tokens(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Bare hostnames ("youtube.com") become https URLs; anything with a scheme
    /// passes through untouched.
    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }

    private static func looksLikeHost(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains(".") && !t.contains(" ")
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
        // Split on "+" but keep a literal "+" token (from "cmd++"), which the
        // separator would otherwise drop as an empty component.
        let normalized = spec.lowercased().replacingOccurrences(of: "++", with: "+plus")
        for part in normalized.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "":
                continue
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
        "left": 123, "right": 124, "down": 125, "up": 126,
        // Symbols and their spoken aliases — zoom (cmd+=/cmd+-), etc.
        "=": 24, "equals": 24, "plus": 24, "-": 27, "minus": 27,
        "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, "comma": 43,
        ".": 47, "period": 47, "/": 44, "slash": 44, "\\": 42, "`": 50
    ]

    // MARK: - Accessibility tree search

    struct ElementMatch { let element: AXUIElement; let role: String; let score: Int }

    /// Content roles that aren't in `interactiveRoles` but are still legitimate
    /// click targets (a result row, a label, an icon). Unioned with the interactive
    /// set so anything the snapshot advertised as clickable is actually clickable —
    /// the old executor rejected text fields/popups/tabs the snapshot offered.
    private static let contentRoles: Set<String> = ["AXStaticText", "AXCell", "AXImage", "AXRow"]

    private static func clickableRole(_ role: String) -> Bool {
        interactiveRoles.contains(role) || contentRoles.contains(role)
    }

    static func isTextInput(_ role: String) -> Bool {
        role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
    }

    /// Walks the AX tree and keeps the single best label match instead of the first
    /// hit, so "chat" prefers the actual input over a "Chat" heading that appears
    /// earlier in tree order. Bounded depth + per-node cancellation like before.
    private static func findBestElement(in element: AXUIElement, matching needle: String,
                                        depth: Int, budget: inout Int, best: inout ElementMatch?) throws {
        if depth > 40 || budget <= 0 { return } // bound pathological / huge trees
        budget -= 1
        try Task.checkCancellation()

        if let role = string(element, kAXRoleAttribute), clickableRole(role),
           let label = descriptiveText(of: element)?.lowercased(), !label.isEmpty {
            let s = elementMatchScore(label: label, needle: needle, depth: depth, isTextInput: isTextInput(role))
            if s > 0, best == nil || s > best!.score {
                best = ElementMatch(element: element, role: role, score: s)
            }
        }
        for child in children(of: element) {
            try findBestElement(in: child, matching: needle, depth: depth + 1, budget: &budget, best: &best)
        }
    }

    /// Pure scorer (testable). Exact label beats prefix beats substring; ties break
    /// toward text inputs (typing targets) and then shallower/more-prominent nodes.
    static func elementMatchScore(label: String, needle: String, depth: Int, isTextInput: Bool) -> Int {
        let base: Int
        if label == needle { base = 300 }
        else if label.hasPrefix(needle) { base = 200 }
        else if label.contains(needle) { base = 100 }
        else { return 0 }
        return base + (isTextInput ? 20 : 0) - min(depth, 40)
    }

    private static func descriptiveText(of element: AXUIElement) -> String? {
        // Placeholder before value so an *empty* field (a chat box, a search box)
        // is still identifiable by its prompt ("Ask Copilot…") rather than vanishing
        // — that's exactly the field a "type in the chat" command targets.
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute] {
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

    /// kAXURLAttribute returns a CFURL, not a String — casting to String (as the
    /// generic helper does) silently yields nil, so URL reads need this.
    private static func axURL(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let u = value as? URL { return u.absoluteString }
        if let u = value as? NSURL { return u.absoluteString }
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

    // MARK: - Vision click (screenshot fallback when AX finds nothing)

    /// Clicks a global screen point directly (used by the vision fallback, which
    /// has pixel coordinates rather than an AX element).
    static func clickAt(_ point: CGPoint) { clickMouse(at: point) }

    /// Maps a normalized (0…1, top-left origin) point within a display to a global
    /// screen point in Quartz coordinates — the same space CGEvent posts into, so
    /// the result is directly clickable. Pure, so it's unit-tested.
    static func normalizedToScreen(x: Double, y: Double, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + CGFloat(x) * frame.width,
                y: frame.minY + CGFloat(y) * frame.height)
    }

    /// Captures the display holding the frontmost window as a base64 PNG plus that
    /// display's global frame (for mapping the model's normalized answer back to a
    /// clickable point). Downscaled to ≤1568px long edge to keep the upload small;
    /// normalized coordinates make the downscale irrelevant to accuracy. Returns
    /// nil if Screen Recording isn't granted — the caller then reports the original
    /// AX miss instead of a phantom click.
    static func captureDisplayForFrontWindow() async -> (pngBase64: String, frame: CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        // The target of a click is the frontmost *controlled* app's window, which may
        // be on a different display than this menu-bar app's NSScreen.main. Pick the
        // display that actually contains that window; fall back to key screen, then any.
        let focusedID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let windowCenter = frontWindowCenter()
        let display = content.displays.first(where: { d in
            windowCenter.map { CGDisplayBounds(d.displayID).contains($0) } ?? false
        }) ?? content.displays.first(where: { $0.displayID == focusedID }) ?? content.displays.first
        guard let display else { return nil }
        let longEdge = max(display.width, display.height)
        let scale = longEdge > 1568 ? 1568.0 / Double(longEdge) : 1.0
        let config = SCStreamConfiguration()
        config.width = Int((Double(display.width) * scale).rounded())
        config.height = Int((Double(display.height) * scale).rounded())
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let png = pngBase64(from: cg) else { return nil }
        return (png, CGDisplayBounds(display.displayID))
    }

    /// The focused window frame of a given app (or the frontmost app), in AX/Quartz
    /// global coordinates (top-left origin). Used to anchor the recorder pill to the
    /// window the user is working in. nil if the app has no readable focused window.
    static func windowFrame(for app: NSRunningApplication?) -> CGRect? {
        guard let app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let ref = winRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let window = ref as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Global-coordinate center of the frontmost app's focused window, for choosing
    /// which display to screenshot. AX positions are already in Quartz global space.
    private static func frontWindowCenter() -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let window = winRef as! AXUIElement? else { return nil }
        return center(of: window)
    }

    private static func pngBase64(from cg: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }
}
