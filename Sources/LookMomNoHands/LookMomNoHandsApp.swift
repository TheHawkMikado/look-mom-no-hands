import SwiftUI

@main
struct LookMomNoHandsApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            PanelView(coordinator: coordinator, store: coordinator.store)
        } label: {
            // slash = off, outline = standby (wake listening), filled = active session
            Image(systemName: coordinator.isActive ? "waveform.circle.fill"
                            : coordinator.isRunning ? "waveform.circle"
                            : "waveform.slash")
        }
        .menuBarExtraStyle(.window)

        Window("Look Ma, No Hands — Dashboard", id: "dashboard") {
            DashboardView(store: coordinator.store)
        }
    }
}

struct PanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var keyField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !coordinator.hasKey {
                keyEntry
                Divider()
            }

            controls

            if !coordinator.accessibilityTrusted {
                accessibilityNotice
            }
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

    private var header: some View {
        HStack {
            Image(systemName: "hand.raised.slash")
            Text("Look Ma, No Hands").font(.headline)
            Spacer()
            Text(coordinator.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    .disabled(!coordinator.hasKey)
            }
            Button("Dashboard") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
            Label("Summary", systemImage: "text.line.first.and.arrowtriangle.forward").font(.caption.bold())
            Text(report.summary).font(.callout)

            if !report.actionItems.isEmpty {
                Label("Action items", systemImage: "checklist").font(.caption.bold())
                ForEach(Array(report.actionItems.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").font(.callout)
                }
            }

            DisclosureGroup("Transcript") {
                ScrollView {
                    Text(report.transcript).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
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
                    ForEach(Array(store.activity.prefix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
    }
}
