import Foundation

/// Exactly one goal may drive the GUI at a time — two agents typing into the
/// same screen is corruption, not concurrency. The user's live voice session
/// always wins: it takes the lease even when a scheduled goal holds it (the
/// scheduled run sees its lease revoked and stops at its next cancellation
/// check). Background (non-UI) agents never touch this.
@MainActor
final class ScreenLease: ObservableObject {
    static let shared = ScreenLease()

    /// The screen was already held by someone with priority — the run never
    /// started. Thrown (not returned) so a skipped run can't read as finished
    /// to any caller.
    struct Busy: Error {}
    /// The user took the screen mid-run. Distinct from a real failure so the
    /// outcome reads "stepped aside" — never "done", never "error".
    struct Revoked: Error {}

    enum Holder: Equatable, Sendable {
        case voice              // the user's live command session
        case scheduled(String)  // a scheduled procedure run, by goal id
        case remote(String)     // a goal sent by a paired fleet machine
    }

    @Published private(set) var holder: Holder?

    /// Voice preempts; scheduled work only gets a free screen.
    func acquire(_ who: Holder) -> Bool {
        switch (holder, who) {
        case (nil, _):
            holder = who
            return true
        case (.some(.scheduled), .voice), (.some(.remote), .voice):
            // Revocation, not queueing: the automated run polls `revoked(_:)`
            // at its cancellation points and abandons the screen.
            holder = .voice
            return true
        case (.some(.voice), .voice):
            return true      // the live session re-entering itself
        default:
            return false
        }
    }

    func release(_ who: Holder) {
        guard holder == who else { return } // a revoked holder must not free the winner's lease
        holder = nil
    }

    func revoked(_ who: Holder) -> Bool { holder != who }
}
