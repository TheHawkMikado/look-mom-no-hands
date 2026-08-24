import Foundation

/// A headless worker that executes one spoken goal ("build me a script that…")
/// entirely off-screen: its own Claude conversation, a shell, and file access —
/// never the GUI. Same-machine agents deliberately get NO screen actions: they
/// would fight the user (and each other) for the one keyboard and mouse, so
/// anything UI-shaped stays with the foreground act-observe loop. That split is
/// enforced twice — the agent's tool set simply has no UI tool, and commands
/// that could reach the GUI sideways (osascript, open) are refused outright.
@MainActor
final class BackgroundAgent: ObservableObject, Identifiable {

    enum Status: Equatable {
        case running(step: String)
        case waitingApproval(command: String)
        case finished(summary: String, success: Bool)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .running, .waitingApproval: return true
            case .finished, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .running(let s): return s.isEmpty ? "Working…" : s
            case .waitingApproval: return "Waiting for your approval"
            case .finished(_, let ok): return ok ? "Done" : "Stopped"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    /// Agent events the coordinator narrates. Everything else stays in the log.
    enum Event {
        case needsApproval(command: String)
        case finished(summary: String, success: Bool)
        case failed(String)
    }

    let id = UUID().uuidString
    let name: String
    let goal: String
    let startedAt = Date()
    @Published private(set) var status: Status = .running(step: "Starting…")
    @Published private(set) var transcript: [String] = []

    var onEvent: ((BackgroundAgent, Event) -> Void)?

    private let claude: ClaudeClient
    private var loop: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    /// Turn cap: a stuck agent burning Opus tokens in a loop is worse than a
    /// task that stops early and says so.
    private static let maxTurns = 24
    /// Tool output cap per result — a `find /` must not blow up the conversation.
    private static let maxToolOutput = 8_000

    /// A matched role renames the agent and appends its standing orders — the
    /// runtime is identical; the role is entirely prompt and identity.
    let role: AgentRole?

    init(goal: String, claude: ClaudeClient, role: AgentRole? = nil) {
        self.goal = goal
        self.claude = claude
        self.role = role
        self.name = role?.name ?? Self.deriveName(from: goal)
    }

    private var systemPrompt: String {
        guard let role, !role.instructions.isEmpty else { return Self.systemPrompt }
        return Self.systemPrompt + "\n\nYou are \"\(role.name)\". Standing orders from the user:\n\(role.instructions)"
    }

    func start() {
        loop = Task { await run() }
    }

    func cancel() {
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        loop?.cancel()
        guard status.isActive else { return }
        status = .failed("cancelled")
    }

    /// The user's verdict on a pending destructive command.
    func resolveApproval(allow: Bool) {
        guard case .waitingApproval = status else { return }
        status = .running(step: allow ? "Approved — continuing" : "Skipping that command")
        approvalContinuation?.resume(returning: allow)
        approvalContinuation = nil
    }

    // MARK: - The loop

    private func run() async {
        var messages: [[String: Any]] = [["role": "user", "content": goal]]
        for _ in 0..<Self.maxTurns {
            guard !Task.isCancelled else { return }
            let turn: ClaudeClient.AgentTurn
            do {
                turn = try await claude.agentTurn(system: systemPrompt, messages: messages)
            } catch {
                conclude(.failed("\(error)"))
                return
            }
            if !turn.text.isEmpty { log(turn.text) }
            // No tool call = the model is done talking; treat its text as the wrap-up.
            guard !turn.calls.isEmpty else {
                conclude(.finished(summary: turn.text.isEmpty ? "Done." : turn.text, success: true))
                return
            }
            messages.append(["role": "assistant", "content": turn.rawContent])
            var results: [[String: Any]] = []
            for call in turn.calls {
                if call.name == "finish" {
                    let summary = call.input["summary"] as? String ?? "Done."
                    let success = call.input["success"] as? Bool ?? true
                    conclude(.finished(summary: summary, success: success))
                    return
                }
                let output = await execute(call)
                results.append(["type": "tool_result", "tool_use_id": call.id,
                                "content": String(output.prefix(Self.maxToolOutput))])
            }
            messages.append(["role": "user", "content": results])
        }
        conclude(.finished(summary: "I hit my step limit before finishing — the log shows how far I got.", success: false))
    }

    private func conclude(_ event: Event) {
        switch event {
        case .finished(let summary, let success):
            status = .finished(summary: summary, success: success)
        case .failed(let message):
            status = .failed(message)
        case .needsApproval:
            break // not a terminal event; status set at the ask site
        }
        onEvent?(self, event)
    }

    // MARK: - Tools

    private func execute(_ call: ClaudeClient.AgentToolCall) async -> String {
        switch call.name {
        case "run_command":
            let command = call.input["command"] as? String ?? ""
            if let reason = Self.forbiddenReason(command) {
                log("refused: \(command)")
                return "Refused: \(reason). Background agents never touch the GUI — do this another way or finish and report it as out of reach."
            }
            if let reason = Self.approvalReason(command) {
                log("needs approval (\(reason)): \(command)")
                status = .waitingApproval(command: command)
                onEvent?(self, .needsApproval(command: command))
                let allowed = await withCheckedContinuation { approvalContinuation = $0 }
                guard allowed else {
                    log("denied by user: \(command)")
                    return "The user declined this command. Continue without it or finish and explain what's blocked."
                }
                log("approved by user: \(command)")
            }
            status = .running(step: "Running: \(command.prefix(60))")
            log("$ \(command)")
            let result = await Self.runShell(command)
            log(result.output.isEmpty ? "(no output, exit \(result.exitCode))" : result.output)
            return "exit \(result.exitCode)\n\(result.output)"
        case "read_file":
            let path = Self.expand(call.input["path"] as? String ?? "")
            status = .running(step: "Reading \((path as NSString).lastPathComponent)")
            do { return try String(contentsOfFile: path, encoding: .utf8) }
            catch { return "Could not read \(path): \(error.localizedDescription)" }
        case "write_file":
            let path = Self.expand(call.input["path"] as? String ?? "")
            let content = call.input["content"] as? String ?? ""
            status = .running(step: "Writing \((path as NSString).lastPathComponent)")
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                log("wrote \(path) (\(content.count) chars)")
                return "Wrote \(content.count) characters to \(path)."
            } catch { return "Could not write \(path): \(error.localizedDescription)" }
        default:
            return "Unknown tool \(call.name)."
        }
    }

    private func log(_ line: String) {
        transcript.append(String(line.prefix(600)))
        // The panel/dashboard shows a rolling window; the full story is capped so
        // an agent that loops on chatty output can't grow memory without bound.
        if transcript.count > 400 { transcript.removeFirst(transcript.count - 400) }
    }

    // MARK: - Command safety (pure, unit-tested)

    /// Commands that can reach the GUI or the user's session. Refused outright,
    /// not sent for approval — approval exists for *destructive* work the user
    /// may genuinely want; UI-reaching work belongs to the foreground loop.
    nonisolated static func forbiddenReason(_ command: String) -> String? {
        let c = normalized(command)
        if c.contains("osascript") { return "AppleScript can drive the screen" }
        if c.hasPrefix("open ") || c.contains("| open ") || c.contains("&& open ") || c.contains("; open ") {
            return "`open` raises GUI apps over what you're doing"
        }
        if c.contains("automator") { return "Automator can drive the screen" }
        if c.contains("caffeinate -u") { return "simulates user activity" }
        return nil
    }

    /// Commands that are legitimate but irreversible or outward-facing — run
    /// only after the user says yes. Returns a short reason for the ask.
    nonisolated static func approvalReason(_ command: String) -> String? {
        let c = normalized(command)
        if c.hasPrefix("sudo") || c.contains("| sudo") || c.contains("&& sudo") || c.contains("; sudo") { return "runs as administrator" }
        if c.range(of: #"\brm\s+(-[a-z]*[rf][a-z]*\s+)+"#, options: .regularExpression) != nil { return "deletes files recursively or by force" }
        if c.contains("git push") { return "publishes commits" }
        if c.range(of: #"git\s+reset\s+--hard"#, options: .regularExpression) != nil { return "discards local changes" }
        if c.range(of: #"git\s+clean\s+-[a-z]*f"#, options: .regularExpression) != nil { return "deletes untracked files" }
        if c.range(of: #"\b(shutdown|reboot|halt)\b"#, options: .regularExpression) != nil { return "power-cycles the machine" }
        if c.range(of: #"\b(killall|pkill)\b"#, options: .regularExpression) != nil || c.contains("kill -9") { return "terminates other apps" }
        if c.contains("diskutil erase") || c.contains("diskutil partition") || c.contains("mkfs") { return "erases a disk" }
        if c.contains("tccutil") || c.contains("csrutil") { return "changes system security state" }
        if c.range(of: #"launchctl\s+(bootout|unload|remove)"#, options: .regularExpression) != nil { return "stops system services" }
        if c.range(of: #"defaults\s+delete"#, options: .regularExpression) != nil { return "wipes app settings" }
        if c.range(of: #"(curl|wget)[^|;&]*\|\s*(ba|z|da|)sh"#, options: .regularExpression) != nil { return "pipes the internet into a shell" }
        if c.range(of: #"\bchmod\s+-r\b"#, options: .regularExpression) != nil || c.range(of: #"\bchown\s+-r\b"#, options: .regularExpression) != nil { return "rewrites permissions recursively" }
        if c.contains("npm publish") || c.contains("cargo publish") { return "publishes a package" }
        return nil
    }

    nonisolated private static func normalized(_ command: String) -> String {
        command.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "build a react app in ~/dev" → "Build a react app". Falls back to a
    /// counter-free generic; the manager disambiguates duplicates with a suffix.
    nonisolated static func deriveName(from goal: String) -> String {
        let words = goal.split(separator: " ").prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        guard !trimmed.isEmpty else { return "Background agent" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    // MARK: - Shell

    /// zsh -lc so the user's PATH (homebrew, nvm, …) applies — an agent asked to
    /// "run the build" must see the same tools the user's own terminal does.
    nonisolated static func runShell(_ command: String, timeout: TimeInterval = 120) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(returning: ("could not start shell: \(error.localizedDescription)", -1))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read BEFORE waiting: a process that fills the pipe buffer blocks
                // forever if nobody drains it.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (text, process.terminationStatus))
            }
        }
    }

    nonisolated private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are a background agent on the user's Mac, spawned by their voice assistant to \
    complete one goal without touching the screen. You have a shell (zsh, the user's \
    login environment), file reading, and file writing. You have NO access to the GUI: \
    never use osascript, `open`, or anything that raises windows or simulates input — \
    if the goal truly requires the GUI, call finish with success=false and say so.

    Work autonomously and verify as you go (run the build, run the tests, cat the file \
    you just wrote). Prefer doing over asking. Destructive commands are intercepted and \
    sent to the user for approval automatically — just issue them when genuinely needed \
    and handle a decline gracefully. When the goal is met, call finish with a summary \
    in one or two spoken-friendly sentences. Keep any commentary brief; nobody is \
    watching you work.
    """
}

/// Owns every background agent on this machine: spawn, capacity, approval routing.
@MainActor
final class BackgroundAgentManager: ObservableObject {
    static let shared = BackgroundAgentManager()

    @Published private(set) var agents: [BackgroundAgent] = []

    /// Three is a dogfooding guess, not physics: each agent is an Opus
    /// conversation plus a shell — the cap bounds cost surprise, not capability.
    nonisolated static let maxConcurrent = 3

    var active: [BackgroundAgent] { agents.filter { $0.status.isActive } }
    var awaitingApproval: [BackgroundAgent] {
        agents.filter { if case .waitingApproval = $0.status { return true }; return false }
    }

    enum SpawnError: Error {
        case atCapacity
        case emptyGoal

        var spoken: String {
            switch self {
            case .atCapacity: return "I already have \(BackgroundAgentManager.maxConcurrent) agents working. Ask me again when one finishes, or cancel one from the panel."
            case .emptyGoal: return "I didn't catch what the agent should do."
            }
        }
    }

    func spawn(goal: String, claude: ClaudeClient, role: AgentRole? = nil,
               onEvent: @escaping (BackgroundAgent, BackgroundAgent.Event) -> Void) -> Result<BackgroundAgent, SpawnError> {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyGoal) }
        guard active.count < Self.maxConcurrent else { return .failure(.atCapacity) }
        let agent = BackgroundAgent(goal: trimmed, claude: claude, role: role)
        agent.onEvent = onEvent
        agents.insert(agent, at: 0)
        // Finished runs stay visible for review; only the tail is trimmed.
        if agents.count > 12 { agents.removeLast(agents.count - 12) }
        agent.start()
        return .success(agent)
    }

    func cancel(_ id: String) {
        agents.first { $0.id == id }?.cancel()
    }

    func resolveApproval(_ id: String, allow: Bool) {
        agents.first { $0.id == id }?.resolveApproval(allow: allow)
    }
}
