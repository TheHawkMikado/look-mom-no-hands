import Foundation
import AppKit

/// Keeps a live picture of everything open (apps → windows → browser tabs),
/// refreshed on a timer so the assistant "knows" the environment even when it
/// isn't listening. The enumeration is synchronous AX work that can stall on a
/// hung app, so it runs off the main actor (a cancellable task-group child) and
/// only the finished snapshot is published back on main.
@MainActor
final class EnvironmentTracker: ObservableObject {
    @Published private(set) var snapshot = EnvSnapshot()
    @Published private(set) var lastRefresh: Date?

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshing = false
    private let interval: TimeInterval

    // Needs Accessibility to read other apps' windows; without it the poll is a
    // no-op rather than an error (the app still works, just without awareness).
    init(interval: TimeInterval = 5) { self.interval = interval }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; refreshTask?.cancel(); refreshTask = nil }

    /// Rebuilds the snapshot. Skips if a refresh is already in flight (a slow AX
    /// walk must not stack up behind the timer) or Accessibility isn't granted.
    /// Per-app AX messaging timeouts (see `environmentSnapshot`) bound a wedged app.
    func refresh() {
        guard !refreshing, ScreenController.isTrusted else { return }
        refreshing = true
        refreshTask = Task { [weak self] in
            defer { self?.refreshing = false }
            let snap = try? await withThrowingTaskGroup(of: EnvSnapshot.self) { group in
                group.addTask { try ScreenController.environmentSnapshot() }
                return try await group.next() ?? EnvSnapshot()
            }
            guard let self else { return }
            self.lastRefresh = Date()
            if let snap, snap != self.snapshot { self.snapshot = snap }
        }
    }
}
