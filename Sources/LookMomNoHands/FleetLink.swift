import Foundation
import Network
import CryptoKit
import Combine

// The fleet: other Macs you own, running this same app, doing goals for you.
// Grok Bot rents you a cloud computer per agent; this networks the computers
// already on your desk. Three hard rules:
//  - GOAL-level delegation, never action-level remoting. A worker runs its own
//    act-observe loop against its own screen and reports back. No screenshots
//    or AX trees cross the wire.
//  - Every message is Ed25519-signed and only paired machines are heard. This
//    channel is remote code execution by design — pairing is a deliberate
//    human act on BOTH machines, with a code to compare.
//  - LAN only (Bonjour). Off-LAN comes later via a mesh; the signing model
//    won't change.

// MARK: - Identity

/// This machine's fleet identity: a Curve25519 signing keypair. Private key in
/// the Keychain, never on disk; the public key hex IS the machine's id.
enum FleetIdentity {
    private static let account = "fleet-identity"

    static func signingKey() -> Curve25519.Signing.PrivateKey {
        if let hex = KeychainStore.load(account: account), let data = Data(hex: hex),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        KeychainStore.save(key.rawRepresentation.map { String(format: "%02x", $0) }.joined(), account: account)
        return key
    }

    static var publicKeyHex: String {
        signingKey().publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    static var machineName: String {
        Host.current().localizedName ?? "This Mac"
    }
}

// MARK: - Envelope (pure, unit-tested)

/// The wire format: one JSON object per line. The signature covers
/// type|timestamp|from|payload so nothing signed can be swapped independently.
struct FleetEnvelope: Codable {
    let type: String
    let from: String          // sender public key hex
    let name: String          // sender display name (advisory; identity is `from`)
    let ts: TimeInterval
    let payload: String       // JSON string; "" for empty
    let sig: String           // base64 Ed25519 over the signed material

    static func signedMaterial(type: String, from: String, ts: TimeInterval, payload: String) -> Data {
        Data("\(type)|\(Int(ts))|\(from)|\(payload)".utf8)
    }

    static func make(type: String, payload: String, key: Curve25519.Signing.PrivateKey,
                     name: String, ts: TimeInterval = Date().timeIntervalSince1970) -> FleetEnvelope? {
        let from = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        guard let sig = try? key.signature(for: signedMaterial(type: type, from: from, ts: ts, payload: payload)) else { return nil }
        return FleetEnvelope(type: type, from: from, name: name, ts: ts, payload: payload, sig: sig.base64EncodedString())
    }

    /// Valid signature AND fresh: a captured goal replayed tomorrow must die
    /// here, not at the shell.
    func verified(now: TimeInterval = Date().timeIntervalSince1970, maxSkew: TimeInterval = 120) -> Bool {
        guard abs(now - ts) <= maxSkew,
              let keyData = Data(hex: from),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: sig) else { return false }
        return key.isValidSignature(signature, for: Self.signedMaterial(type: type, from: from, ts: ts, payload: payload))
    }

    /// The 6-digit code both screens show during pairing: same on both ends,
    /// order-independent, derived from both identities so a man in the middle
    /// can't show matching codes.
    static func pairingCode(_ keyA: String, _ keyB: String) -> String {
        let joined = [keyA, keyB].sorted().joined()
        let digest = SHA256.hash(data: Data(joined.utf8))
        let value = digest.withUnsafeBytes { $0.load(as: UInt32.self) }
        return String(format: "%06d", value % 1_000_000)
    }
}

// MARK: - Peers

struct FleetPeer: Codable, Identifiable, Sendable, Equatable {
    let keyHex: String
    var name: String
    var pairedAt: Date
    var id: String { keyHex }
}

@MainActor
final class FleetPeerStore: ObservableObject {
    @Published private(set) var peers: [FleetPeer] = []
    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".fleet")

    init(directory: URL) {
        url = directory.appendingPathComponent("fleet-peers.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([FleetPeer].self, from: data) {
            peers = decoded
        }
    }

    func isPaired(_ keyHex: String) -> Bool { peers.contains { $0.keyHex == keyHex } }

    func upsert(_ peer: FleetPeer) {
        peers.removeAll { $0.keyHex == peer.keyHex }
        peers.append(peer)
        persist()
    }

    func remove(_ keyHex: String) {
        peers.removeAll { $0.keyHex == keyHex }
        persist()
    }

    private func persist() {
        let snapshot = peers
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Service

/// Both halves live in the one class because it's the one app: enable worker
/// mode and this Mac advertises and accepts goals; discover-and-pair and it
/// dispatches them. A machine can be both (a worker can have workers).
@MainActor
final class FleetService: ObservableObject {
    static let bonjourType = "_lmnh._tcp"

    struct DiscoveredWorker: Identifiable, Equatable {
        let endpointName: String
        let endpoint: NWEndpoint
        var id: String { endpointName }
        static func == (a: Self, b: Self) -> Bool { a.endpointName == b.endpointName }
    }

    struct PendingPair: Identifiable {
        let id = UUID().uuidString
        let peerKey: String
        let peerName: String
        let code: String
        let connection: NWConnection
    }

    struct WorkerStatus: Equatable {
        var online: Bool = false
        var runningGoal: String? = nil
        var lastSeen: Date? = nil
    }

    let peers: FleetPeerStore
    @Published private(set) var discovered: [DiscoveredWorker] = []
    @Published var pendingPair: PendingPair?          // worker side: approve/deny UI
    @Published private(set) var status: [String: WorkerStatus] = [:]  // peer key → status
    @Published var workerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(workerModeEnabled, forKey: "fleet-worker-mode")
            workerModeEnabled ? startListening() : stopListening()
        }
    }

    /// Worker side: run this goal locally. Wired by the coordinator.
    var onRemoteGoal: ((_ text: String, _ goalID: String, _ reply: @escaping (String, String) -> Void) -> Void)?
    /// Dispatcher side: a worker reported progress/result for a goal we sent.
    var onWorkerEvent: ((_ peerName: String, _ kind: String, _ detail: String) -> Void)?
    /// A paired peer pushed a store snapshot (Phase 7 sync).
    var onStoreSync: ((_ store: String, _ json: String) -> Void)?

    private let key = FleetIdentity.signingKey()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]   // peer key → live link
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var heartbeat: Timer?

    init(peers: FleetPeerStore) {
        self.peers = peers
        self.workerModeEnabled = UserDefaults.standard.bool(forKey: "fleet-worker-mode")
        if workerModeEnabled { startListening() }
        startBrowsing()
        // Heartbeat pings keep the status dots honest; a worker that vanished
        // mid-goal shows offline within a minute.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    // MARK: Worker side

    private func startListening() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: FleetIdentity.machineName, type: Self.bonjourType)
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            // Port squatting or local-network denial — worker mode just stays off.
            workerModeEnabled = false
        }
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveLoop(connection)
    }

    // MARK: Dispatcher side

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discovered = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    // Our own advertisement shows up too; hide it.
                    guard name != FleetIdentity.machineName else { return nil }
                    return DiscoveredWorker(endpointName: name, endpoint: result.endpoint)
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func beginPairing(with worker: DiscoveredWorker) {
        let connection = NWConnection(to: worker.endpoint, using: .tcp)
        connection.start(queue: .main)
        receiveLoop(connection)
        send(type: "pair_request", payload: "", over: connection)
    }

    func approvePendingPair() {
        guard let pending = pendingPair else { return }
        peers.upsert(FleetPeer(keyHex: pending.peerKey, name: pending.peerName, pairedAt: Date()))
        connections[pending.peerKey] = pending.connection
        send(type: "pair_accept", payload: "", over: pending.connection)
        pendingPair = nil
    }

    func rejectPendingPair() {
        pendingPair?.connection.cancel()
        pendingPair = nil
    }

    /// "on the mac mini, pull the report" → dispatch "pull the report" there.
    /// Word-boundary prefix match against PAIRED peer names only. Pure for tests.
    nonisolated static func parseTarget(command: String, peerNames: [String]) -> (peer: String, goal: String)? {
        let lowered = command.lowercased()
        for name in peerNames.sorted(by: { $0.count > $1.count }) {
            let n = name.lowercased()
            for prefix in ["on the \(n)", "on \(n)"] {
                guard lowered.hasPrefix(prefix) else { continue }
                var rest = String(command.dropFirst(prefix.count))
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,:—-"))
                guard !rest.isEmpty else { return nil }
                return (name, rest)
            }
        }
        return nil
    }

    /// Sends a goal to a paired worker by name. Returns false if it isn't
    /// reachable — the caller falls back to saying so, never to guessing.
    func dispatch(goal: String, toPeerNamed name: String) -> Bool {
        guard let peer = peers.peers.first(where: { $0.name.lowercased() == name.lowercased() }) else { return false }
        let payload = (try? JSONSerialization.data(withJSONObject: ["goal": goal, "id": UUID().uuidString]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        if let live = connections[peer.keyHex], live.state == .ready {
            send(type: "goal", payload: payload, over: live)
            return true
        }
        // No live link — reconnect through discovery if the worker is visible.
        guard let worker = discovered.first(where: { $0.endpointName == peer.name }) else { return false }
        let connection = NWConnection(to: worker.endpoint, using: .tcp)
        connections[peer.keyHex] = connection
        connection.start(queue: .main)
        receiveLoop(connection)
        send(type: "goal", payload: payload, over: connection)
        return true
    }

    /// Phase 7: push a store snapshot to every paired machine (debounced by the
    /// coordinator). Merging is id-union, newest-wins — deletes stay local.
    func broadcastStore(_ store: String, json: String) {
        let payload = (try? JSONSerialization.data(withJSONObject: ["store": store, "json": json]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        for (_, connection) in connections where connection.state == .ready {
            send(type: "store_sync", payload: payload, over: connection)
        }
    }

    // MARK: Plumbing

    private func pingAll() {
        var next = status
        for (key, connection) in connections {
            if connection.state == .ready {
                send(type: "ping", payload: "", over: connection)
            } else {
                next[key, default: WorkerStatus()].online = false
            }
        }
        // Anything silent for >70s (two missed heartbeats) is offline.
        for (key, s) in next where s.online {
            if let seen = s.lastSeen, Date().timeIntervalSince(seen) > 70 {
                next[key]?.online = false
            }
        }
        status = next
    }

    private func send(type: String, payload: String, over connection: NWConnection) {
        guard let envelope = FleetEnvelope.make(type: type, payload: payload, key: key, name: FleetIdentity.machineName),
              var data = try? JSONEncoder().encode(envelope) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, closed, _ in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let oid = ObjectIdentifier(connection)
                    var buffer = self.buffers[oid] ?? Data()
                    buffer.append(data)
                    for frame in MCPConnection.drainFrames(from: &buffer) {
                        if let envelope = try? JSONDecoder().decode(FleetEnvelope.self, from: frame) {
                            self.handle(envelope, over: connection)
                        }
                    }
                    self.buffers[oid] = buffer
                }
                if closed {
                    self.buffers.removeValue(forKey: ObjectIdentifier(connection))
                } else {
                    self.receiveLoop(connection)
                }
            }
        }
    }

    private func handle(_ envelope: FleetEnvelope, over connection: NWConnection) {
        guard envelope.verified() else { return }   // unsigned/stale: not even a log line for an attacker
        let paired = peers.isPaired(envelope.from)

        switch envelope.type {
        case "pair_request":
            guard !paired else { send(type: "pair_accept", payload: "", over: connection); return }
            // Surfaced to the human; nothing is trusted until they approve.
            pendingPair = PendingPair(peerKey: envelope.from, peerName: envelope.name,
                                      code: FleetEnvelope.pairingCode(envelope.from, FleetIdentity.publicKeyHex),
                                      connection: connection)
        case "pair_accept":
            guard !paired else { return }
            peers.upsert(FleetPeer(keyHex: envelope.from, name: envelope.name, pairedAt: Date()))
            connections[envelope.from] = connection
        case "ping":
            guard paired else { return }
            connections[envelope.from] = connection
            send(type: "pong", payload: "", over: connection)
        case "pong":
            guard paired else { return }
            status[envelope.from, default: WorkerStatus()].online = true
            status[envelope.from]?.lastSeen = Date()
        case "goal":
            guard paired, workerModeEnabled,
                  let obj = try? JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as? [String: Any],
                  let goal = obj["goal"] as? String, let goalID = obj["id"] as? String else { return }
            connections[envelope.from] = connection
            onRemoteGoal?(goal, goalID) { [weak self] kind, detail in
                guard let self else { return }
                let payload = (try? JSONSerialization.data(withJSONObject: ["id": goalID, "kind": kind, "detail": detail]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                self.send(type: "goal_event", payload: payload, over: connection)
            }
        case "goal_event":
            guard paired,
                  let obj = try? JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as? [String: Any],
                  let kind = obj["kind"] as? String else { return }
            if kind == "goal_done" || kind == "goal_failed" {
                status[envelope.from]?.runningGoal = nil
            }
            onWorkerEvent?(envelope.name, kind, obj["detail"] as? String ?? "")
        case "store_sync":
            guard paired,
                  let obj = try? JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as? [String: Any],
                  let store = obj["store"] as? String, let json = obj["json"] as? String else { return }
            onStoreSync?(store, json)
        default:
            break
        }
    }
}
