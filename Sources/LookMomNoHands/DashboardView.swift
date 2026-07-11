import SwiftUI
import AppKit

/// The full dashboard window: a searchable copy of every transcript and the
/// complete activity log. Both are backed by files on disk (see AppStore).
struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            LiveTab(coordinator: coordinator)
                .tabItem { Label("Live", systemImage: "waveform") }
            TranscriptsTab(store: coordinator.store)
                .tabItem { Label("Transcripts", systemImage: "text.book.closed") }
            VocabularyTab(vocabulary: coordinator.vocabulary,
                          onChange: { coordinator.refreshContextualPhrases() })
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ActivityTab(store: coordinator.store)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 720, minHeight: 480)
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
                    Button(role: .destructive) { coordinator.stopLiveTranscription() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    Label("Recording…", systemImage: "waveform")
                        .foregroundStyle(.red).font(.callout)
                } else {
                    Button { coordinator.startLiveTranscription() } label: {
                        Label("Start live transcript", systemImage: "record.circle")
                    }
                    .disabled(!coordinator.hasElevenLabsKey)
                }
                Spacer()
                if coordinator.liveBusy { ProgressView().controlSize(.small) }
            }
            if !coordinator.hasElevenLabsKey {
                Text("Add an ElevenLabs API key to enable live transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(coordinator.liveTranscript.isEmpty
                     ? "Nothing captured yet. Press Start and talk — the transcript fills in every ~60 seconds."
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
