import SwiftUI
import AppKit

@main
struct LookMomNoHandsApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var account = AccountStore()
    @StateObject private var updates = UpdateChecker()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(coordinator: coordinator, store: coordinator.store,
                      account: account, updates: updates)
                .onAppear { updates.checkInBackground() }
        } label: {
            MenuBarIcon(coordinator: coordinator)
                // The menu-bar icon is always present, so this is the reliable
                // place to wire sign-in delivery and run the launch sync — unlike
                // window content, which isn't materialised until it's shown.
                .onAppear {
                    account.attach(coordinator: coordinator)
                    AccountBridge.handler = { url in
                        Task { await account.handleAuthCallback(url) }
                    }
                    AppDelegate.onTerminate = { [weak coordinator] in coordinator?.mcp.shutdown() }
                    Task { await account.syncOnLaunch() }
                }
                .onOpenURL { url in AccountBridge.handle(url) }
        }
        .menuBarExtraStyle(.window)

        Window(Self.dashboardTitle, id: "dashboard") {
            DashboardView(coordinator: coordinator)
                .onAppear { DockPresence.dashboardOpened() }
        }
    }

    static let dashboardTitle = "\(AppIdentity.displayName) — Dashboard"
}

/// The status-item glyph plus its animation clock. Grey slash = off, purple
/// hand = standby, purple finger-sweep = live command session, red sweep =
/// recording/dictation.
///
/// The sweep is frame-by-frame image swaps, not an implicit animation —
/// MenuBarExtra labels don't run those. The ticker only writes state while a
/// sweep is on screen, so standby/off never re-render on the tick.
struct MenuBarIcon: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    private let ticker = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: .brandMark(height: 15, state: state))
            .onReceive(ticker) { _ in
                guard isSweeping else { return }
                step = (step + 1) % MarkShape.capsuleCount
            }
            // The voice command "open the dashboard" lands here: this label is the
            // only view that's guaranteed alive, so it owns the openWindow bridge.
            .onReceive(NotificationCenter.default.publisher(for: .lmnhOpenDashboard)) { _ in
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }

    private var isSweeping: Bool {
        switch state {
        case .active, .dictating: return true
        case .off, .standby: return false
        }
    }

    private var state: MenuBarMark {
        guard coordinator.isRunning else { return .off }
        if coordinator.phase == .recording || coordinator.liveActive { return .dictating(step: step) }
        switch coordinator.phase {
        case .capturingCommand, .thinking, .acting, .clarifying, .watching:
            return .active(step: step)
        default:
            return .standby
        }
    }
}

extension Notification.Name {
    /// Posted by the action executor when a voice command targets our own
    /// dashboard; observed by the menu-bar label, which opens the window scene.
    static let lmnhOpenDashboard = Notification.Name("lmnhOpenDashboard")
}

/// Routes custom-scheme URLs (`lookmomnohands://auth?token=…`) to the account
/// store. Both the AppKit delegate below and SwiftUI's `.onOpenURL` feed this one
/// sink, so sign-in completes whichever path the OS uses to deliver the URL.
enum AccountBridge {
    @MainActor static var handler: ((URL) -> Void)?
    static func handle(_ url: URL) { Task { @MainActor in handler?(url) } }
}

/// A menu-bar (`LSUIElement`) app still wants a delegate to catch URL opens while
/// it's already running — the common case, since sign-in happens with the app up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Cleanup that must not outlive the app — today: terminating MCP server
    /// child processes, which otherwise linger as orphans after quit.
    @MainActor static var onTerminate: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(AccountBridge.handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.onTerminate?() }
    }
}

/// The app ships as an `LSUIElement` — menu-bar only, no Dock tile — because
/// that's right for something you talk to rather than switch to. The dashboard
/// is a real window though, so give the app a real Dock presence for as long as
/// it's open and drop back to accessory when it closes.
@MainActor
enum DockPresence {
    private static var observer: NSObjectProtocol?

    static func dashboardOpened() {
        apply(.regular)

        // `onDisappear` on a Window's root view doesn't reliably fire when the
        // window is closed from the red button, so the close notification is the
        // authority. Matching on title because SwiftUI doesn't hand us the
        // NSWindow for a scene.
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard (note.object as? NSWindow)?.title == LookMomNoHandsApp.dashboardTitle else { return }
            MainActor.assumeIsolated { apply(.accessory) }
        }
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Going regular mid-flight doesn't focus the app on its own, and going
        // back to accessory can leave the menu bar owned by nobody.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}

extension BackgroundAgent.Status {
    /// The one status→color mapping, next to nothing: the panel and the
    /// dashboard both read it, so a new case can't diverge between them.
    var tint: Color {
        switch self {
        case .running: return .purple
        case .waitingApproval: return .orange
        case .finished(_, let ok): return ok ? .green : .secondary
        case .failed: return .red
        }
    }
}

/// One background agent in the panel: status dot, live step, and — when it's
/// asking — the approve/deny pair. Its own view so @ObservedObject tracks the
/// agent's published status without redrawing the whole panel per log line.
private struct AgentRow: View {
    @ObservedObject var agent: BackgroundAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(agent.status.tint).frame(width: 7, height: 7)
                Text(agent.name).font(.caption).lineLimit(1)
                Spacer()
                if agent.status.isActive {
                    Button("Cancel") { BackgroundAgentManager.shared.cancel(agent.id) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if case .waitingApproval(let command) = agent.status {
                Text(command)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Approve") { BackgroundAgentManager.shared.resolveApproval(agent.id, allow: true) }
                    Button("Don't run") { BackgroundAgentManager.shared.resolveApproval(agent.id, allow: false) }
                }
                .controlSize(.small)
            } else {
                Text(agent.status.label)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.leading, 2)
    }
}

struct PanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: AppStore
    @ObservedObject var account: AccountStore
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var agentManager = BackgroundAgentManager.shared
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showAccount = false
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            updateBanner

            accountSection

            if account.status.allowsUse && !coordinator.hasKey {
                keysNotice
                Divider()
            }

            if let clarify = coordinator.pendingClarification {
                ClarifyView(clarification: clarify,
                            onPick: { coordinator.answerClarification($0) },
                            onDismiss: { coordinator.dismissClarification() })
                Divider()
            }

            if !agentManager.agents.isEmpty {
                agentsSection
                Divider()
            }

            controls
            dictateRow

            if !coordinator.accessibilityTrusted {
                accessibilityNotice
            }
            voiceReplyRow
            pushToDictateRow
            Divider()

            if let report = coordinator.lastReport {
                reportView(report)
                Divider()
            }

            activity
        }
        .padding(14)
        .frame(width: 380)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.gobackward").foregroundStyle(.secondary)
                Text("Background agents").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(agentManager.agents.prefix(4)) { agent in
                AgentRow(agent: agent)
            }
        }
    }

    private var voiceReplyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: coordinator.hasElevenLabsKey ? "speaker.wave.2.fill" : "speaker.wave.1")
                    .foregroundStyle(coordinator.hasElevenLabsKey ? .green : .secondary)
                Text(coordinator.hasElevenLabsKey ? "Spoken replies: ElevenLabs" : "Spoken replies: system voice")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if coordinator.hasElevenLabsKey {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder").foregroundStyle(.secondary)
                    Text("Transcription").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { coordinator.speechEngine },
                        set: { coordinator.speechEngine = $0 }
                    )) {
                        ForEach(SpeechEngine.allCases, id: \.self) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)
                }
            }
        }
    }

    // Push-to-dictate: a chord/voice phrase that dictates straight to the cursor.
    private var pushToDictateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text("Push-to-dictate").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { coordinator.dictationChord },
                    set: { coordinator.dictationChord = $0 }
                )) {
                    ForEach(DictationChord.allCases, id: \.self) { chord in
                        Text(chord.label).tag(chord)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            Toggle(isOn: Binding(
                get: { coordinator.cleanUpInsertedText },
                set: { coordinator.cleanUpInsertedText = $0 }
            )) {
                Text("Clean up dictated text before pasting").font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Text("End after pause").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { coordinator.recorderEndPause },
                    set: { coordinator.recorderEndPause = $0 }
                )) {
                    Text("15s").tag(TimeInterval(15))
                    Text("30s").tag(TimeInterval(30))
                    Text("60s").tag(TimeInterval(60))
                    Text("2m").tag(TimeInterval(120))
                    Text("Never").tag(TimeInterval(0))
                }
                .labelsHidden().frame(width: 90)
            }
            Text(coordinator.dictationChord == .off
                 ? "Chord off — say “Mama dictate this” to start, “Mama stop dictating” to paste."
                 : "Press the chord (or say “Mama dictate this”) to start; press again or say “Mama stop dictating” to paste at your cursor.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Shows only when an update exists — invisible the rest of the time, which
    /// is almost always. A `.required` build (below the server's floor) reads as
    /// red rather than the softer accent, but still just links out; nothing here
    /// disables the app.
    @ViewBuilder
    private var updateBanner: some View {
        switch updates.status {
        case .upToDate:
            EmptyView()
        case .available(let version, let url, let notes),
             .required(let version, let url, let notes):
            let mandatory = { if case .required = updates.status { return true } else { return false } }()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: mandatory ? "exclamationmark.arrow.triangle.2.circlepath"
                                                : "arrow.down.circle.fill")
                        .foregroundStyle(mandatory ? .red : Color.accentColor)
                    Text(mandatory ? "Update required — v\(version)"
                                   : "Update available — v\(version)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if updater.phase.busy {
                        ProgressView().controlSize(.small)
                    } else if let dmg = updates.dmgURL {
                        // One deliberate click; the app does the rest (download,
                        // verify it's ours, swap, relaunch). Never silent.
                        Button("Update now") { updater.install(fromDMG: dmg) }
                            .font(.caption)
                    } else {
                        Button("Get it") { NSWorkspace.shared.open(url) }
                            .font(.caption)
                    }
                }
                if updater.phase.busy || updater.phase != .idle {
                    Text(updater.phase.label).font(.caption2).foregroundStyle(.secondary)
                }
                if case .failed = updater.phase {
                    // Self-update failed — the old manual path is the fallback.
                    HStack(spacing: 8) {
                        Button("Download in browser") { NSWorkspace.shared.open(url) }
                        Button("Dismiss") { updater.dismissFailure() }
                    }
                    .font(.caption2)
                }
                if !notes.isEmpty {
                    Text(notes).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background((mandatory ? Color.red : Color.accentColor).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8))
            Divider()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "hand.raised.slash")
            Text(AppIdentity.displayName).font(.headline)
            Spacer()
            Text(coordinator.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Account state. Deliberately quiet while things are fine — a signed-in,
    /// active user sees one caption line; only a signed-out or lapsed app gets the
    /// full banner. Signing in opens the website, which hands a token back over
    /// the `lookmomnohands://` scheme; there's no key to paste here anymore.
    @ViewBuilder
    private var accountSection: some View {
        let fullyActive = { if case .licensed = account.status { return true } else { return false } }()
        if fullyActive && !showAccount {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(accountLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Manage") { showAccount = true }.font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: account.status.allowsUse ? "person.crop.circle.badge.checkmark" : "lock.fill")
                        .foregroundStyle(account.status.allowsUse ? .orange : .red)
                    Text(accountHeading).font(.callout.weight(.medium))
                    Spacer()
                    if showAccount { Button("Close") { showAccount = false }.font(.caption) }
                }

                if let err = account.lastError, !err.isEmpty {
                    Text(err).font(.caption2)
                        .foregroundStyle(account.status.allowsUse ? Color.secondary : Color.red)
                } else if !account.isSignedIn {
                    Text("Sign in with the account you subscribed with — your plan and keys come with you.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !fullyActive, let email = account.info?.email {
                    Text("Signed in as \(email)").font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if account.isSignedIn {
                        if !account.status.isPaid {
                            Button("Subscribe") { NSWorkspace.shared.open(LicenseConfig.purchaseURL) }
                                .font(.caption)
                        }
                        Button(account.isWorking ? "Refreshing…" : "Sign out") {
                            account.signOut()
                            showAccount = false
                        }
                        .font(.caption).disabled(account.isWorking)
                    } else {
                        Button(account.isWorking ? "Signing in…" : "Sign in") {
                            NSWorkspace.shared.open(AccountStore.signInURL)
                        }
                        .font(.caption).disabled(account.isWorking)
                    }
                    Spacer()
                }
            }
            .padding(10)
            .background((account.status.allowsUse ? Color.orange : Color.red).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        Divider()
    }

    /// One-line "email · Plan" (with a sub-user tag) for the quiet active state.
    private var accountLine: String {
        guard let info = account.info else { return account.status.label }
        let plan = info.plan.capitalized
        return info.isSubUser ? "\(info.email) · \(plan) (sub-user)" : "\(info.email) · \(plan)"
    }

    /// The banner heading: the account line when active, otherwise the status
    /// ("No active subscription", "Not signed in", …).
    private var accountHeading: String {
        if !account.isSignedIn { return "Sign in to activate" }
        if case .licensed = account.status { return accountLine }
        return account.status.label
    }

    /// Shown only when signed in and active but the account has no Anthropic key
    /// set yet — the holder needs to add it once on the website.
    private var keysNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.slash").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Anthropic key on your account yet").font(.caption)
                Text("Set it once at nohandsapp.com — every device picks it up.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(AccountStore.accountURL) }.font(.caption)
        }
    }

    private var controls: some View {
        HStack {
            if !(coordinator.micAuthorized && coordinator.speechAuthorized) {
                Button("Grant mic & speech") { coordinator.requestPermissions { _ in } }
            } else if !coordinator.isRunning {
                // Always-listening starts itself; this shows only when the audio
                // pipeline died and needs a manual kick.
                Button("Resume listening") { coordinator.start() }
            }
            Button("Dashboard") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    // The unified recorder: record a note of any length; it transcribes as you go
    // and processes into a note on stop. Push-to-dictate (the chord) is the insert
    // variant of the same recorder.
    private var dictateRow: some View {
        HStack(spacing: 8) {
            if coordinator.phase == .recording || coordinator.liveActive {
                Image(systemName: "waveform.badge.mic").foregroundStyle(.red)
                Text("Recording — pause or say “Mama stop” to finish").font(.caption)
                Spacer()
                Button("Stop") { coordinator.stopRecording() }
            } else {
                Button {
                    coordinator.startRecording(output: .note)
                } label: {
                    Label("Record a note", systemImage: "mic.circle.fill")
                }
                .disabled(!coordinator.isRunning || !coordinator.hasKey || !account.status.allowsUse)
                Spacer()
            }
        }
    }

    private var accessibilityNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click.badge.clock").foregroundStyle(.orange)
            Text("Clicking/typing needs Accessibility").font(.caption)
            Spacer()
            Button("Enable…") { coordinator.requestAccessibility() }
        }
    }

    @ViewBuilder
    private func reportView(_ report: DictationReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.title.isEmpty {
                Text(report.title).font(.headline)
            }
            if !report.summary.isEmpty {
                Label("Summary", systemImage: "text.line.first.and.arrowtriangle.forward").font(.caption.bold())
                Text(report.summary).font(.callout)
            }
            if !report.keyPoints.isEmpty {
                Label("Key points", systemImage: "list.bullet").font(.caption.bold())
                ForEach(Array(report.keyPoints.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").font(.callout)
                }
            }
            if !report.actionItems.isEmpty {
                Label("Action items", systemImage: "checklist").font(.caption.bold())
                ForEach(Array(report.actionItems.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").font(.callout)
                }
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.reportText(report), forType: .string)
                } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    .font(.caption)
                Spacer()
            }

            DisclosureGroup("Transcript") {
                ScrollView {
                    Text(report.transcript).font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private static func reportText(_ r: DictationReport) -> String {
        var out = ""
        if !r.title.isEmpty { out += "\(r.title)\n\n" }
        if !r.summary.isEmpty { out += "Summary:\n\(r.summary)\n\n" }
        if !r.keyPoints.isEmpty { out += "Key points:\n" + r.keyPoints.map { "• \($0)" }.joined(separator: "\n") + "\n\n" }
        if !r.actionItems.isEmpty { out += "Action items:\n" + r.actionItems.map { "• \($0)" }.joined(separator: "\n") + "\n\n" }
        out += "Transcript:\n\(r.transcript)"
        return out
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent activity").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.transcripts.count) transcripts stored")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.activity.prefix(12)) { entry in
                        Text(entry.line).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 100)
            launchAtLoginRow
            versionRow
        }
    }

    /// Open-at-login toggle. A voice assistant you have to remember to launch
    /// isn't really hands-free, so this is on by intent for most users — but it's
    /// their machine, so it's a choice, defaulting to whatever the OS reports.
    private var launchAtLoginRow: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { want in
                    let ok = LoginItem.setEnabled(want)
                    // Reflect the OS's actual state, not the requested one — if the
                    // user has to approve it in Settings, the switch shouldn't lie.
                    launchAtLogin = ok ? want : LoginItem.isEnabled
                }
            )) {
                Text("Open at login").font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            if LoginItem.needsApproval {
                Button("Approve…") { LoginItem.openLoginItemsSettings() }
                    .font(.caption2)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    /// Version + manual update check. The banner above handles the "there's an
    /// update" case on its own; this is for the user who wants to check on demand
    /// and to see what they're running.
    ///
    /// Every press has to visibly land. When the answer is "nothing new" the
    /// banner stays empty by design, so without the spinner and the confirmation
    /// line here the button looks broken — indistinguishable from an update check
    /// that never fired.
    private var versionRow: some View {
        HStack(spacing: 6) {
            Text("v\(updates.currentVersion)").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if updates.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption2).foregroundStyle(.secondary)
            } else if case .upToDate = updates.status {
                switch updates.manualResult {
                case .current:
                    Text("Up to date").font(.caption2).foregroundStyle(.secondary)
                case .unreachable:
                    Text("Couldn't reach the server").font(.caption2).foregroundStyle(.orange)
                case .none:
                    EmptyView()
                }
                Button("Check for updates") { updates.checkInBackground(force: true) }
                    .font(.caption2)
            } else {
                Text("Update available").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.top, 2)
    }
}

/// The on-screen clarification prompt: shows the model's question and lets the
/// user answer by clicking (the same answer they could speak).
struct ClarifyView: View {
    let clarification: Clarification
    let onPick: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
                Text(clarification.question).font(.callout.weight(.medium))
                Spacer()
                Button { onDismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !clarification.options.isEmpty {
                ForEach(clarification.options, id: \.self) { option in
                    Button { onPick(option) } label: {
                        HStack {
                            Text(option)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("or just say your answer")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
