import Foundation
import Network
import Combine

// The browser runner (SPEC §4.1): a Chrome-family extension reads the live
// page as a ref-based snapshot and acts on refs, so a web step is "click e7"
// resolved by the page itself instead of a screen-label guess resolved through
// the Accessibility tree and a coordinate click. Three hard rules:
//  - The extension EXECUTES; it never plans and never gates. Every step still
//    comes out of the planner and through the Approval Gate on this side.
//  - Page content is DATA. A snapshot goes to the model as what is on screen;
//    nothing a page says can become an instruction (SPEC §12).
//  - Loopback only, and paired. The listener binds 127.0.0.1, accepts only a
//    browser-extension Origin, and the first message must carry the pairing
//    code shown in the dashboard. Anything else is dropped.
// Transport is a WebSocket the extension dials (DECISIONS.md, "The browser
// runner is a paired loopback WebSocket, not native messaging").

// MARK: - Pure protocol (unit-tested)

/// One interactive or context element of a page, as the extension reported it.
struct BrowserElement: Sendable, Equatable {
    let ref: String          // "e12" — valid until the next snapshot
    let role: String         // link, button, textbox, combobox, checkbox, heading, …
    let name: String         // accessible name, ≤100 chars
    let value: String?       // current text / selected option; "••••" for passwords
    let href: String?        // links: path on the same site, full URL elsewhere
    let checked: Bool?
    let disabled: Bool
    let offscreen: Bool
}

/// A page snapshot: what's open, what's clickable, by ref.
struct BrowserSnapshot: Sendable {
    let url: String
    let title: String
    let focused: String?     // ref of the focused element, if listed
    let elements: [BrowserElement]
    let total: Int           // elements on the page before the cap

    static func parse(_ dict: [String: Any]) -> BrowserSnapshot {
        let raw = dict["elements"] as? [[String: Any]] ?? []
        let elements: [BrowserElement] = raw.compactMap { e in
            guard let ref = e["ref"] as? String, let role = e["role"] as? String else { return nil }
            return BrowserElement(
                ref: ref, role: role, name: e["name"] as? String ?? "",
                value: e["value"] as? String, href: e["href"] as? String,
                checked: e["checked"] as? Bool, disabled: e["disabled"] as? Bool ?? false,
                offscreen: e["offscreen"] as? Bool ?? false)
        }
        return BrowserSnapshot(url: dict["url"] as? String ?? "", title: dict["title"] as? String ?? "",
                               focused: dict["focused"] as? String, elements: elements,
                               total: dict["total"] as? Int ?? elements.count)
    }

    /// Rendering for the planner. Same shape the AX snapshot uses, plus refs:
    /// the click executor resolves a ref exactly, so the model is told to put
    /// the ref — not the label — in `target`.
    var promptText: String {
        var s = "On screen now: browser tab \"\(title)\""
        if !url.isEmpty { s += " (\(url))" }
        s += " — read through the No Hands browser extension."
        let listed = elements.filter { !ScreenController.Snapshot.isDistractorElement($0.name) }
        guard !listed.isEmpty else { return s + "\nNo interactive elements found." }
        s += "\nElements (to click one, emit a click step whose target is ITS REF, e.g. \"e7\"; to type into a field, click its ref, then a type step):"
        for e in listed {
            var line = "\n- \(e.ref) \(e.role)"
            if !e.name.isEmpty { line += " \"\(e.name)\"" }
            if let v = e.value, !v.isEmpty { line += " = \"\(v)\"" }
            if let h = e.href, !h.isEmpty, h != e.name { line += " → \(h)" }
            if let c = e.checked { line += c ? " (checked)" : " (unchecked)" }
            if e.disabled { line += " (disabled)" }
            if e.ref == focused { line += " [focused]" }
            if e.offscreen { line += " (offscreen — scroll to it)" }
            s += line
        }
        if total > elements.count { s += "\n(\(total - elements.count) more elements not listed — scroll or ask for a new read)" }
        return s
    }
}

enum BrowserProtocol {
    enum Incoming {
        case hello(token: String, extensionID: String, version: String)
        case ping
        case pong
        case response(id: Int, result: [String: Any], error: String?)
        case event(name: String, payload: [String: Any])
        case unknown
    }

    static func decode(_ data: Data) -> Incoming {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        if let type = obj["type"] as? String {
            switch type {
            case "hello":
                return .hello(token: obj["token"] as? String ?? "",
                              extensionID: obj["extension"] as? String ?? "",
                              version: obj["version"] as? String ?? "")
            case "ping": return .ping
            case "pong": return .pong
            default: return .unknown
            }
        }
        if let id = obj["id"] as? Int {
            return .response(id: id, result: obj["result"] as? [String: Any] ?? [:], error: obj["error"] as? String)
        }
        if let name = obj["event"] as? String {
            var payload = obj; payload["event"] = nil
            return .event(name: name, payload: payload)
        }
        return .unknown
    }

    static func encodeRequest(id: Int, method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    /// Constant-time compare of the pairing code, so a wrong code can't be
    /// narrowed down by timing.
    static func acceptsHello(token: String, expected: String) -> Bool {
        let a = Array(token.utf8), b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Only a browser extension may open the socket — a web page's WebSocket
    /// carries an http(s) Origin and is refused at the handshake.
    static func acceptsOrigin(_ origin: String) -> Bool {
        let o = origin.lowercased()
        return o.hasPrefix("chrome-extension://") || o.hasPrefix("moz-extension://") || o.hasPrefix("safari-web-extension://")
    }

    /// The ref in a planner click target: "e7", "[e7]", "e7 Search", "ref e7".
    /// nil for an ordinary label — those take the Accessibility path.
    static func ref(in target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:ref\s+)?\[?(e\d{1,4})\]?(?:[\s:,)]|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t) else { return nil }
        return String(t[r])
    }

    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isChromiumBrowser(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return chromiumBundleIDs.contains(id)
    }

    static func pairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

enum BrowserBridgeError: Error, CustomStringConvertible {
    case disconnected
    case timeout(String)
    case remote(String)
    case badReply(String)

    var description: String {
        switch self {
        case .disconnected: return "the browser extension isn't connected"
        case .timeout(let m): return "the browser extension didn't answer \(m) in time"
        case .remote(let m): return m
        case .badReply(let m): return "unexpected reply from the browser extension: \(m)"
        }
    }
}

// MARK: - The bridge

@MainActor
final class BrowserBridge: ObservableObject {
    @Published private(set) var isConnected = false     // a paired extension is on the line
    @Published private(set) var extensionID = ""
    @Published private(set) var extensionVersion = ""
    @Published private(set) var listening = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastNavigatedURL = ""

    static let defaultPort: UInt16 = 47831
    private static let pairingAccount = "browser-bridge-pairing"

    let port: UInt16
    /// Shown in the dashboard; typed once into the extension's popup. Kept in
    /// the Keychain so it survives reinstalls of the app.
    let pairingCode: String
    var log: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: AppIdentity.storeQueueLabel + ".browser")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1

    init(port: UInt16 = BrowserBridge.defaultPort) {
        self.port = port
        if let code = KeychainStore.load(account: Self.pairingAccount), code.count == 6 {
            pairingCode = code
        } else {
            let code = BrowserProtocol.pairingCode()
            KeychainStore.save(code, account: Self.pairingAccount)
            pairingCode = code
        }
    }

    // MARK: Listening

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.setClientRequestHandler(queue) { request in
                let origin = request.additionalHeaders.first { $0.name.lowercased() == "origin" }?.value ?? ""
                let ok = BrowserProtocol.acceptsOrigin(origin)
                return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
            }
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "couldn't listen on 127.0.0.1:\(port): \(error)"
            log(lastError ?? "")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        listening = false
        isConnected = false
        failPending(BrowserBridgeError.disconnected)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listening = true
            log("listening for the browser extension on 127.0.0.1:\(port)")
        case .failed(let error):
            listening = false
            lastError = "listener failed: \(error)"
            log(lastError ?? "")
            listener = nil
        case .cancelled:
            listening = false
        default: break
        }
    }

    private func accept(_ conn: NWConnection) {
        // One extension at a time; a fresh connection replaces a stale one.
        connection?.cancel()
        connection = conn
        isConnected = false
        failPending(BrowserBridgeError.disconnected)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.connectionChanged(state, conn) }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func connectionChanged(_ state: NWConnection.State, _ conn: NWConnection) {
        guard connection === conn else { return }
        switch state {
        case .failed(let error): drop(conn, reason: "\(error)")
        case .cancelled: drop(conn, reason: "closed")
        default: break
        }
    }

    private func drop(_ conn: NWConnection, reason: String) {
        guard connection === conn else { return }
        if isConnected { log("browser extension disconnected (\(reason))") }
        connection = nil
        isConnected = false
        failPending(BrowserBridgeError.disconnected)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty { self.handle(data, from: conn) }
                if let error { self.drop(conn, reason: "\(error)") } else { self.receive(on: conn) }
            }
        }
    }

    private func handle(_ data: Data, from conn: NWConnection) {
        switch BrowserProtocol.decode(data) {
        case .hello(let token, let ext, let version):
            if BrowserProtocol.acceptsHello(token: token, expected: pairingCode) {
                extensionID = ext
                extensionVersion = version
                isConnected = true
                lastError = nil
                log("browser extension \(ext) v\(version) paired")
                send(["type": "welcome"], over: conn)
            } else {
                lastError = "an extension sent the wrong pairing code"
                log("browser extension \(ext) sent a wrong pairing code — refused")
                send(["type": "bye"], over: conn)
                conn.cancel()
            }
        case .ping:
            send(["type": "pong"], over: conn)
        case .pong:
            break
        case .response(let id, let result, let error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error { cont.resume(throwing: BrowserBridgeError.remote(error)) }
            else { cont.resume(returning: result) }
        case .event(let name, let payload):
            if name == "navigated", let url = payload["url"] as? String { lastNavigatedURL = url }
        case .unknown:
            break
        }
    }

    private func send(_ object: [String: Any], over conn: NWConnection) {
        guard let data = BrowserProtocol.encode(object) else { return }
        sendRaw(data, over: conn)
    }

    private func sendRaw(_ data: Data, over conn: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }

    // MARK: Requests

    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard isConnected, let conn = connection else { throw BrowserBridgeError.disconnected }
        let id = nextID
        nextID += 1
        let data = try BrowserProtocol.encodeRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = cont
            sendRaw(data, over: conn)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.timeOut(id: id, method: method)
            }
        }
    }

    private func timeOut(id: Int, method: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: BrowserBridgeError.timeout(method))
    }

    // MARK: Typed API used by the coordinator

    func snapshot(maxElements: Int = 120) async throws -> BrowserSnapshot {
        BrowserSnapshot.parse(try await request("snapshot", params: ["max": maxElements]))
    }

    func click(ref: String) async throws {
        _ = try await request("click", params: ["ref": ref])
    }

    /// Types into `ref`, or into whatever the page has focused when nil.
    /// Throws when nothing editable is focused, so the caller can fall back to
    /// key events. A trailing newline means "and press Enter", as it does when
    /// the same text is typed key by key.
    func type(text: String, ref: String? = nil, submit: Bool = false) async throws {
        var body = text
        var enter = submit
        while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast(); enter = true }
        var params: [String: Any] = ["text": body, "submit": enter]
        if let ref { params["ref"] = ref }
        _ = try await request("type", params: params)
    }

    /// Waits until the tab has loaded (and, when known, is on `urlContains`)
    /// and the DOM has gone quiet. Never throws on a timeout — the loop just
    /// observes whatever is there, as the AX path does.
    func waitSettled(urlContains: String?, timeout: TimeInterval) async {
        var params: [String: Any] = ["timeoutMs": Int(timeout * 1000)]
        if let host = urlContains, !host.isEmpty {
            params["urlContains"] = host
            params["navigation"] = true
        }
        _ = try? await request("wait", params: params, timeout: timeout + 3)
    }

    func navigate(url: String) async throws {
        _ = try await request("navigate", params: ["url": url], timeout: 20)
    }

    func activeTab() async throws -> (title: String, url: String) {
        let r = try await request("active_tab")
        return (r["title"] as? String ?? "", r["url"] as? String ?? "")
    }
}
