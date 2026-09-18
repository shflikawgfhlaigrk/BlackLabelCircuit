import Foundation

/// Pure policy for the LAST ghost failure in a user-activated Partner session:
/// Ace listening perfectly and hearing nothing, forever, in silence.
///
/// Observed 2026-08-07 during a live shoot. The receipts tell the whole story:
///
///     09:10:55 PARTNER activated by user
///     09:12:28 PARTNER silent listening window renewed
///     09:13:58 PARTNER silent listening window renewed
///     09:15:28 PARTNER silent listening window renewed
///     09:15:40 PARTNER ended reason=userEnded
///
/// The owner was talking the entire time, across the room from the built-in
/// microphone. Ace KNEW it had heard nothing for four and a half minutes — it
/// renewed the window three times — and said nothing, so "listening perfectly"
/// and "completely broken" looked identical from where he was standing.
///
/// This is the same class as the finish-setup visible-channel bug and the
/// Partner decline bug: a lane whose only channel had no reader. The owner
/// activated Partner to TALK; sustained silence there is a signal, not a state.
nonisolated enum PartnerSilentWindowPolicy {
    /// Two consecutive expiries. One is ordinary — the owner is thinking, or
    /// stepped away mid-sentence. Two in a row inside a session the owner
    /// explicitly opened to speak means the microphone is not reaching them.
    static let silentWindowsBeforeSurfacing = 2

    static let spokenLine =
        "i'm not picking up your voice. move closer to this mac, "
            + "or use your airpods, and say something."

    /// Surfacing is once per unbroken run of silence: repeating it every window
    /// would make Ace nag into an empty room, which is its own ghost.
    /// Any captured utterance resets the run (see `resetAfterCapturedTurn`).
    static func shouldSurfaceDeafness(
        consecutiveSilentWindows: Int,
        alreadySurfacedForThisRun: Bool,
        userActivatedSession: Bool,
        stealthBlocked: Bool
    ) -> Bool {
        // Stealth is deliberately never broken by this: announcing "i can't
        // hear you" out loud is exactly the disclosure Private Mode exists to
        // prevent, and the microphone is closed there anyway.
        guard !stealthBlocked,
              userActivatedSession,
              !alreadySurfacedForThisRun,
              consecutiveSilentWindows >= silentWindowsBeforeSurfacing else {
            return false
        }
        return true
    }

    /// A real captured turn proves the microphone reaches the owner, so the
    /// run — and the once-per-run allowance — both start over.
    static func resetAfterCapturedTurn() -> (
        consecutiveSilentWindows: Int,
        alreadySurfacedForThisRun: Bool
    ) {
        (consecutiveSilentWindows: 0, alreadySurfacedForThisRun: false)
    }
}
