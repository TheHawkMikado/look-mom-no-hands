import Foundation
import Combine

// "Open ChatGPT" is ambiguous when ChatGPT is both an installed app and a
// website. The first time, the app asks — "the app, or Chrome?" — and
// remembers the answer per thing, so it never asks about that one again.
// Remembered choices are listed in Memory › Where things open, and can be
// removed there to be asked again.

enum OpenChoice: String, Codable, Sendable {
    case app       // the installed macOS application
    case browser   // the website, in Chrome when it is installed
}

struct OpenPreference: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String          // normalized key ("chatgpt")
    var displayName: String   // as spoken/shown ("ChatGPT")
    var choice: OpenChoice
    var url: String           // the web address for the browser choice
    let createdAt: Date

    init(id: String = UUID().uuidString, name: String, displayName: String,
         choice: OpenChoice, url: String, createdAt: Date = Date()) {
        self.id = id
        self.name = OpenPreferenceStore.key(name)
        self.displayName = displayName
        self.choice = choice
        self.url = url
        self.createdAt = createdAt
    }
}

@MainActor
final class OpenPreferenceStore: ObservableObject {
    @Published private(set) var preferences: [OpenPreference] = []

    private let fileURL: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".open-preferences")

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("open-preferences.json")
        load()
    }

    func lookup(_ name: String) -> OpenPreference? {
        let k = Self.key(name)
        guard !k.isEmpty else { return nil }
        return preferences.first { $0.name == k }
    }

    func set(name: String, choice: OpenChoice, url: String) {
        let pref = OpenPreference(name: name, displayName: name, choice: choice, url: url)
        guard !pref.name.isEmpty else { return }
        preferences.removeAll { $0.name == pref.name }
        preferences.insert(pref, at: 0)
        persist()
    }

    func remove(_ id: String) {
        preferences.removeAll { $0.id == id }
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([OpenPreference].self, from: data) else { return }
        preferences = decoded
    }

    private func persist() {
        let snapshot = preferences
        let url = fileURL
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// "Google Chrome" / "chatgpt" / " ChatGPT.app " → "chatgpt".
    nonisolated static func key(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".app") { s.removeLast(4) }
        return s.replacingOccurrences(of: "the ", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Things that are both a Mac app and a web app, by the name people say.
    /// The planner also fills `url` on open_app for anything it knows is a web
    /// app, so this table is the floor, not the ceiling.
    nonisolated static let webEquivalents: [String: String] = [
        "chatgpt": "chatgpt.com", "claude": "claude.ai", "gemini": "gemini.google.com",
        "perplexity": "perplexity.ai", "slack": "app.slack.com", "discord": "discord.com/app",
        "notion": "notion.so", "spotify": "open.spotify.com", "zoom": "zoom.us",
        "figma": "figma.com", "canva": "canva.com", "trello": "trello.com", "asana": "app.asana.com",
        "linear": "linear.app", "whatsapp": "web.whatsapp.com", "telegram": "web.telegram.org",
        "messenger": "messenger.com", "gmail": "mail.google.com", "google drive": "drive.google.com",
        "google docs": "docs.google.com", "google calendar": "calendar.google.com",
        "google chat": "chat.google.com", "dropbox": "dropbox.com", "github": "github.com",
        "youtube": "youtube.com", "netflix": "netflix.com", "microsoft teams": "teams.microsoft.com",
        "teams": "teams.microsoft.com", "outlook": "outlook.live.com", "onenote": "onenote.com",
        "todoist": "todoist.com", "evernote": "evernote.com", "1password": "my.1password.com",
        "loom": "loom.com", "miro": "miro.com", "airtable": "airtable.com", "hubspot": "app.hubspot.com",
        "gohighlevel": "app.gohighlevel.com", "highlevel": "app.gohighlevel.com",
        "x": "x.com", "twitter": "x.com", "facebook": "facebook.com", "instagram": "instagram.com",
        "linkedin": "linkedin.com", "tiktok": "tiktok.com", "reddit": "reddit.com",
        "obsidian": "obsidian.md", "monday": "monday.com", "clickup": "app.clickup.com",
    ]

    /// The web address for an app name, when it is also a web app.
    nonisolated static func webURL(forApp name: String) -> String? {
        webEquivalents[key(name)]
    }

    /// The app name for a web address, when a Mac app by that name exists:
    /// "https://chatgpt.com/c/123" → "chatgpt".
    nonisolated static func appName(forURL raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let host = s.split(separator: "/").first.map(String.init) ?? s
        guard !host.isEmpty else { return nil }
        // Longest matching table entry wins ("docs.google.com" over "google.com").
        let hits = webEquivalents.filter { _, site in
            let siteHost = site.split(separator: "/").first.map(String.init) ?? site
            return host == siteHost || host.hasSuffix("." + siteHost)
        }
        return hits.max { $0.value.count < $1.value.count }?.key
    }

    /// The (name, url) pair an open step is really about, when it could go
    /// either way. nil when the step is unambiguous (no web twin, or no name).
    nonisolated static func candidate(name target: String, url: String, kind: ScreenAction.Kind) -> (name: String, url: String)? {
        switch kind {
        case .openApp:
            let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let site = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !site.isEmpty { return (name, site) }
            if let site = webURL(forApp: name) { return (name, site) }
            return nil
        case .openURL:
            let site = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !site.isEmpty, let name = appName(forURL: site) else { return nil }
            return (name, site)
        default:
            return nil
        }
    }

    /// The user already said where: "open chatgpt in chrome" / "open the chatgpt app".
    nonisolated static func explicitChoice(in command: String) -> OpenChoice? {
        let c = " " + command.lowercased() + " "
        let browser = [" in chrome", " in the browser", " in a browser", " in my browser", " in safari",
                       " on the web", " the website", " the web version", " in a tab", " in a new tab"]
        let app = [" the app ", " the app.", " desktop app", " the application", " on my computer",
                   " on my mac", " on the mac", " on this computer", " natively", " the mac app", " the installed"]
        if browser.contains(where: { c.contains($0) }) { return .browser }
        if app.contains(where: { c.contains($0) }) { return .app }
        return nil
    }

    /// The spoken (or clicked) answer to "the app, or Chrome?".
    nonisolated static func parseAnswer(_ answer: String) -> OpenChoice? {
        let a = answer.lowercased()
        guard !a.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let browserWords = ["chrome", "browser", "web", "online", "tab", "site", "safari"]
        let appWords = ["app", "application", "computer", "desktop", "mac", "native", "installed", "program"]
        let saysBrowser = browserWords.contains { a.contains($0) }
        let saysApp = appWords.contains { a.contains($0) }
        if saysBrowser && !saysApp { return .browser }
        if saysApp && !saysBrowser { return .app }
        if saysBrowser && saysApp {
            // "the app in chrome"? Take whichever comes last — people correct themselves.
            let bi = browserWords.compactMap { a.range(of: $0)?.lowerBound }.max()
            let ai = appWords.compactMap { a.range(of: $0)?.lowerBound }.max()
            if let bi, let ai { return bi > ai ? .browser : .app }
        }
        return nil
    }
}
