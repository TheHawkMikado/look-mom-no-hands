import Foundation

/// A calendar connected inside the app ("Connect your calendar"), independent
/// of anything macOS is signed into. Apple/EventKit stays a third, separate
/// source in CalendarMeetings; these two talk to the providers' APIs directly.
enum RemoteCalendarKind: String, CaseIterable, Codable, Sendable {
    case google, microsoft

    var label: String {
        switch self {
        case .google: return "Google Calendar"
        case .microsoft: return "Microsoft Outlook"
        }
    }

    /// A provider appears in Settings only once its OAuth credentials are baked
    /// in — an unconfigured Connect button would be a dead end for customers.
    /// Google's Desktop-type client needs BOTH id and secret for the token
    /// exchange, so the button stays hidden until both exist. Microsoft's code
    /// ships dark until demand earns it an Azure registration.
    var isConfigured: Bool {
        switch self {
        case .google: return !CalendarOAuthClientIDs.google.isEmpty && !CalendarOAuthClientIDs.googleSecret.isEmpty
        case .microsoft: return !CalendarOAuthClientIDs.microsoft.isEmpty
        }
    }
}

/// Developer-owned OAuth client identifiers. The client IDs are genuinely
/// public (they ride in every auth URL). The Google client *secret* is only
/// "non-confidential" inside a shipped binary — this repo is PUBLIC, and
/// Google's leak scanner disables clients whose secret it finds in source —
/// so it is injected at build time instead: Scripts/common.sh writes the
/// LMNH_GOOGLE_OAUTH_SECRET env value (an Actions secret in CI) into the
/// bundle's Info.plist, and it is read back here at runtime.
enum CalendarOAuthClientIDs {
    static let google = "213171066367-npg8qvo0cmjp4h0615e7gund6nfini9d.apps.googleusercontent.com"
    static var googleSecret: String {
        (Bundle.main.infoDictionary?["LMNHGoogleOAuthSecret"] as? String)
            ?? ProcessInfo.processInfo.environment["LMNH_GOOGLE_OAUTH_SECRET"]   // bare `swift run` dev builds
            ?? ""
    }
    static let microsoft = ""
}

/// Everything needed to keep one provider connection alive, stored as JSON in
/// the Keychain (service-level encryption; never in UserDefaults).
struct RemoteCalendarTokens: Codable, Sendable {
    var kind: RemoteCalendarKind
    var email: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    static func keychainAccount(_ kind: RemoteCalendarKind) -> String { "calendar.\(kind.rawValue)" }
}

/// Stateless API client for one provider. All parsing is pure static funcs on
/// fixture-friendly Data, so the wire formats are pinned by unit tests.
struct RemoteCalendarClient: Sendable {

    enum ClientError: Error, CustomStringConvertible {
        case http(Int, String)
        case reauthNeeded     // refresh token rejected — the user must reconnect

        var description: String {
            switch self {
            case .http(let s, let body): return "HTTP \(s): \(body.prefix(200))"
            case .reauthNeeded: return "the connection expired — reconnect in Settings"
            }
        }
    }

    let kind: RemoteCalendarKind

    // MARK: Connect (interactive)

    /// Runs the browser sign-in and returns a ready token set.
    func connect() async throws -> RemoteCalendarTokens {
        let t: CalendarOAuth.TokenResponse
        switch kind {
        case .google:
            t = try await CalendarOAuth.run(
                authEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenEndpoint: "https://oauth2.googleapis.com/token",
                clientID: CalendarOAuthClientIDs.google,
                clientSecret: CalendarOAuthClientIDs.googleSecret.isEmpty ? nil : CalendarOAuthClientIDs.googleSecret,
                scope: "https://www.googleapis.com/auth/calendar.readonly openid email",
                redirectHost: "127.0.0.1",   // what Google registers for desktop loopback
                // offline + consent: without both, Google omits the refresh
                // token on re-grants and the connection dies in an hour.
                extraAuthParams: ["access_type": "offline", "prompt": "consent"])
        case .microsoft:
            t = try await CalendarOAuth.run(
                authEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                clientID: CalendarOAuthClientIDs.microsoft,
                clientSecret: nil,            // public client — PKCE only
                scope: "Calendars.Read offline_access openid email",
                redirectHost: "localhost")    // what Azure registers for public clients
        }
        guard let refresh = t.refreshToken, !refresh.isEmpty else {
            throw CalendarOAuth.OAuthError.tokenExchange("no refresh token — reconnect and approve offline access")
        }
        let email = t.idToken.flatMap { Self.email(fromIDToken: $0) } ?? kind.label
        return RemoteCalendarTokens(kind: kind, email: email,
                                    accessToken: t.accessToken, refreshToken: refresh,
                                    expiresAt: Date().addingTimeInterval(t.expiresIn))
    }

    /// The signed-in address, read from the id_token's claims (display only —
    /// the token came straight from the provider over TLS). Pure — unit-tested.
    static func email(fromIDToken idToken: String) -> String? {
        let claims = CalendarOAuth.jwtClaims(idToken)
        return (claims?["email"] as? String) ?? (claims?["preferred_username"] as? String)
    }

    // MARK: Refresh

    /// Returns a fresh token set when the current one is within two minutes of
    /// expiry, nil when it's still fine. An invalid_grant means the user
    /// revoked us (or Google's testing-mode 7-day expiry hit) — surface
    /// reauthNeeded so the UI flips back to Connect instead of failing forever.
    func refreshedIfNeeded(_ tokens: RemoteCalendarTokens) async throws -> RemoteCalendarTokens? {
        guard tokens.expiresAt.timeIntervalSinceNow < 120 else { return nil }
        var fields = ["grant_type": "refresh_token",
                      "refresh_token": tokens.refreshToken,
                      "client_id": kind == .google ? CalendarOAuthClientIDs.google : CalendarOAuthClientIDs.microsoft]
        if kind == .google, !CalendarOAuthClientIDs.googleSecret.isEmpty {
            fields["client_secret"] = CalendarOAuthClientIDs.googleSecret
        }
        if kind == .microsoft { fields["scope"] = "Calendars.Read offline_access openid email" }
        let endpoint = kind == .google ? "https://oauth2.googleapis.com/token"
                                       : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        do {
            let t = try await CalendarOAuth.exchange(tokenEndpoint: endpoint, fields: fields)
            var fresh = tokens
            fresh.accessToken = t.accessToken
            // Providers rotate refresh tokens at will; keep whichever is newest.
            if let r = t.refreshToken, !r.isEmpty { fresh.refreshToken = r }
            fresh.expiresAt = Date().addingTimeInterval(t.expiresIn)
            return fresh
        } catch let error as CalendarOAuth.OAuthError {
            if case .tokenExchange(let body) = error, body.contains("invalid_grant") {
                throw ClientError.reauthNeeded
            }
            throw error
        }
    }

    // MARK: Events

    /// Upcoming meetings in the window, already filtered to events that carry
    /// a Meet/Zoom/Teams link.
    func upcomingMeetings(tokens: RemoteCalendarTokens,
                          from: Date, to: Date) async throws -> [CalendarMeetings.UpcomingMeeting] {
        switch kind {
        case .google:
            // All selected calendars, not just primary — the user's businesses
            // live on separate calendars. Capped so one account can't fan out
            // into dozens of requests every refresh.
            let listData = try await get("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&fields=items(id,selected,primary)",
                                         token: tokens.accessToken)
            let ids = Self.googleCalendarIDs(from: listData)
            var out: [CalendarMeetings.UpcomingMeeting] = []
            let iso = ISO8601DateFormatter()
            for id in ids {
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "@+/"))) ?? id
                let url = "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events?singleEvents=true&orderBy=startTime&maxResults=50&timeMin=\(iso.string(from: from))&timeMax=\(iso.string(from: to))"
                let data = try await get(url, token: tokens.accessToken)
                out += Self.googleMeetings(from: data)
            }
            return out
        case .microsoft:
            let fmt = ISO8601DateFormatter()
            let url = "https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=\(fmt.string(from: from))&endDateTime=\(fmt.string(from: to))&$top=50&$select=id,subject,start,end,isAllDay,isCancelled,location,onlineMeeting,bodyPreview"
            let data = try await get(url, token: tokens.accessToken,
                                     headers: ["Prefer": "outlook.timezone=\"UTC\""])
            return Self.microsoftMeetings(from: data)
        }
    }

    private func get(_ url: String, token: String, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw ClientError.reauthNeeded }
            throw ClientError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    // MARK: Parsing (pure — unit-tested against wire fixtures)

    /// Selected calendar ids, primary first, capped at 10.
    static func googleCalendarIDs(from data: Data) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        let selected = items.filter { ($0["selected"] as? Bool) ?? false || ($0["primary"] as? Bool) ?? false }
        let ordered = selected.sorted { (($0["primary"] as? Bool) ?? false) && !(($1["primary"] as? Bool) ?? false) }
        return Array(ordered.compactMap { $0["id"] as? String }.prefix(10))
    }

    static func googleMeetings(from data: Data) -> [CalendarMeetings.UpcomingMeeting] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return items.compactMap { e in
            guard (e["status"] as? String) != "cancelled",
                  let id = e["id"] as? String,
                  let start = (e["start"] as? [String: Any])?["dateTime"] as? String,
                  let end = (e["end"] as? [String: Any])?["dateTime"] as? String,
                  let startDate = iso.date(from: start) ?? iso.date(from: start + "Z"),
                  let endDate = iso.date(from: end) ?? iso.date(from: end + "Z")
            else { return nil }   // all-day events have "date", not "dateTime" — skipped by design
            // The link can be structured (conferenceData / hangoutLink) or
            // pasted into location/description — scan all of it with the same
            // detector the rest of the app uses.
            let entryPoints = (((e["conferenceData"] as? [String: Any])?["entryPoints"]) as? [[String: Any]])?
                .compactMap { $0["uri"] as? String }.joined(separator: "\n") ?? ""
            let haystack = [entryPoints,
                            e["hangoutLink"] as? String ?? "",
                            e["location"] as? String ?? "",
                            e["description"] as? String ?? ""].joined(separator: "\n")
            guard let link = MeetingLink.detect(in: haystack) else { return nil }
            return CalendarMeetings.UpcomingMeeting(id: "g:\(id)#\(startDate.timeIntervalSince1970)",
                                                    title: (e["summary"] as? String) ?? "meeting",
                                                    start: startDate, end: endDate, link: link)
        }
    }

    /// Graph returns "2026-10-03T17:00:00.0000000" (7-digit fraction, no zone;
    /// the Prefer header pins it to UTC). Pure — unit-tested.
    static func graphDate(_ value: String) -> Date? {
        let trimmed = value.split(separator: ".").first.map(String.init) ?? value
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: trimmed)
    }

    static func microsoftMeetings(from data: Data) -> [CalendarMeetings.UpcomingMeeting] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = json["value"] as? [[String: Any]] else { return [] }
        return items.compactMap { e in
            guard !((e["isAllDay"] as? Bool) ?? false),
                  !((e["isCancelled"] as? Bool) ?? false),
                  let id = e["id"] as? String,
                  let start = (e["start"] as? [String: Any])?["dateTime"] as? String,
                  let end = (e["end"] as? [String: Any])?["dateTime"] as? String,
                  let startDate = graphDate(start), let endDate = graphDate(end)
            else { return nil }
            let haystack = [((e["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String) ?? "",
                            ((e["location"] as? [String: Any])?["displayName"] as? String) ?? "",
                            (e["bodyPreview"] as? String) ?? ""].joined(separator: "\n")
            guard let link = MeetingLink.detect(in: haystack) else { return nil }
            return CalendarMeetings.UpcomingMeeting(id: "m:\(id)#\(startDate.timeIntervalSince1970)",
                                                    title: (e["subject"] as? String) ?? "meeting",
                                                    start: startDate, end: endDate, link: link)
        }
    }
}
