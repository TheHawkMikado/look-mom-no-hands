import Foundation
import Combine

/// The user's processing profiles — named instruction sets that decide how a
/// recording becomes a note. Seeded with built-ins on first run; the user can
/// add/edit/delete their own and pick which is active. Persisted to disk; the
/// active profile's instructions are injected into the report prompt.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ProcessingProfile] = []
    @Published var activeID: String {
        didSet { UserDefaults.standard.set(activeID, forKey: Self.activeKey) }
    }

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".profiles")
    private static let activeKey = "activeProfileID"

    init(directory: URL) {
        url = directory.appendingPathComponent("profiles.json")
        activeID = UserDefaults.standard.string(forKey: Self.activeKey) ?? "builtin.general"
        load()
    }

    /// The instructions of the active profile (falls back to the first profile),
    /// or "" if somehow none — callers treat "" as "use the default framing."
    var activeInstructions: String {
        (profiles.first { $0.id == activeID } ?? profiles.first)?.instructions ?? ""
    }

    var active: ProcessingProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    func add(name: String, instructions: String) {
        let p = ProcessingProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !p.name.isEmpty else { return }
        profiles.append(p)
        activeID = p.id
        persist()
    }

    func update(_ id: String, name: String, instructions: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[i].instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Removes a user profile (built-ins can't be deleted). Keeps the active
    /// selection valid.
    func remove(_ id: String) {
        guard let p = profiles.first(where: { $0.id == id }), !p.builtIn else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles.first?.id ?? "builtin.general" }
        persist()
    }

    // MARK: Persistence

    private func load() {
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ProcessingProfile].self, from: $0) } ?? []
        // Always (re)present the built-ins so a new seed appears for existing users,
        // without clobbering the user's edits to a built-in or their own profiles.
        var merged = saved
        for seed in ProcessingProfile.seeds where !merged.contains(where: { $0.id == seed.id }) {
            merged.append(seed)
        }
        // Built-ins first (seed order), then the user's own.
        let order = ProcessingProfile.seeds.map(\.id)
        profiles = merged.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
        if !profiles.contains(where: { $0.id == activeID }) { activeID = profiles.first?.id ?? "builtin.general" }
    }

    private func persist() {
        let snapshot = profiles
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
