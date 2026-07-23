import SwiftUI

@main
struct LookMomNoHandsApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var license = LicenseStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView(coordinator: coordinator, store: coordinator.store, license: license)
        } label: {
            // slash = off, dimmed = standby (wake listening), solid = live session
            Image(nsImage: .brandMark(height: 15,
                                      slashed: !coordinator.isRunning,
                                      dimmed: coordinator.isRunning && !coordinator.isActive))
        }
        .menuBarExtraStyle(.window)

        Window(Self.dashboardTitle, id: "dashboard") {
            DashboardView(coordinator: coordinator)
                .onAppear { DockPresence.dashboardOpened() }
        }
    }

    static let dashboardTitle = "\(AppIdentity.displayName) — Dashboard"
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

struct PanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: AppStore
    @ObservedObject var license: LicenseStore
    @Environment(\.openWindow) private var openWindow
    @State private var keyField = ""
    @State private var elevenField = ""
    @State private var showVoiceSetup = false
    @State private var licenseField = ""
    @State private var showLicenseEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            licenseSection

            if !coordinator.hasKey {
                keyEntry
                Divider()
            }

            if let clarify = coordinator.pendingClarification {
                ClarifyView(clarification: clarify,
                            onPick: { coordinator.answerClarification($0) },
                            onDismiss: { coordinator.dismissClarification() })
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

    private var voiceReplyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: coordinator.hasElevenLabsKey ? "speaker.wave.2.fill" : "speaker.wave.1")
                    .foregroundStyle(coordinator.hasElevenLabsKey ? .green : .secondary)
                Text(coordinator.hasElevenLabsKey ? "Spoken replies: ElevenLabs" : "Spoken replies: system voice")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showVoiceSetup ? "Close" : (coordinator.hasElevenLabsKey ? "Change" : "Add key")) {
                    showVoiceSetup.toggle()
                }
                .font(.caption)
            }
            if showVoiceSetup {
                HStack {
                    SecureField("ElevenLabs API key", text: $elevenField)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        coordinator.setElevenLabsKey(elevenField)
                        elevenField = ""
                        showVoiceSetup = false
                    }
                    .disabled(elevenField.isEmpty)
                }
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

    /// Licence state. Deliberately quiet while things are fine — a paid customer
    /// sees one caption line, and only a blocked app gets the full banner.
    @ViewBuilder
    private var licenseSection: some View {
        if license.status.allowsUse && license.status.isPaid && !showLicenseEntry {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(license.status.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Manage") { showLicenseEntry = true }.font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: license.status.allowsUse ? "clock.badge" : "lock.fill")
                        .foregroundStyle(license.status.allowsUse ? .orange : .red)
                    Text(license.status.label).font(.callout.weight(.medium))
                    Spacer()
                    if showLicenseEntry && license.status.allowsUse {
                        Button("Close") { showLicenseEntry = false }.font(.caption)
                    }
                }

                if !license.status.allowsUse {
                    Text("Your \(license.status == .trialExpired ? "trial has ended" : "licence has lapsed"). Enter a licence key to keep going.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    TextField("NOHANDS-XXXX-XXXX-XXXX", text: $licenseField)
                        .textFieldStyle(.roundedBorder)
                        .disabled(license.isActivating)
                    Button(license.isActivating ? "Checking…" : "Activate") {
                        Task {
                            await license.activate(key: licenseField)
                            if license.status.isPaid {
                                licenseField = ""
                                showLicenseEntry = false
                            }
                        }
                    }
                    .disabled(licenseField.isEmpty || license.isActivating)
                }

                if let err = license.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("Buy a licence") { NSWorkspace.shared.open(LicenseConfig.purchaseURL) }
                        .font(.caption)
                    if license.status.isPaid {
                        Button("Deactivate this Mac") {
                            license.deactivate()
                            showLicenseEntry = false
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
            }
            .padding(10)
            .background((license.status.allowsUse ? Color.orange : Color.red).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        Divider()
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anthropic API key").font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("sk-ant-…", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    coordinator.setAPIKey(keyField)
                    keyField = ""
                }
                .disabled(keyField.isEmpty)
            }
        }
    }

    private var controls: some View {
        HStack {
            if !(coordinator.micAuthorized && coordinator.speechAuthorized) {
                Button("Grant mic & speech") { coordinator.requestPermissions { _ in } }
            } else if coordinator.isRunning {
                Button("Stop listening") { coordinator.stop() }
            } else {
                Button("Start listening") { coordinator.start() }
                    .disabled(!coordinator.hasKey || !license.status.allowsUse)
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
                .disabled(!coordinator.isRunning || !coordinator.hasKey || !license.status.allowsUse)
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
        }
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
