import Foundation

/// Which video-meeting service a link belongs to.
enum MeetingService: String, Sendable, Codable {
    case meet, zoom, teams

    var label: String {
        switch self {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        }
    }

    /// Name of the native macOS app, in the form ScreenController.resolveAppPath
    /// can match ("zoom.us" is the literal bundle name Zoom ships under). Meet
    /// has no desktop app — it's browser-only.
    var appName: String? {
        switch self {
        case .meet: return nil
        case .zoom: return "zoom.us"
        case .teams: return "Microsoft Teams"
        }
    }
}

/// A meeting URL found in spoken text or a calendar event, plus everything the
/// deterministic join flow needs to know about it. All pure — unit-tested.
struct MeetingLink: Sendable, Equatable {
    let service: MeetingService
    let url: String     // normalized https browser URL

    // Meeting URLs hide in prose (calendar notes, spoken text pasted from chat),
    // so each pattern must find the link mid-sentence and stop at whatever
    // punctuation or angle-bracket wrapper the invite glued on.
    private static let patterns: [(MeetingService, NSRegularExpression)] = {
        let tail = #"[^\s<>"'\)\],;]*"#
        let raw: [(MeetingService, String)] = [
            (.meet, #"(?:https?://)?meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"# + tail),
            (.zoom, #"(?:https?://)?[a-zA-Z0-9.-]*zoom\.(?:us|com)/(?:j|my|w|s)/"# + tail),
            (.teams, #"(?:https?://)?teams\.microsoft\.com/l/meetup-join/"# + tail),
            (.teams, #"(?:https?://)?teams\.live\.com/meet/"# + tail)
        ]
        return raw.compactMap { service, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (service, $0) }
        }
    }()

    /// The first meeting link anywhere in `text` (earliest match wins when
    /// several services appear — invites often quote dial-in alternatives after
    /// the real link).
    static func detect(in text: String) -> MeetingLink? {
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, link: MeetingLink)?
        for (service, regex) in patterns {
            guard let m = regex.firstMatch(in: text, range: range),
                  let r = Range(m.range, in: text) else { continue }
            if m.range.location < (best?.location ?? Int.max) {
                var url = String(text[r])
                if !url.contains("://") { url = "https://" + url }
                best = (m.range.location, MeetingLink(service: service, url: url))
            }
        }
        return best?.link
    }

    /// Deep link that opens the meeting directly in the installed native app,
    /// or nil when only the browser can take it. Zoom: only numeric /j/ links
    /// carry a conference number the zoommtg scheme accepts; vanity (/my/) and
    /// webinar links stay in the browser and let Zoom's own redirect take over.
    var appDeepLink: String? {
        guard let comps = URLComponents(string: url), let host = comps.host else { return nil }
        switch service {
        case .meet:
            return nil
        case .zoom:
            let parts = comps.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "j", parts[1].allSatisfy(\.isNumber) else { return nil }
            var deep = "zoommtg://\(host)/join?confno=\(parts[1])"
            if let pwd = comps.queryItems?.first(where: { $0.name == "pwd" })?.value, !pwd.isEmpty {
                deep += "&pwd=\(pwd)"
            }
            return deep
        case .teams:
            guard host == "teams.microsoft.com" else { return nil }
            return url.replacingOccurrences(of: "https://", with: "msteams://")
        }
    }

    /// The room identifier a browser tab title would carry — Meet's dashed room
    /// code ("abc-defg-hij") shows up verbatim in the tab title, which makes it a
    /// far stronger "this tab IS that meeting" signal than the word "meet" (a
    /// substring of every "Meeting notes" window). Nil where titles don't carry it.
    var roomCode: String? {
        guard service == .meet, let comps = URLComponents(string: url) else { return nil }
        return comps.path.split(separator: "/").map(String.init)
            .first { $0.contains("-") && $0.count >= 10 }
    }

    // MARK: Join click-through vocabulary

    // Ordered: the first present label is the next thing to click. Browser
    // mic/cam permission prompts are included DELIBERATELY — the planner is
    // forbidden from touching them, but a spoken "join my meeting" is the user
    // asking for a working meeting, and that consent is what the guardrail
    // protects. (Trade-off, accepted: browsers reuse this button wording for
    // other site permissions, so an unrelated prompt inside the meeting tab
    // during the join window would be granted too.) Matched case-insensitively
    // by containment.
    private static let controlsByService: [MeetingService: [String]] = {
        let shared = ["allow while visiting the site", "allow this time"]
        let perService: [MeetingService: [String]] = [
            .meet: ["join now", "ask to join", "join anyway",
                    "continue without microphone and camera", "got it", "dismiss"],
            .zoom: ["join with computer audio", "join audio by computer", "launch meeting",
                    "join from your browser", "join audio", "i agree", "join meeting", "join"],
            .teams: ["join now", "continue on this browser", "join on the web instead",
                     "use the web app instead", "join meeting", "join"]
        ]
        return perService.mapValues { shared + $0 }
    }()

    /// The next control to click from what's on screen, skipping stepping stones
    /// this join already clicked. Join buttons are deliberately NOT expected in
    /// `alreadyClicked` — a disabled pre-join button swallows the first click and
    /// must stay retryable (the caller rate-limits those instead). Returns the
    /// on-screen label verbatim so the AX click can match it exactly.
    static func nextJoinControl(in labels: [String], service: MeetingService,
                                alreadyClicked: Set<String>) -> String? {
        let lowered = labels.map { ($0, $0.lowercased()) }
        for candidate in controlsByService[service] ?? [] {
            if let hit = lowered.first(where: { $0.1.contains(candidate) && !alreadyClicked.contains($0.0) }) {
                return hit.0
            }
        }
        return nil
    }

    /// A label that means the click actually joins (vs. a cookie/permission
    /// stepping stone) — used to decide the flow reached the point of no return.
    static func isJoinLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("join") || l.contains("launch meeting")
    }

    /// In-meeting toolbar markers: seeing one means we're inside the call.
    static func indicatesInMeeting(_ label: String) -> Bool {
        let l = label.lowercased().trimmingCharacters(in: .whitespaces)
        return l.contains("leave call") || l.contains("leave meeting")
            || l == "leave" || l.contains("end call") || l.contains("hang up")
    }

    /// Controls that leave the meeting, in click order. Deliberately excludes
    /// anything containing "end" — "End meeting for all" would kick everyone out.
    static let leaveControls = ["Leave call", "Leave Meeting", "Leave meeting", "Leave", "Hang up"]

    /// The leave control actually present on screen (verbatim label), or nil.
    /// Matching against the visible snapshot — never a blind AX walk — is what
    /// keeps "leave the meeting" from clicking a lookalike in some other app.
    static func leaveControl(in labels: [String]) -> String? {
        for candidate in leaveControls {
            if let hit = labels.first(where: { $0.lowercased().contains(candidate.lowercased()) }) {
                return hit
            }
        }
        return nil
    }
}
