import Foundation
import Combine

/// A named teammate: "Scout — researches and summarizes; keep findings in
/// ~/Notes/research". Saying its name routes a background goal to it, and its
/// instructions ride along as the agent's standing orders. Roles are how the
/// same agent runtime becomes "the research bot" vs "the build bot" without
/// separate code paths.
struct AgentRole: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var instructions: String
    let createdAt: Date

    init(id: String = UUID().uuidString, name: String, instructions: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructions = instructions
        self.createdAt = createdAt
    }
}

@MainActor
final class AgentRoleStore: ObservableObject {
    @Published private(set) var roles: [AgentRole] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".agentroles")

    init(directory: URL) {
        url = directory.appendingPathComponent("agent-roles.json")
        load()
    }

    func upsert(_ role: AgentRole) {
        guard !role.name.isEmpty else { return }
        roles.removeAll { $0.name.lowercased() == role.name.lowercased() && $0.id != role.id }
        if let i = roles.firstIndex(where: { $0.id == role.id }) { roles[i] = role }
        else { roles.insert(role, at: 0) }
        persist()
    }

    func remove(_ id: String) {
        roles.removeAll { $0.id == id }
        persist()
    }

    /// The role whose name appears in the goal, longest name first so "Scout Two"
    /// wins over "Scout". Word-boundary match: a role named "Ed" must not fire
    /// on "download the PDF".
    func match(goal: String) -> AgentRole? {
        let lowered = goal.lowercased()
        return roles
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.count > $1.name.count }
            .first { role in
                lowered.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: role.name.lowercased()) + #"\b"#,
                              options: .regularExpression) != nil
            }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AgentRole].self, from: data) else { return }
        roles = decoded
    }

    private func persist() {
        let snapshot = roles
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
