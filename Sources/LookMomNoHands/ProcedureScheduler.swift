import Foundation

/// Fires scheduled procedures. A 30-second poll, not per-procedure timers: the
/// Mac sleeps, the clock jumps, schedules get edited — recomputing "is anything
/// due right now" each tick survives all of that where armed timers silently
/// don't. The isDue grace window (30 min) covers the wake-from-sleep case.
///
/// The Mac must be awake for a slot to fire — registering pmset wakes needs
/// admin rights, which an agent must not self-grant. The Procedures tab says so
/// next to the schedule editor.
@MainActor
final class ProcedureScheduler {
    private let procedures: ProcedureStore
    private weak var coordinator: AppCoordinator?
    private var timer: Timer?

    init(procedures: ProcedureStore, coordinator: AppCoordinator) {
        self.procedures = procedures
        self.coordinator = coordinator
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5   // let the OS coalesce; a schedule isn't a metronome
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let coordinator else { return }
        let now = Date()
        for p in procedures.procedures {
            guard let schedule = p.schedule, schedule.isDue(now: now, lastFired: p.lastFiredAt) else { continue }
            procedures.markFired(p.id, at: now)
            coordinator.runScheduledProcedure(p)
        }
    }
}
