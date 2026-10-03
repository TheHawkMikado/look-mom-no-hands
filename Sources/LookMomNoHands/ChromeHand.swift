import Foundation
import Network
import AppKit
import Combine

// The browser-side hand. A Chrome extension (chrome-extension/ in the repo,
// bundled into the app) keeps one WebSocket open to this loopback server. On
// request it reads the live page as a numbered map — every link, button,
// field, heading, with a ref like "e12" — and clicks, types, selects or
// scrolls by that ref. The planner then acts on exact elements instead of
// guessing from a screenshot. Loopback only; paired with a short code the user
// types into the extension once. Page content goes where the Accessibility
// snapshot already goes (into the planner prompt) and nowhere else.

@MainActor
final class ChromeHand: ObservableObject {
    static let defaultPort: UInt16 = 47831
    static let enabledKey = "chrome-hand-enabled"
    static let tokenKey = "chrome-hand-token"

    @Published private(set) var isConnected = false
    @Published private(set) var extensionVersion = ""
    @Published private(set) var lastError = ""
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { start() } else { stop() }
        }
    }
    /// The pairing code shown in Settings and typed into the extension popup.
    let token: String
    let port: UInt16
    var log: (String) -> Void = { _ in }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    struct HandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(port: UInt16 = ChromeHand.defaultPort, defaults: UserDefaults = .standard) {
        self.port = port
        if let existing = defaults.string(forKey: Self.tokenKey), !existing.isEmpty {
            token = existing
        } else {
            let fresh = Self.makeToken()
            defaults.set(fresh, forKey: Self.tokenKey)
            token = fresh
        }
        enabled = defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
    }

    // MARK: - Server

    func start() {
        guard enabled, listener == nil else { return }
        do {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            // Loopback only: the extension on this Mac is the sole client.
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        self.lastError = "listener failed: \(error)"
                        self.log(self.lastError)
                        self.listener = nil
                    case .ready:
                        self.log("listening on 127.0.0.1:\(self.port) for the Chrome extension")
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = "could not listen on port \(port): \(error)"
            log(lastError)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dropConnection()
    }

    private func accept(_ conn: NWConnection) {
        // One extension at a time; a reconnect replaces the stale socket.
        dropConnection()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                switch state {
                case .failed, .cancelled: self.dropConnection()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receiveLoop(conn)
    }

    private func dropConnection() {
        guard let conn = connection else { return }
        connection = nil
        conn.cancel()
        isConnected = false
        failAllPending(HandError(message: "the Chrome extension disconnected"))
        log("extension disconnected")
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .close {
                    self.dropConnection()
                    return
                }
                if let data, !data.isEmpty { self.handle(data, from: conn) }
                if error != nil { self.dropConnection(); return }
                self.receiveLoop(conn)
            }
        }
    }

    private func send(_ object: [String: Any], over conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "lmnh", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ data: Data, from conn: NWConnection) {
        guard let message = Self.decodeFrame(data) else { return }
        if let type = message["type"] as? String {
            switch type {
            case "hello":
                let offered = Self.normalizeToken((message["token"] as? String) ?? "")
                guard offered == token else {
                    log("extension offered a wrong pairing code — refused")
                    send(["type": "unauthorized"], over: conn)
                    conn.cancel()
                    return
                }
                extensionVersion = (message["version"] as? String) ?? ""
                isConnected = true
                lastError = ""
                send(["type": "hello_ok"], over: conn)
                log("Chrome extension \(extensionVersion) connected")
            default: break
            }
            return
        }
        guard let id = message["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? String {
            cont.resume(throwing: HandError(message: error))
        } else {
            cont.resume(returning: (message["result"] as? [String: Any]) ?? [:])
        }
    }

    /// One request to the extension. Throws when it is not connected, when it
    /// reports an error, or after `timeout` seconds of silence.
    func call(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard isConnected, let conn = connection else {
            throw HandError(message: "the Chrome extension is not connected")
        }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { cont in
            begin(id: id, method: method, params: params, over: conn, timeout: timeout, cont)
        }
    }

    /// Registers the continuation and sends, in one isolated call (the
    /// MCPConnection pattern): the reply can only ever find its waiter.
    private func begin(id: Int, method: String, params: [String: Any], over conn: NWConnection,
                       timeout: TimeInterval, _ cont: CheckedContinuation<[String: Any], Error>) {
        pending[id] = cont
        send(["id": id, "method": method, "params": params], over: conn)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.expire(id, method: method)
        }
    }

    private func expire(_ id: Int, method: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: HandError(message: "\(method) timed out"))
        }
    }

    // MARK: - Page API

    func pageMap(maxElements: Int = 120) async throws -> PageMap {
        let result = try await call("page.map", params: ["maxElements": maxElements, "textChars": 1200])
        return try PageMap.decode(result)
    }

    func bestMatch(for query: String) async throws -> Match? {
        let result = try await call("page.find", params: ["query": query])
        let raw = (result["matches"] as? [[String: Any]]) ?? []
        let data = try JSONSerialization.data(withJSONObject: raw)
        let matches = try JSONDecoder().decode([Match].self, from: data)
        return Self.pick(matches)
    }

    func click(ref: String) async throws {
        _ = try await call("page.click", params: ["ref": ref])
    }

    func type(_ text: String, ref: String?, submit: Bool = false) async throws {
        var params: [String: Any] = ["text": text, "submit": submit]
        if let ref { params["ref"] = ref }
        _ = try await call("page.type", params: params)
    }

    func select(ref: String, value: String) async throws {
        _ = try await call("page.select", params: ["ref": ref, "value": value])
    }

    func scroll(_ direction: String) async throws {
        _ = try await call("page.scroll", params: ["direction": direction])
    }

    func press(_ key: String) async throws {
        _ = try await call("page.press", params: ["key": key])
    }

    func pageText(maxChars: Int = 12000) async throws -> String {
        let result = try await call("page.text", params: ["maxChars": maxChars])
        return (result["text"] as? String) ?? ""
    }

    // MARK: - Pure helpers (unit-tested)

    /// A match only counts when it is clearly the best: strong on its own and
    /// not tied with a runner-up, so a vague target falls through to the
    /// Accessibility/vision ladder instead of clicking the wrong thing.
    nonisolated static func pick(_ matches: [Match]) -> Match? {
        guard let top = matches.first, top.score >= 60 else { return nil }
        if matches.count > 1, matches[1].score == top.score, top.score < 100 { return nil }
        return top
    }

    nonisolated static func decodeFrame(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "e12", "[e12]", "E12" or "[e12] button Send" → "e12"; a description → nil.
    nonisolated static func ref(in target: String) -> String? {
        let lower = target.lowercased()
        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let hit = tokens.first(where: { t in
            t.count >= 2 && t.count <= 5 && t.first == "e" && t.dropFirst().allSatisfy(\.isNumber)
        }) else { return nil }
        return (tokens.count == 1 || lower.contains("[")) ? hit : nil
    }

    /// Whatever the user typed or pasted — spaces, hyphens, lowercase — down to
    /// the six characters that matter.
    nonisolated static func normalizeToken(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Six characters, no look-alikes (0/O, 1/I/L), so it survives being read aloud.
    nonisolated static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    nonisolated static var chromiumBundlePrefixes: [String] {
        ["com.google.chrome", "com.brave.browser", "com.microsoft.edgemac",
         "company.thebrowser.browser", "com.vivaldi.vivaldi", "org.chromium.chromium", "com.operasoftware.opera"]
    }

    nonisolated static func isChromiumBrowser(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return chromiumBundlePrefixes.contains { id.hasPrefix($0) }
    }

    static var frontIsChromium: Bool {
        isChromiumBrowser(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    // MARK: - Install

    /// Where the unpacked extension lives for Chrome to load: a copy outside the
    /// signed bundle (so an app update doesn't move it from under Chrome) that is
    /// refreshed whenever the bundled copy changes. Lives beside the app's own
    /// data in ~/Library/Application Support/LookMaNoHands/.
    static var installedExtensionURL: URL {
        supportDirectory.appendingPathComponent("LookMaNoHands/chrome-extension", isDirectory: true)
    }

    /// The first release put the copy under a misspelled folder. Anyone who
    /// loaded the extension from there keeps a working, up-to-date copy at that
    /// path until they re-load it from the right one; nothing breaks mid-task.
    static var legacyExtensionURL: URL {
        supportDirectory.appendingPathComponent("LookMomNoHands/chrome-extension", isDirectory: true)
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    @discardableResult
    static func installExtensionCopy() -> URL? {
        let fm = FileManager.default
        let dest = installedExtensionURL
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension", isDirectory: true),
              fm.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) else {
            return fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) ? dest : nil
        }
        let synced = sync(bundled, to: dest)
        if fm.fileExists(atPath: legacyExtensionURL.appendingPathComponent("manifest.json").path) {
            _ = sync(bundled, to: legacyExtensionURL)
        }
        return synced ? dest : (fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) ? dest : nil)
    }

    /// Copies `source` over `dest` when their load-bearing files differ. True
    /// when `dest` is usable afterwards.
    private static func sync(_ source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        let stamp = { (dir: URL) -> Data in
            ["manifest.json", "background.js", "content.js", "popup.js", "popup.html"]
                .compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
                .reduce(Data(), +)
        }
        if fm.fileExists(atPath: dest.path), stamp(dest) == stamp(source) { return true }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            return true
        } catch {
            return fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path)
        }
    }
}

// MARK: - Page model

struct PageElement: Codable, Sendable, Equatable {
    let ref: String
    let role: String
    let name: String
    var href: String?
    var value: String?
    var placeholder: String?
    var options: [String]?
    var state: [String]?
    var inView: Bool?
    var frame: String?

    /// One line the planner can act on: `[e4] button "Sign in"`.
    var promptLine: String {
        var s = "[\(ref)] \(role)"
        if !name.isEmpty { s += " \"\(name)\"" }
        if let href, !href.isEmpty, href != name { s += " → \(href)" }
        var notes: [String] = []
        if ["textbox", "searchbox", "combobox", "spinbutton"].contains(role) {
            if let value, !value.isEmpty { notes.append("= \"\(value)\"") } else { notes.append("empty") }
        } else if let value, !value.isEmpty {
            notes.append("= \"\(value)\"")
        }
        if let placeholder, !placeholder.isEmpty { notes.append("placeholder \"\(placeholder)\"") }
        if let options, !options.isEmpty { notes.append("options: \(options.joined(separator: ", "))") }
        if let state, !state.isEmpty { notes.append(state.joined(separator: ", ")) }
        if inView == false { notes.append("offscreen") }
        if let frame, !frame.isEmpty { notes.append("in \(frame)") }
        if !notes.isEmpty { s += " (\(notes.joined(separator: "; ")))" }
        return s
    }
}

struct PageMap: Codable, Sendable {
    let url: String
    let title: String
    let elements: [PageElement]
    var headings: [String]?
    var text: String?
    var total: Int?

    static func decode(_ object: [String: Any]) throws -> PageMap {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PageMap.self, from: data)
    }

    /// The screen block for the planner. Mirrors ScreenController.Snapshot.promptText
    /// so the model reads it the same way, plus the refs that make clicks exact.
    var promptText: String {
        var s = "On screen now: Chrome — \(title)"
        if !url.isEmpty { s += " (\(url))" }
        s += "\nRead by the Chrome extension: every element below has an exact ref. To click one, emit a click step whose target is the ref (e.g. \"e12\"). To type into a field, emit a type step with the field's ref as target and the text."
        if elements.isEmpty {
            s += "\n(no interactive elements found on this page)"
        } else {
            s += "\nPage elements:"
            for e in elements { s += "\n" + e.promptLine }
            if let total, total > elements.count {
                s += "\n(\(total - elements.count) more elements not listed — scroll to see them)"
            }
        }
        if let headings, !headings.isEmpty {
            s += "\nHeadings: " + headings.prefix(8).joined(separator: " | ")
        }
        if let text, !text.isEmpty {
            s += "\nPage text (excerpt): \(text)"
        }
        return s
    }
}

struct Match: Codable, Sendable, Equatable {
    let ref: String
    let role: String
    let name: String
    let score: Int
}
