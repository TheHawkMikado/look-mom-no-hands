import Foundation
import AppKit
import EventKit

/// Reads the user's calendar (on-device, read-only) for events carrying a
/// Meet/Zoom/Teams link, so "join my 2pm" resolves to a real URL and — when
/// auto-join is on — meetings join themselves at start time.
@MainActor
final class CalendarMeetings: ObservableObject {

    struct UpcomingMeeting: Identifiable, Sendable, Equatable {
        let id: String        // eventIdentifier + start — occurrences of a recurring series must not collide
        let title: String
        let start: Date
        let end: Date
        let link: MeetingLink
    }

    @Published private(set) var upcoming: [UpcomingMeeting] = []
    @Published private(set) var authorized = false

    /// Asks the coordinator to auto-join a meeting whose start is imminent.
    /// Returns whether the join actually STARTED — a "no" (Mac busy, session
    /// live) leaves the meeting unfired so the next tick can retry while the
    /// join window is still open.
    var onMeetingStarting: ((UpcomingMeeting) -> Bool)?
    var autoJoinEnabled = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var ticks = 0
    private var fired: Set<String> = []   // occurrences already auto-joined this launch
    private var log: (String) -> Void = { _ in }

    /// Deliberately does NOT trigger the TCC prompt: the calendar is an opt-in
    /// convenience, and every existing user hitting a full-calendar-access dialog
    /// at launch (before ever asking for meetings) would read as a grab. The
    /// prompt fires from requestAccess() — the Settings button, the auto-join
    /// toggle, or the first "join my meeting" that needs the calendar.
    func start(log: @escaping (String) -> Void) {
        self.log = log
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            authorized = true
            refresh()
        }
        // Tolerance + .common mode match ProcedureScheduler: a menu being open or
        // a window drag must not suspend the tick — checkDue's one-minute window
        // means a suspended tick is an auto-join silently skipped.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ticks += 1
                // The EventKit rescan is main-thread work; change notifications
                // plus a 5-minute horizon refresh keep it fresh — only the due
                // check needs 30s granularity.
                if self.ticks % 10 == 0 { self.refresh() }
                self.checkDue()
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
            refresh()
        case .denied, .restricted:
            // macOS never re-prompts after a denial — the only path back is
            // System Settings, so take the user straight there.
            log("calendar access was denied — opening System Settings")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        default:
            store.requestFullAccessToEvents { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorized = granted
                    if let error { self.log("calendar access failed: \(error)") }
                    else { self.log(granted ? "calendar access granted" : "calendar access declined") }
                    if granted { self.refresh() }
                }
            }
        }
    }

    /// Rescans a -10min…+10h window. Small and synchronous — EventKit predicate
    /// queries over hours are milliseconds at this cadence.
    func refresh() {
        guard authorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-10 * 60),
                                                 end: now.addingTimeInterval(10 * 3600),
                                                 calendars: nil)
        var seen: Set<String> = []
        let meetings: [UpcomingMeeting] = store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, let eventID = event.eventIdentifier else { return nil }
            // eventIdentifier is SHARED across occurrences of a recurring series;
            // keying on it alone would drop today's second stand-up entirely.
            let id = "\(eventID)#\(event.startDate.timeIntervalSince1970)"
            guard !seen.contains(id) else { return nil }
            // The link hides in different fields per invite source; search them all.
            let haystack = [event.location, event.notes, event.url?.absoluteString]
                .compactMap { $0 }.joined(separator: "\n")
            guard let link = MeetingLink.detect(in: haystack) else { return nil }
            seen.insert(id)
            return UpcomingMeeting(id: id, title: event.title ?? "meeting",
                                   start: event.startDate, end: event.endDate, link: link)
        }.sorted { $0.start < $1.start }
        let capped = Array(meetings.prefix(8))
        if capped != upcoming { upcoming = capped }
    }

    /// Planner context block. Per-turn (rides outside the cached prefix).
    var promptText: String { Self.promptText(for: upcoming, now: Date()) }

    /// Pure — unit-tested.
    nonisolated static func promptText(for meetings: [UpcomingMeeting], now: Date) -> String {
        guard !meetings.isEmpty else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        var s = "Meetings on the calendar (to join one, emit a join_meeting step with its exact url):"
        for m in meetings {
            let when = m.start <= now ? "started \(fmt.string(from: m.start))" : "at \(fmt.string(from: m.start))"
            s += "\n- “\(m.title)” \(when) — \(m.link.service.label), url: \(m.link.url)"
        }
        return s
    }

    /// The meeting a bare "join my meeting" means: in progress, or starting soon.
    /// A hint ("standup", "zoom") picks by word overlap via the same matcher that
    /// resolves window names. A hint that matches NOTHING returns nil — falling
    /// back to "some other meeting" would join the user into the wrong live call.
    /// Pure — unit-tested.
    nonisolated static func pick(from meetings: [UpcomingMeeting], hint: String, now: Date) -> UpcomingMeeting? {
        let joinable = meetings.filter { now < $0.end && $0.start.timeIntervalSince(now) < 20 * 60 }
        let pool = joinable.isEmpty ? meetings.filter { now < $0.end } : joinable
        let stopwords: Set<String> = ["meeting", "my", "the", "a", "join", "call"]
        let words = hint.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !stopwords.contains($0) }
        guard !words.isEmpty else { return pool.first }
        let labels = pool.map { "\($0.title) \($0.link.service.label) \($0.link.service.rawValue)" }
        guard let idx = ScreenController.bestWindowIndex(labels, query: words.joined(separator: " ")) else {
            return nil
        }
        return pool[idx]
    }

    func nextJoinable(matching hint: String) -> UpcomingMeeting? {
        Self.pick(from: upcoming, hint: hint, now: Date())
    }

    /// One auto-join attempt at a time. A meeting is stamped `fired` only when
    /// the coordinator actually starts the join — a busy Mac gets retried every
    /// tick until the 3-minute window closes, instead of one bad instant burning
    /// the meeting for good.
    private func checkDue() {
        guard autoJoinEnabled, let onMeetingStarting else { return }
        let now = Date()
        for m in upcoming where !fired.contains(m.id) {
            guard m.start.timeIntervalSince(now) < 60, now.timeIntervalSince(m.start) < 3 * 60 else { continue }
            if onMeetingStarting(m) { fired.insert(m.id) }
            return
        }
    }
}
