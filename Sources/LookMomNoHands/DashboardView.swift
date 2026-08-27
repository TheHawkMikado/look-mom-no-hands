import SwiftUI
import AppKit

/// Every dashboard section. Our own tab strip (not TabView) so the navigation
/// bar is ALWAYS visible on every tab — no child view (NavigationSplitView,
/// toolbars) can hide or replace it.
enum DashTab: String, CaseIterable {
    case memory, live, transcripts, vocabulary, profiles, procedures, agents, paste, activity, settings

    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .memory: return "brain"
        case .live: return "waveform"
        case .transcripts: return "text.book.closed"
        case .vocabulary: return "character.book.closed"
        case .profiles: return "slider.horizontal.3"
        case .procedures: return "list.number"
        case .agents: return "person.2.gobackward"
        case .paste: return "doc.on.clipboard"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// The full dashboard window. The permanent tab strip lives at the very top of
/// the window content; the selected section renders below it.
struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @AppStorage("dashboardTab") private var selected: DashTab = .memory

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    // Always visible, on every tab, 100% of the time.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(DashTab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 14))
                        Text(tab.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected == tab ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                    .foregroundStyle(selected == tab ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var content: some View {
        switch selected {
        case .memory:
            MemoryTab(coordinator: coordinator, environment: coordinator.environment, knowledge: coordinator.knowledge, learned: coordinator.learnedControls, appCaps: coordinator.appCapabilities)
        case .live:
            LiveTab(coordinator: coordinator)
        case .transcripts:
            TranscriptsTab(store: coordinator.store)
        case .vocabulary:
            VocabularyTab(vocabulary: coordinator.vocabulary,
                          onChange: { coordinator.refreshContextualPhrases() })
        case .profiles:
            ProfilesTab(profiles: coordinator.profiles)
        case .procedures:
            ProceduresTab(procedures: coordinator.procedures)
        case .agents:
            AgentsTab(roles: coordinator.agentRoles, mcp: coordinator.mcp, fleet: coordinator.fleet)
        case .paste:
            PasteRulesTab(rules: coordinator.insertRules)
        case .activity:
            ActivityTab(store: coordinator.store)
        case .settings:
            SettingsTab(coordinator: coordinator)
        }
    }
}

/// What the assistant knows right now: the sticky focus it's working in, a live
/// tree of everything open (apps → windows → tabs), and the recent-action memory
/// that keeps commands on-track across turns.
private struct MemoryTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var environment: EnvironmentTracker
    @ObservedObject var knowledge: KnowledgeStore
    @ObservedObject var learned: ElementMemoryStore
    @ObservedObject var appCaps: AppCapabilityStore
    @State private var newFact = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(coordinator.workingContext.isEmpty ? Color.secondary : Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Working focus").font(.caption2).foregroundStyle(.secondary)
                    Text(coordinator.workingContext.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(coordinator.workingContext.isEmpty ? .secondary : .primary)
                }
                Spacer()
                if !coordinator.workingContext.isEmpty {
                    Button("Clear focus") { coordinator.clearWorkingContext() }
                }
            }
            .padding(10)
            Divider()

            List {
                Section {
                    if environment.snapshot.apps.isEmpty {
                        Text(ScreenController.isTrusted
                             ? "Scanning…"
                             : "Grant Accessibility to track open windows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !environment.snapshot.apps.isEmpty && !CGPreflightScreenCaptureAccess() {
                        Text("Grant Screen Recording to see the titles of windows on other desktops.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    ForEach(environment.snapshot.apps) { app in
                        DisclosureGroup {
                            ForEach(app.windows) { win in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(win.title.isEmpty ? "(untitled window)" : win.title)
                                            .font(.callout)
                                        if !win.onScreen {
                                            Text("another desktop").font(.caption2)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    if !win.tabs.isEmpty {
                                        Text(win.tabs.map { $0 == win.activeTab ? "▸ \($0)" : $0 }.joined(separator: "  ·  "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            if app.windows.isEmpty {
                                Text("No windows").font(.caption2).foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Image(systemName: app.active ? "app.badge.checkmark" : "app")
                                    .foregroundStyle(app.active ? Color.blue : Color.secondary)
                                Text(app.name).font(.callout.weight(app.active ? .semibold : .regular))
                                Spacer()
                                Text("\(app.windows.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Open now").font(.headline)
                        Spacer()
                        if let t = environment.lastRefresh {
                            Text("updated \(t.formatted(date: .omitted, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("General memory (what it knows about you)") {
                    HStack(spacing: 6) {
                        TextField("Add a fact — e.g. “my main project is look-mom-no-hands”", text: $newFact)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addFact() }
                        Button("Add") { addFact() }
                            .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if knowledge.facts.isEmpty {
                        Text("Nothing yet — say “remember that …” or add one here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(knowledge.facts) { fact in
                        HStack {
                            Text(fact.text)
                            Spacer()
                            Button { knowledge.remove(fact.id) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                    }
                }

                Section("Learned controls (taught by demonstration)") {
                    if learned.elements.isEmpty {
                        Text("None yet. When it can't find something you asked it to click, it'll ask you to click it once — then it remembers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(learned.elements) { el in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("“\(el.phrase)” → \(el.label)").font(.callout)
                                Text("\(el.role) in \(el.appName)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { learned.remove(el.id) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                    }
                }

                Section("App knowledge (from documentation)") {
                    if appCaps.capabilities.isEmpty {
                        Text("None yet. When you command an app for the first time, it looks up that app's features and shortcuts and remembers them here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appCaps.capabilities) { cap in
                        DisclosureGroup {
                            Text(cap.summary).font(.caption).textSelection(.enabled)
                        } label: {
                            HStack {
                                Text(cap.appName).font(.callout.weight(.medium))
                                Spacer()
                                Button { appCaps.remove(cap.bundleID) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Recent actions") {
                    if coordinator.recentActions.isEmpty {
                        Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(coordinator.recentActions.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func addFact() {
        let t = newFact.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        knowledge.remember(t)
        newFact = ""
    }
}

/// Otter-style live transcript: a rolling note the app fills in from 60-second
/// audio chunks while it listens, plus ask/summarize over what's been captured.
private struct LiveTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if coordinator.liveActive {
                    Button(role: .destructive) { coordinator.stopRecording() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    Label("Recording…", systemImage: "waveform")
                        .foregroundStyle(.red).font(.callout)
                } else {
                    Button { coordinator.startRecording(output: .note) } label: {
                        Label("Record a note", systemImage: "record.circle")
                    }
                    .disabled(!coordinator.hasKey)
                }
                Spacer()
                if coordinator.liveBusy { ProgressView().controlSize(.small) }
            }
            if !coordinator.hasElevenLabsKey {
                Text("Recording works on-device; add an ElevenLabs key for higher-accuracy transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(coordinator.liveTranscript.isEmpty
                     ? "Nothing captured yet. Press Record and talk — it transcribes as you go and processes into a note when you stop."
                     : coordinator.liveTranscript)
                    .textSelection(.enabled)
                    .foregroundStyle(coordinator.liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let trouble = coordinator.transcriptionTrouble {
                Label(trouble, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Instant proof the mic is capturing: the on-device recognizer's tail,
            // live — Scribe chunks land every ~12-25s. A separate child view so
            // the per-partial churn re-renders only this caption.
            if coordinator.liveActive {
                HearingCaption(meter: coordinator.meter)
            }

            HStack(spacing: 8) {
                TextField("Ask a question about this transcript…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button("Ask") { ask() }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || coordinator.liveTranscript.isEmpty)
            }
            if !coordinator.liveAnswer.isEmpty {
                Text(coordinator.liveAnswer)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button { coordinator.summarizeLiveTranscript() } label: { Label("Summarize", systemImage: "sparkles") }
                    .disabled(coordinator.liveTranscript.isEmpty || coordinator.liveBusy)
                Button { coordinator.saveLiveAsNote() } label: { Label("Save as note", systemImage: "square.and.arrow.down") }
                    .disabled(coordinator.liveTranscript.isEmpty)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(coordinator.liveTranscript, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(coordinator.liveTranscript.isEmpty)
                Button(role: .destructive) { coordinator.clearLiveTranscript() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(coordinator.liveTranscript.isEmpty)
            }
        }
        .padding()
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        coordinator.askLiveTranscript(q)
    }
}

/// How dictated text is formatted before it's pasted: a general instruction plus
/// per-app rules (e.g. VS Code gets one style, Slack another).
// Observes only the meter, so the several-per-second partial updates re-render
// this one caption instead of the whole Live tab.
private struct HearingCaption: View {
    @ObservedObject var meter: RecorderMeter

    var body: some View {
        if !meter.heard.isEmpty {
            Text("Hearing: …\(meter.heard)")
                .font(.caption).italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PasteRulesTab: View {
    @ObservedObject var rules: InsertRulesStore
    @State private var newApp = ""

    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How push-to-dictate / insert text is cleaned up before pasting. General always applies; a per-app rule adds to it when you paste into that app.")
                .font(.caption).foregroundStyle(.secondary)

            Text("General").font(.headline)
            TextEditor(text: $rules.general).font(.body).frame(height: 70).overlay(border)

            Divider()
            HStack {
                Text("Per app").font(.headline)
                Spacer()
                TextField("App name (e.g. Code)", text: $newApp).frame(width: 160).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let a = newApp.trimmingCharacters(in: .whitespaces)
                    guard !a.isEmpty else { return }
                    rules.upsert(InsertRule(app: a, instructions: ""))
                    newApp = ""
                }
            }

            List {
                if rules.appRules.isEmpty {
                    Text("No per-app rules. Add one to format differently in a specific app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rules.appRules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rule.app).font(.callout.weight(.semibold))
                            Spacer()
                            Button { rules.remove(rule.id) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                        TextEditor(text: instructionsBinding(rule)).font(.callout).frame(height: 54).overlay(border)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
    }

    private func instructionsBinding(_ rule: InsertRule) -> Binding<String> {
        Binding(get: { rule.instructions },
                set: { rules.upsert(InsertRule(id: rule.id, app: rule.app, instructions: $0)) })
    }
}

/// Taught procedures: the growing library of "here's how I do X." You teach them
/// by voice ("here's how to create a new Claude Code session: …") or edit here; a
/// matching command follows the steps.
/// Background agents: what's running now (with live transcript + approvals) and
/// the named roles work can be routed to by saying their name.
private struct AgentsTab: View {
    @ObservedObject var roles: AgentRoleStore
    let mcp: MCPManager
    @ObservedObject var fleet: FleetService
    @ObservedObject private var manager = BackgroundAgentManager.shared
    @ObservedObject private var meter = CostMeter.shared
    @State private var editingRole: AgentRole?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                runsColumn
                Divider().padding(.vertical, 8)
                FleetSection(fleet: fleet)
            }
            .frame(minWidth: 340)
            VStack(spacing: 0) {
                rolesColumn
                Divider().padding(.vertical, 8)
                ConnectionsSection(mcp: mcp)
            }
            .frame(minWidth: 280)
        }
        .padding(12)
    }

    private var runsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent runs").font(.headline)
                Spacer()
                if meter.agents.calls > 0 {
                    Text(String(format: "$%.2f · %d calls", meter.agents.cost, meter.agents.calls))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if manager.agents.isEmpty {
                Text("No agents yet. Say “Hey Mama, build…” or “have Scout research…” — anything long-running and off-screen becomes a background agent.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(manager.agents) { agent in
                            AgentRunCard(agent: agent)
                        }
                    }
                }
            }
        }
        .padding(.trailing, 10)
    }

    private var rolesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Roles").font(.headline)
                Spacer()
                Button {
                    let role = AgentRole(name: "New role", instructions: "")
                    roles.upsert(role)
                    editingRole = role
                } label: { Image(systemName: "plus") }
            }
            Text("Say a role's name in a command to route the work to it. Its instructions ride along as standing orders.")
                .font(.caption).foregroundStyle(.secondary)
            List(roles.roles) { role in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(role.name).font(.callout.bold())
                        Spacer()
                        Button { editingRole = role } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain)
                        Button { roles.remove(role.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    if !role.instructions.isEmpty {
                        Text(role.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .padding(.leading, 10)
        .sheet(item: $editingRole) { role in
            RoleEditor(role: role, roles: roles)
        }
    }
}

/// Other Macs you own, paired into a fleet: enable worker mode to accept goals
/// here; pair a discovered machine to send goals there ("on the mac mini, …").
private struct FleetSection: View {
    @ObservedObject var fleet: FleetService
    @ObservedObject var peers: FleetPeerStore

    init(fleet: FleetService) {
        self.fleet = fleet
        self.peers = fleet.peers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fleet").font(.headline)
            Toggle(isOn: $fleet.workerModeEnabled) {
                Text("Let paired Macs send work here (worker mode)").font(.caption)
            }
            .toggleStyle(.checkbox)

            if let pending = fleet.pendingPair {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(pending.peerName)” wants to pair").font(.callout.bold())
                    Text("Only approve if the same code shows on that Mac: \(pending.code)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Pair") { fleet.approvePendingPair() }
                        Button("Reject") { fleet.rejectPendingPair() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }

            if !peers.peers.isEmpty {
                Text("Paired").font(.caption).foregroundStyle(.secondary)
                ForEach(peers.peers) { peer in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(fleet.status[peer.keyHex]?.online == true ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(peer.name).font(.caption)
                        Spacer()
                        Button { peers.remove(peer.keyHex) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Text("Say “on the \(peers.peers.first?.name.lowercased() ?? "mac mini"), …” to send a task there.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            let unpaired = fleet.discovered.filter { worker in !peers.peers.contains { $0.name == worker.endpointName } }
            if !unpaired.isEmpty {
                Text("On your network").font(.caption).foregroundStyle(.secondary)
                ForEach(unpaired) { worker in
                    HStack {
                        Text(worker.endpointName).font(.caption)
                        Spacer()
                        Button("Pair") { fleet.beginPairing(with: worker) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.trailing, 10)
    }
}

/// Connected MCP servers: the API escape hatch. A server's tools appear in the
/// planner's context, and use_tool beats ten clicks whenever one covers the task.
private struct ConnectionsSection: View {
    @ObservedObject var mcp: MCPManager
    @ObservedObject var store: MCPStore
    @State private var adding = false

    init(mcp: MCPManager) {
        self.mcp = mcp
        self.store = mcp.store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus") }
            }
            Text("MCP servers give her real APIs — Gmail, Slack, Notion — so those tasks stop being clicks. Secrets go to the Keychain, never to disk.")
                .font(.caption).foregroundStyle(.secondary)
            List(store.servers) { server in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Circle()
                            .fill(mcp.tools.contains { $0.server == server.name } ? Color.green
                                  : mcp.connectionErrors[server.id] != nil ? Color.red : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(server.name).font(.callout.bold())
                        Spacer()
                        Button { Task { await mcp.connect(server) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                        Button { mcp.disconnect(server.id); store.remove(server.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Text(server.command).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if let error = mcp.connectionErrors[server.id] {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    } else {
                        let count = mcp.tools.filter { $0.server == server.name }.count
                        if count > 0 { Text("\(count) tools").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .padding(.leading, 10)
        .sheet(isPresented: $adding) {
            AddConnectionSheet(mcp: mcp)
        }
    }
}

private struct AddConnectionSheet: View {
    let mcp: MCPManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var envText = ""   // KEY=value per line

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add MCP server").font(.headline)
            TextField("Name (becomes the tool prefix, e.g. slack)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Command (e.g. npx -y @modelcontextprotocol/server-slack)", text: $command)
                .textFieldStyle(.roundedBorder)
            Text("Secrets — one KEY=value per line. Values are stored in the Keychain; only the names touch disk.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $envText)
                .font(.callout.monospaced())
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add & connect") {
                    var secrets: [String: String] = [:]
                    for line in envText.split(separator: "\n") {
                        guard let eq = line.firstIndex(of: "=") else { continue }
                        secrets[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
                            String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    }
                    let config = MCPServerConfig(name: name, command: command, envKeys: Array(secrets.keys))
                    mcp.store.upsert(config, secrets: secrets)
                    Task { await mcp.connect(config) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct AgentRunCard: View {
    @ObservedObject var agent: BackgroundAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(agent.status.tint).frame(width: 8, height: 8)
                Text(agent.name).font(.callout.bold())
                Text(agent.startedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if agent.status.isActive {
                    Button("Cancel") { BackgroundAgentManager.shared.cancel(agent.id) }
                        .controlSize(.small)
                }
            }
            Text(agent.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if case .waitingApproval(let command) = agent.status {
                VStack(alignment: .leading, spacing: 4) {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Approve") { BackgroundAgentManager.shared.resolveApproval(agent.id, allow: true) }
                        Button("Don't run") { BackgroundAgentManager.shared.resolveApproval(agent.id, allow: false) }
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            } else {
                Text(agent.status.label).font(.caption).foregroundStyle(.secondary)
            }
            if !agent.transcript.isEmpty {
                // The tail is what tells you whether it's on track — the full log
                // stays with the agent, this is a live window, newest last.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(agent.transcript.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

private struct RoleEditor: View {
    @State var role: AgentRole
    let roles: AgentRoleStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit role").font(.headline)
            TextField("Name (what you'll say — e.g. Scout)", text: $role.name)
                .textFieldStyle(.roundedBorder)
            Text("Standing orders").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $role.instructions)
                .font(.callout)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    roles.upsert(role)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct ProceduresTab: View {
    @ObservedObject var procedures: ProcedureStore
    @State private var selection: String?
    @State private var name = ""
    @State private var triggers = ""
    @State private var steps = ""
    @State private var scheduleOn = false
    @State private var scheduleTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var scheduleDays: Set<Int> = [2, 3, 4, 5, 6]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    if procedures.procedures.isEmpty {
                        Text("No procedures yet. Say “watch this” and demonstrate, or add one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(procedures.procedures) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name.isEmpty ? "(unnamed)" : p.name)
                            if !p.triggers.isEmpty {
                                Text(p.triggers.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let s = p.schedule {
                                Label(s.label, systemImage: "clock")
                                    .font(.caption2).foregroundStyle(.purple)
                            }
                        }
                        .tag(p.id)
                        .contextMenu { Button("Delete", role: .destructive) { procedures.remove(p.id) } }
                    }
                }
                Divider()
                Button { newProcedure() } label: { Label("New procedure", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 250)

            Divider()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selection) { _ in loadDraft() }
    }

    @ViewBuilder private var editor: some View {
        if selection != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Teach it by voice too — say “here's how to …” while using the app.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Name (e.g. create a new Claude Code session)", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Trigger phrases, comma-separated", text: $triggers)
                    .textFieldStyle(.roundedBorder)
                Text("Steps").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $steps)
                    .font(.body).frame(maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                scheduleEditor
                HStack {
                    Spacer()
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Select a procedure, or add one").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scheduleEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Run on a schedule", isOn: $scheduleOn)
                .toggleStyle(.checkbox)
            if scheduleOn {
                HStack(spacing: 10) {
                    DatePicker("At", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .frame(width: 110)
                    ForEach(1..<8) { day in
                        let letters = ["S", "M", "T", "W", "T", "F", "S"]
                        Button(letters[day - 1]) {
                            if scheduleDays.contains(day) { scheduleDays.remove(day) }
                            else { scheduleDays.insert(day) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(scheduleDays.contains(day) ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)))
                    }
                }
                Text("Runs only while the Mac is awake and you're not mid-task — a busy slot is skipped, not queued. If you speak during a run, it stops and you win the screen.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadDraft() {
        guard let id = selection, let p = procedures.procedures.first(where: { $0.id == id }) else {
            name = ""; triggers = ""; steps = ""   // no selection / stale id → clear, never show a stale draft
            scheduleOn = false
            return
        }
        name = p.name; triggers = p.triggers.joined(separator: ", "); steps = p.steps
        scheduleOn = p.schedule != nil
        if let s = p.schedule {
            scheduleTime = Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? scheduleTime
            scheduleDays = s.weekdays
        }
    }

    private func newProcedure() {
        let p = Procedure(name: "New procedure", steps: "")
        procedures.upsert(p)
        selection = p.id
        loadDraft()
    }

    private func save() {
        // Mutate the existing record: rebuilding from scratch here once silently
        // wiped createdAt — and would now wipe lastFiredAt too.
        guard let id = selection, var p = procedures.procedures.first(where: { $0.id == id }) else { return }
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.triggers = triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.steps = steps
        // Toggle on with zero weekdays = a schedule that can never fire but
        // still shows a clock badge — treat it as "off", not as a lie.
        if scheduleOn, !scheduleDays.isEmpty {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
            p.schedule = ProcedureSchedule(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: scheduleDays)
        } else {
            p.schedule = nil
        }
        procedures.upsert(p)
    }
}

/// Processing profiles: named instruction sets that decide how a recording turns
/// into a note (what to extract and when). The active one drives every note.
private struct ProfilesTab: View {
    @ObservedObject var profiles: ProfileStore
    @State private var draftName = ""
    @State private var draftInstructions = ""
    @State private var editingID: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { profiles.activeID }, set: { profiles.activeID = $0 ?? profiles.activeID })) {
                ForEach(profiles.profiles) { p in
                    HStack {
                        Image(systemName: p.id == profiles.activeID ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(p.id == profiles.activeID ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            if p.builtIn { Text("built-in").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .tag(p.id)
                    .contextMenu {
                        if !p.builtIn { Button("Delete", role: .destructive) { profiles.remove(p.id) } }
                    }
                }
                Button { addProfile() } label: { Label("New profile", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            .frame(width: 250)

            Divider()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadDraft)
        .onChange(of: profiles.activeID) { _ in loadDraft() }
    }

    @ViewBuilder private var editor: some View {
        if let p = profiles.active {
            VStack(alignment: .leading, spacing: 10) {
                Text("Active profile").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(p.builtIn)
                Text("Instructions — what the app should produce from a recording, and when.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draftInstructions)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    if p.builtIn {
                        Text("Built-in — edits are saved to your copy.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") { profiles.update(p.id, name: draftName, instructions: draftInstructions) }
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } else {
            Text("No profile selected").foregroundStyle(.secondary)
        }
    }

    private func loadDraft() {
        guard let p = profiles.active else { return }
        draftName = p.name; draftInstructions = p.instructions; editingID = p.id
    }

    private func addProfile() {
        profiles.add(name: "New profile", instructions: "A title, a short summary, and any action items.")
        loadDraft()
    }
}

/// Unified "dictionary + snippets": names/terms to spell right, corrections for
/// consistent mishearings, and snippet expansions. The model applies all three.
private struct VocabularyTab: View {
    @ObservedObject var vocabulary: VocabularyStore
    let onChange: () -> Void

    @State private var kind: VocabEntry.Kind = .word
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Teach the app your words. It applies these to every transcription and command.")
                .font(.caption).foregroundStyle(.secondary)

            addRow

            List {
                section("Words & names", .word, "Recognized and spelled exactly")
                section("Corrections", .correction, "A mishearing → what you meant")
                section("Snippets", .snippet, "A spoken shortcut → its full text")
            }
        }
        .padding()
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                Text("Word").tag(VocabEntry.Kind.word)
                Text("Correction").tag(VocabEntry.Kind.correction)
                Text("Snippet").tag(VocabEntry.Kind.snippet)
            }
            .labelsHidden().frame(width: 120)

            TextField(kind == .word ? "Term (e.g. Styku)" : kind == .correction ? "Heard as…" : "When I say…", text: $spoken)
                .textFieldStyle(.roundedBorder)
            if kind != .word {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField(kind == .correction ? "I mean…" : "Expand to…", text: $written)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Add") {
                vocabulary.add(VocabEntry(kind: kind, spoken: spoken, written: written))
                spoken = ""; written = ""
                onChange()
            }
            .disabled(spoken.trimmingCharacters(in: .whitespaces).isEmpty
                      || (kind != .word && written.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ k: VocabEntry.Kind, _ hint: String) -> some View {
        let items = vocabulary.entries(of: k)
        Section {
            if items.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { entry in
                HStack {
                    if entry.written.isEmpty {
                        Text(entry.spoken)
                    } else {
                        Text(entry.spoken).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(entry.written)
                    }
                    Spacer()
                    Button {
                        vocabulary.remove(entry.id); onChange()
                    } label: { Image(systemName: "trash").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                }
            }
        } header: {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// All tunable behavior in one place (the menu-bar panel is space-constrained).
/// Every control binds to a coordinator property that persists itself on change.
private struct SettingsTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var meter = CostMeter.shared
    @State private var section: SettingsSection = .general

    private enum SettingsSection: String, CaseIterable {
        case general = "General"
        case hotkeys = "Hotkeys"
    }

    private let pauseOptions: [(String, TimeInterval)] =
        [("5 seconds", 5), ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
         ("2 minutes", 120), ("Never (stop manually)", 0)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(SettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            switch section {
            case .general: generalForm
            case .hotkeys: hotkeysForm
            }
        }
        // Devices can (un)plug at any time; the list is cheap to rebuild and
        // only needs to be fresh while the user is looking at it.
        .onAppear { coordinator.refreshInputDevices() }
    }

    private var generalForm: some View {
        Form {
            Section("Speech recognition") {
                Picker("Engine", selection: $coordinator.speechEngine) {
                    ForEach(SpeechEngine.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Microphone", selection: Binding(
                    get: { coordinator.micUID },
                    set: { coordinator.selectMicrophone(uid: $0) }
                )) {
                    Text("System default").tag(String?.none)
                    // Keep a disconnected selection visible instead of a blank
                    // picker — capture silently falls back to the default mic.
                    if let uid = coordinator.micUID,
                       !coordinator.inputDevices.contains(where: { $0.uid == uid }) {
                        Text("Selected mic (disconnected)").tag(String?.some(uid))
                    }
                    ForEach(coordinator.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Text("Pick a dedicated mic to leave your other mics free for a second recorder running in parallel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("API keys") {
                LabeledContent("Anthropic") { statusPill(coordinator.hasKey) }
                LabeledContent("ElevenLabs") { statusPill(coordinator.hasElevenLabsKey) }
                Text("Your keys are set once on your account and shared to every device you sign in on — there's nothing to enter here. Anthropic powers screen control; ElevenLabs adds spoken replies and higher-accuracy transcription.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Manage keys at nohandsapp.com", destination: AccountStore.accountURL)
                    .font(.caption)
            }

            Section("Measured cost (this device)") {
                costRow("Controller", meter.controller)
                costRow("Dictation", meter.dictation)
                Text("Real API spend so far, priced at current rates and split by workload. The per-hour figure is approximate — active time is inferred from usage. Reset before a timed run to measure a clean $/hr.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset measurements", role: .destructive) { meter.reset() }
            }

            Section("Recording") {
                Picker("Note profile", selection: Binding(
                    get: { coordinator.profiles.activeID },
                    set: { coordinator.profiles.activeID = $0 }
                )) {
                    ForEach(coordinator.profiles.profiles) { Text($0.name).tag($0.id) }
                }
                Picker("End after pause", selection: $coordinator.recorderEndPause) {
                    ForEach(pauseOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("Clean up inserted text before pasting", isOn: $coordinator.cleanUpInsertedText)
            }

            Section("Live transcript") {
                Text("Captures continuously and adds to the transcript about every \(Int(AppCoordinator.liveChunkSecondsForTest)) seconds, at the next natural pause.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Say “Mama, take notes” to start and “Mama, stop transcribing” to end — or use the Live tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Screen control") {
                Text("Say “Hey Mama” to start a command, “Adios Mama” to end the session.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Accessibility (mouse/keyboard)") { statusPill(coordinator.accessibilityTrusted) }
                if !coordinator.accessibilityTrusted {
                    Button("Grant Accessibility…") { coordinator.requestAccessibility() }
                }
                Toggle("Vision fallback (screenshot a target the app can't find)", isOn: $coordinator.visionClickEnabled)
                Text("When on, a click the Accessibility tree can't resolve is retried by screenshotting the screen and locating it visually. Needs Screen Recording permission (macOS will prompt the first time).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Learn app documentation (features & shortcuts)", isOn: $coordinator.appDocsEnabled)
                Text("The first time you command an app, it researches that app's documented features and keyboard shortcuts on the web and feeds them to the planner — so it acts precisely instead of guessing. One web-search lookup per app, then cached. Review what it learned in the Memory tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeysForm: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-dictate", selection: $coordinator.dictationChord) {
                    ForEach(DictationChord.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Tap the chord to start dictating, tap again (or pause) to stop. The text is cleaned up and pasted at your cursor.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Push-to-dictate & submit", selection: $coordinator.submitChord) {
                    ForEach(DictationChord.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Same as push-to-dictate, but presses Enter after pasting — so a chat box, search field, or terminal submits automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Screen control") {
                Picker("Start session (“Hey Mama”)", selection: $coordinator.sessionStartChord) {
                    ForEach(DictationChord.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("End session (“Adios Mama”)", selection: $coordinator.sessionEndChord) {
                    ForEach(DictationChord.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Button equivalents of the wake/stop words, so a session can be started and ended by voice or by keyboard. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("A chord is a set of modifier keys tapped together (no letter). Pick distinct chords for each action; when one is a subset of another (⌃⌥ vs ⌃⌥⇧), the more-specific one wins. Global hotkeys need Accessibility permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statusPill(_ ok: Bool) -> some View {
        Label(ok ? "Connected" : "Not set", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .font(.caption)
    }

    private func costRow(_ name: String, _ b: CostMeter.Bucket) -> some View {
        LabeledContent(name) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "$%.4f", b.cost)).monospacedDigit()
                Text("\(b.calls) calls · \(Self.duration(b.activeSeconds)) · "
                     + (b.perHour > 0 ? String(format: "$%.2f/hr", b.perHour) : "—/hr"))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }

}

private struct TranscriptsTab: View {
    @ObservedObject var store: AppStore
    @State private var selection: TranscriptRecord.ID?
    @State private var search = ""

    private var filtered: [TranscriptRecord] {
        guard !search.isEmpty else { return store.transcripts }
        let q = search.lowercased()
        return store.transcripts.filter {
            $0.transcript.lowercased().contains(q)
            || ($0.summary?.lowercased().contains(q) ?? false)
        }
    }

    // Plain HStack (not NavigationSplitView/HSplitView): a NavigationSplitView inside
    // the tab strip took over the window chrome; HSplitView left panes mis-sized. A
    // fixed sidebar + a filling detail is predictable.
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 8)
                List(selection: $selection) {
                    if filtered.isEmpty {
                        Text(store.transcripts.isEmpty ? "No transcripts yet." : "No matches.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { rec in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: rec.kind == "dictation" ? "note.text" : "cursorarrow.rays")
                                Text(rec.summary ?? rec.transcript).lineLimit(1)
                                Spacer()
                            }
                            Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(rec.id)
                    }
                }
            }
            .frame(width: 280)

            Divider()

            Group {
                if let id = selection, let rec = store.transcripts.first(where: { $0.id == id }) {
                    TranscriptDetail(record: rec)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a transcript · \(store.transcripts.count) stored").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptDetail: View {
    let record: TranscriptRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(record.title?.isEmpty == false ? record.title! : record.kind.capitalized).font(.headline)
                    Spacer()
                    Text(record.date.formatted(date: .long, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let summary = record.summary {
                    section("Summary") { Text(summary) }
                }
                if let points = record.keyPoints, !points.isEmpty {
                    section("Key points") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(points.enumerated()), id: \.offset) { _, i in Text("• \(i)") }
                        }
                    }
                }
                if let items = record.actionItems, !items.isEmpty {
                    section("Action items") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, i in Text("• \(i)") }
                        }
                    }
                }
                if let outcome = record.outcome {
                    section("Outcome") { Text(outcome).font(.callout.monospaced()) }
                }
                section("Transcript") {
                    Text(record.transcript).textSelection(.enabled)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var copyText: String {
        var out = ""
        if let t = record.title, !t.isEmpty { out += "\(t)\n\n" }
        if let s = record.summary { out += "Summary:\n\(s)\n\n" }
        if let points = record.keyPoints, !points.isEmpty {
            out += "Key points:\n" + points.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let items = record.actionItems, !items.isEmpty {
            out += "Action items:\n" + items.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        out += "Transcript:\n\(record.transcript)"
        return out
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ActivityTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.activity.count) events").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                } label: { Label("Reveal data folder", systemImage: "folder") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.activity.reversed().map(\.line).joined(separator: "\n"), forType: .string)
                } label: { Label("Copy log", systemImage: "doc.on.doc") }
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.activity) { entry in
                        Text(entry.line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
    }
}
