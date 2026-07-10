import SwiftUI
import AppKit

/// The full dashboard window: a searchable copy of every transcript and the
/// complete activity log. Both are backed by files on disk (see AppStore).
struct DashboardView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TabView {
            TranscriptsTab(store: store)
                .tabItem { Label("Transcripts", systemImage: "text.book.closed") }
            ActivityTab(store: store)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 720, minHeight: 480)
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
                    Text(record.kind.capitalized).font(.headline)
                    Spacer()
                    Text(record.date.formatted(date: .long, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let summary = record.summary {
                    section("Summary") { Text(summary) }
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
        if let s = record.summary { out += "Summary:\n\(s)\n\n" }
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
                    NSPasteboard.general.setString(store.activity.reversed().joined(separator: "\n"), forType: .string)
                } label: { Label("Copy log", systemImage: "doc.on.doc") }
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.activity.enumerated()), id: \.offset) { _, line in
                        Text(line)
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
