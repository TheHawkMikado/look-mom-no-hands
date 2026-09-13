import Foundation
import AppKit
import CoreGraphics
import Combine

/// When the bot may open its mouth on its own (SPEC.md §5.4 "by voice at a
/// good moment", Phase 6 "DND and calendar-aware timing"). Three switches
/// and a window: quiet hours (default 22:00–07:00), never during a meeting
/// session or a recording, and never while the screen is locked. The
/// follow-up poller asks `goodMomentToSpeak` before speaking a prompt; a
/// "no" only delays the question — the web keeps it open.
@MainActor
final class QuietHours: ObservableObject {
    private static let startKey = "quietHoursStart"
    private static let endKey = "quietHoursEnd"
    private static let meetingsKey = "quietDuringMeetings"
    private static let lockedKey = "quietWhileLocked"

    /// Minutes after midnight. 22:00 → 1320, 07:00 → 420.
    @Published var startMinute: Int { didSet { defaults.set(startMinute, forKey: Self.startKey) } }
    @Published var endMinute: Int { didSet { defaults.set(endMinute, forKey: Self.endKey) } }
    @Published var muteDuringMeetings: Bool { didSet { defaults.set(muteDuringMeetings, forKey: Self.meetingsKey) } }
    @Published var muteWhileLocked: Bool { didSet { defaults.set(muteWhileLocked, forKey: Self.lockedKey) } }
    /// Tracked from the lock/unlock notifications after an initial read of the
    /// session dictionary; the poller reads this instead of asking CG each time.
    @Published private(set) var screenLocked = false

    private let defaults: UserDefaults
    private var observers: [Any] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startMinute = defaults.object(forKey: Self.startKey) != nil ? defaults.integer(forKey: Self.startKey) : 22 * 60
        endMinute = defaults.object(forKey: Self.endKey) != nil ? defaults.integer(forKey: Self.endKey) : 7 * 60
        muteDuringMeetings = defaults.object(forKey: Self.meetingsKey) != nil ? defaults.bool(forKey: Self.meetingsKey) : true
        muteWhileLocked = defaults.object(forKey: Self.lockedKey) != nil ? defaults.bool(forKey: Self.lockedKey) : true
    }

    /// Starts tracking the lock screen. Separate from init so tests never
    /// register distributed-notification observers.
    func start() {
        screenLocked = Self.currentlyLocked()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = false }
        })
        // Sleep/wake bracket a lock too; re-read on wake in case the unlock
        // notification was missed while asleep.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = Self.currentlyLocked() }
        })
    }

    /// The whole gate. `idle` = the coordinator is in standby (not mid-command,
    /// not thinking, not clarifying); `inMeeting` = a live meeting session or
    /// a recorded call; `recording` = a dictation/note is being captured.
    func goodMomentToSpeak(idle: Bool, inMeeting: Bool, recording: Bool, now: Date = Date()) -> Bool {
        guard idle, !recording else { return false }
        if muteDuringMeetings, inMeeting { return false }
        if muteWhileLocked, screenLocked { return false }
        return !isQuietNow(now)
    }

    func isQuietNow(_ now: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return Self.isQuiet(minuteOfDay: (c.hour ?? 0) * 60 + (c.minute ?? 0), start: startMinute, end: endMinute)
    }

    /// Why the moment is bad, for the log. Nil when it's fine.
    func reasonNotToSpeak(idle: Bool, inMeeting: Bool, recording: Bool, now: Date = Date()) -> String? {
        if !idle { return "not idle" }
        if recording { return "recording" }
        if muteDuringMeetings, inMeeting { return "in a meeting" }
        if muteWhileLocked, screenLocked { return "screen locked" }
        if isQuietNow(now) { return "quiet hours" }
        return nil
    }

    // MARK: - Pure (tests)

    /// Inside the window? A window that crosses midnight (22:00–07:00) wraps;
    /// start == end means "never quiet". The end minute itself is outside.
    nonisolated static func isQuiet(minuteOfDay m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }

    /// "22:00" → 1320; nil for anything else ("25:00", "9", "").
    nonisolated static func minute(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    nonisolated static func label(minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// `CGSessionCopyCurrentDictionary`'s lock flag. False when the dictionary
    /// is unavailable (no window server, e.g. under tests).
    nonisolated static func currentlyLocked() -> Bool {
        guard let cf = CGSessionCopyCurrentDictionary() else { return false }
        let dict = cf as NSDictionary
        if let flag = dict["CGSSessionScreenIsLocked"] as? Bool { return flag }
        if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
        return false
    }
}
