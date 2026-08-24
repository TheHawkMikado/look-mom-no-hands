import Foundation
import Combine

// The API escape hatch: connected MCP servers give the planner real tools
// (Gmail, Notion, Slack, …) so a task that HAS an API stops being ten fragile
// clicks. UI automation stays the universal fallback — this only shortcuts what
// a server genuinely covers. Hand-rolled JSON-RPC over stdio because the repo
// takes no dependencies; MCP's stdio transport is just newline-delimited
// JSON-RPC 2.0.

/// One configured server. `command` is a full shell line ("npx -y
/// @modelcontextprotocol/server-slack") run through zsh -lc so the user's PATH
/// (node, homebrew) applies. Secret env values live in the Keychain under
/// mcp.<id>.<KEY> — the JSON on disk stores only the key NAMES.
struct MCPServerConfig: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String          // short label, becomes the tool prefix ("slack.send_message")
    var command: String
    var envKeys: [String]     // env var names whose values are in the Keychain
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, command: String, envKeys: [String] = [], enabled: Bool = true) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.envKeys = envKeys
        self.enabled = enabled
    }

    func environment() -> [String: String] {
        var env: [String: String] = [:]
        for key in envKeys {
            if let value = KeychainStore.load(account: "mcp.\(id).\(key)") { env[key] = value }
        }
        return env
    }
}

struct MCPTool: Sendable, Equatable {
    let server: String        // config.name
    let name: String
    let description: String
    let schemaJSON: String    // inputSchema, serialized for the planner prompt

    var qualified: String { "\(server).\(name)" }
}

@MainActor
final class MCPStore: ObservableObject {
    @Published private(set) var servers: [MCPServerConfig] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".mcp")

    init(directory: URL) {
        url = directory.appendingPathComponent("mcp-servers.json")
        load()
    }

    func upsert(_ config: MCPServerConfig, secrets: [String: String] = [:]) {
        guard !config.name.isEmpty, !config.command.isEmpty else { return }
        for (key, value) in secrets where !value.isEmpty {
            KeychainStore.save(value, account: "mcp.\(config.id).\(key)")
        }
        if let i = servers.firstIndex(where: { $0.id == config.id }) { servers[i] = config }
        else { servers.append(config) }
        persist()
    }

    func remove(_ id: String) {
        if let config = servers.first(where: { $0.id == id }) {
            for key in config.envKeys { KeychainStore.delete(account: "mcp.\(id).\(key)") }
        }
        servers.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        let snapshot = servers
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// One live server process. An actor: the pending-request table and the read
/// buffer are touched from the pipe's readability handler and from callers.
actor MCPConnection {
    enum MCPError: Error, CustomStringConvertible {
        case launchFailed(String)
        case serverError(String)
        case timeout(String)
        case closed

        var description: String {
            switch self {
            case .launchFailed(let m): return "couldn't start server: \(m)"
            case .serverError(let m): return m
            case .timeout(let m): return "\(m) timed out"
            case .closed: return "server exited"
            }
        }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var alive = false

    init(command: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice   // servers log freely; it's not protocol
        do { try process.run() } catch { throw MCPError.launchFailed(error.localizedDescription) }
        alive = true
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.didClose() }
        }
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        didClose()
    }

    // MARK: Protocol

    func initialize() async throws {
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "LookMomNoHands", "version": "1.0"]
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func listTools(server: String) async throws -> [MCPTool] {
        let result = try await request("tools/list", params: [:])
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = t["inputSchema"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            return MCPTool(server: server,
                           name: name,
                           description: (t["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           schemaJSON: schema.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        }
    }

    /// Returns the tool's text content, or throws with the server's error text —
    /// the planner sees either as this round's outcome and adapts.
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request("tools/call",
                                       params: ["name": name, "arguments": arguments],
                                       timeout: 60)
        let content = (result["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        if result["isError"] as? Bool == true { throw MCPError.serverError(content.isEmpty ? "tool failed" : content) }
        return content
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard alive else { throw MCPError.closed }
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerPending(id: id, cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.failPending(id: id, with: MCPError.timeout(method))
                throw MCPError.timeout(method)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func registerPending(id: Int, _ cont: CheckedContinuation<[String: Any], Error>) {
        guard alive else { cont.resume(throwing: MCPError.closed); return }
        pending[id] = cont
    }

    private func failPending(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        for frame in Self.drainFrames(from: &buffer) {
            guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ message: [String: Any]) {
        // Server-initiated requests/notifications (logging, progress) are out of
        // scope — only responses to our ids matter here.
        guard let id = message["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            cont.resume(throwing: MCPError.serverError(error["message"] as? String ?? "unknown server error"))
        } else {
            cont.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func didClose() {
        alive = false
        for (_, cont) in pending { cont.resume(throwing: MCPError.closed) }
        pending.removeAll()
    }

    /// Newline-delimited framing, pure for tests: complete lines come out, the
    /// trailing partial stays in the buffer.
    nonisolated static func drainFrames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !frame.isEmpty { frames.append(frame) }
        }
        return frames
    }
}

/// Owns configured servers' live connections and exposes their tools to the
/// planner. Connects lazily on first use of each session — most commands never
/// need a server, and npx cold-starts are slow.
@MainActor
final class MCPManager: ObservableObject {
    let store: MCPStore
    private var connections: [String: MCPConnection] = [:]   // config.id → live
    @Published private(set) var tools: [MCPTool] = []
    @Published private(set) var connectionErrors: [String: String] = [:]  // config.id → why

    init(store: MCPStore) {
        self.store = store
    }

    /// "server.tool" → (server, tool). One split on the FIRST dot: tool names
    /// may themselves contain dots.
    nonisolated static func parse(qualified: String) -> (server: String, tool: String)? {
        guard let dot = qualified.firstIndex(of: "."), dot != qualified.startIndex,
              qualified.index(after: dot) != qualified.endIndex else { return nil }
        return (String(qualified[..<dot]), String(qualified[qualified.index(after: dot)...]))
    }

    func connectAll() async {
        for config in store.servers where config.enabled && connections[config.id] == nil {
            await connect(config)
        }
    }

    func connect(_ config: MCPServerConfig) async {
        do {
            let connection = try MCPConnection(command: config.command, environment: config.environment())
            try await connection.initialize()
            let found = try await connection.listTools(server: config.name)
            connections[config.id] = connection
            tools.removeAll { $0.server == config.name }
            tools.append(contentsOf: found)
            connectionErrors[config.id] = nil
        } catch {
            connectionErrors[config.id] = "\(error)"
        }
    }

    func disconnect(_ configID: String) {
        if let name = store.servers.first(where: { $0.id == configID })?.name {
            tools.removeAll { $0.server == name }
        }
        let connection = connections.removeValue(forKey: configID)
        Task { await connection?.shutdown() }
    }

    func shutdown() {
        for id in connections.keys { disconnect(id) }
    }

    func call(qualified: String, argumentsJSON: String) async throws -> String {
        guard let (server, tool) = Self.parse(qualified: qualified),
              let config = store.servers.first(where: { $0.name == server }) else {
            throw MCPConnection.MCPError.serverError("no connected tool named “\(qualified)”")
        }
        if connections[config.id] == nil { await connect(config) }
        guard let connection = connections[config.id] else {
            throw MCPConnection.MCPError.serverError(connectionErrors[config.id] ?? "server offline")
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        return try await connection.callTool(name: tool, arguments: arguments)
    }

    /// The planner-facing tool list. Rides in the per-turn context (NOT the
    /// cached stable block): connecting/removing a server must take effect on
    /// the next command, not whenever the cache happens to roll.
    var promptBlock: String {
        guard !tools.isEmpty else { return "" }
        var lines = ["API tools available (use_tool, target = tool id, text = JSON arguments). Prefer one over driving a website's UI when it covers the task:"]
        for tool in tools.prefix(40) {
            lines.append("• \(tool.qualified): \(tool.description.prefix(120)) — args \(tool.schemaJSON.prefix(300))")
        }
        return lines.joined(separator: "\n")
    }
}
