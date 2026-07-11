import SwiftUI
import AppKit

/// The full dashboard window: a searchable copy of every transcript and the
/// complete activity log. Both are backed by files on disk (see AppStore).
struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            MemoryTab(coordinator: coordinator, environment: coordinator.environment, knowledge: coordinator.knowledge)
                .tabItem { Label("Memory", systemImage: "brain") }
            LiveTab(coordinator: coordinator)
                .tabItem { Label("Live", systemImage: "waveform") }
            TranscriptsTab(store: coordinator.store)
                .tabItem { Label("Transcripts", systemImage: "text.book.closed") }
            VocabularyTab(vocabulary: coordinator.vocabulary,
                          onChange: { coordinator.refreshContextualPhrases() })
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ProfilesTab(profiles: coordinator.profiles)
                .tabItem { Label("Profiles", systemImage: "slider.horizontal.3") }
            ProceduresTab(procedures: coordinator.procedures)
                .tabItem { Label("Procedures", systemImage: "list.number") }
            ActivityTab(store: coordinator.store)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            SettingsTab(coordinator: coordinator)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// What the assistant knows right now: the sticky focus it's working in, a live
/// tree of everything open (apps → windows → tabs), and the recent-action memory
/// that keeps commands on-track across turns.
private struct MemoryTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var environment: EnvironmentTracker
    @ObservedObject var knowledge: KnowledgeStore
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
                    ForEach(environment.snapshot.apps) { app in
                        DisclosureGroup {
                            ForEach(app.windows) { win in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(win.title.isEmpty ? "(untitled window)" : win.title)
                                        .font(.callout)
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

/// Taught procedures: the growing library of "here's how I do X." You teach them
/// by voice ("here's how to create a new Claude Code session: …") or edit here; a
/// matching command follows the steps.
private struct ProceduresTab: View {
    @ObservedObject var procedures: ProcedureStore
    @State private var selection: String?
    @State private var name = ""
    @State private var triggers = ""
    @State private var steps = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(procedures.procedures) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name.isEmpty ? "(unnamed)" : p.name)
                            if !p.triggers.isEmpty {
                                Text(p.triggers.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(p.id)
                        .contextMenu { Button("Delete", role: .destructive) { procedures.remove(p.id) } }
                    }
                }
                Divider()
                Button { newProcedure() } label: { Label("New procedure", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 200)

            editor.frame(minWidth: 340).padding()
        }
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
                    .font(.body).frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } else {
            Text("Select or add a procedure").foregroundStyle(.secondary)
        }
    }

    private func loadDraft() {
        guard let id = selection, let p = procedures.procedures.first(where: { $0.id == id }) else {
            name = ""; triggers = ""; steps = ""   // no selection / stale id → clear, never show a stale draft
            return
        }
        name = p.name; triggers = p.triggers.joined(separator: ", "); steps = p.steps
    }

    private func newProcedure() {
        let p = Procedure(name: "New procedure", steps: "")
        procedures.upsert(p)
        selection = p.id
        loadDraft()
    }

    private func save() {
        guard let id = selection else { return }
        let trig = triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        procedures.upsert(Procedure(id: id, name: name, triggers: trig, steps: steps))
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
        HSplitView {
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
            .frame(minWidth: 200)

            editor
                .frame(minWidth: 320)
                .padding()
        }
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

    private let pauseOptions: [(String, TimeInterval)] =
        [("5 seconds", 5), ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
         ("2 minutes", 120), ("Never (stop manually)", 0)]

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Engine", selection: $coordinator.speechEngine) {
                    ForEach(SpeechEngine.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Anthropic key") { statusPill(coordinator.hasKey) }
                LabeledContent("ElevenLabs key") { statusPill(coordinator.hasElevenLabsKey) }
                Text("Add or change keys from the menu-bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Picker("Push-to-dictate chord", selection: $coordinator.dictationChord) {
                    ForEach(DictationChord.allCases, id: \.self) { Text($0.label).tag($0) }
                }
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
            }
        }
        .formStyle(.grouped)
    }

    private func statusPill(_ ok: Bool) -> some View {
        Label(ok ? "Connected" : "Not set", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .font(.caption)
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

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { rec in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: rec.kind == "dictation" ? "note.text" : "cursorarrow.rays")
                        Text(rec.summary ?? rec.transcript)
                            .lineLimit(1)
                        Spacer()
                    }
                    Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tag(rec.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search transcripts")
            .navigationTitle("Transcripts")
            .frame(minWidth: 260)
        } detail: {
            if let id = selection, let rec = store.transcripts.first(where: { $0.id == id }) {
                TranscriptDetail(record: rec)
            } else {
                ContentUnavailableView("No transcript selected",
                                       systemImage: "text.book.closed",
                                       description: Text("\(store.transcripts.count) stored"))
            }
        }
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
