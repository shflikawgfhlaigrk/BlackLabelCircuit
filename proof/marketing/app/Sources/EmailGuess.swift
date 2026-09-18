// Black Label Marketing — the in-house pattern-GUESS email lane (honest, separate, never fake-green).
//
// The gap this closes: a buyer with a lead that has a name + company domain but NO email wants a
// starting point. The BYO-provider path (EnrichmentProvider.swift) needs a real Hunter/Apollo key.
// WITHOUT a provider, the only honest thing we can offer is a PATTERN GUESS (first.last@domain, …)
// derived from the name + domain — and it must be labelled, everywhere, as an UNVERIFIED GUESS.
//
// The single invariant this module enforces (and its test locks): a guessed address can NEVER render
// in the same visual state as a real, confirmed email. It lives in its own field (`Lead.guessedEmail`,
// separate from `Lead.email`), it always carries the word "unverified", and its colour role is
// `.guess` — a role that is, by construction, never `.confirmed` and never the success/green tone.
// A confirmed email always wins the display; a guess only ever shows when there is no real email.
//
// Pure Foundation (no SwiftUI, no AppModel) so the honesty logic is unit-tested with zero UI.
import Foundation

/// The colour role the UI maps to a concrete tone. A guess is NEVER `.confirmed` — the View layer
/// maps `.confirmed` to the success/green tone and `.guess` to a neutral/muted tone. Keeping this an
/// enum (not a Color) is what lets the honesty test assert "a guess is never green" without SwiftUI.
enum EmailColorRole: String, Equatable {
    case neutral      // no email at all
    case confirmed    // a real address the buyer typed / imported / a keyed provider returned
    case guess        // an in-house pattern guess — unverified, muted, never the confirmed tone
}

/// The resolved e-mail display for a lead. Exactly one case; a confirmed email always shadows a guess.
enum LeadEmailDisplay: Equatable {
    case none
    case confirmed(String)
    case guessed(address: String, pattern: String)

    /// Resolve from a lead's stored fields. A non-empty real `email` ALWAYS wins — the guess is only
    /// surfaced when there is no confirmed address, so a guess can never occupy the confirmed slot.
    static func resolve(email: String, guessedEmail: String, guessedPattern: String) -> LeadEmailDisplay {
        let real = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !real.isEmpty { return .confirmed(real) }
        let g = guessedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { return .guessed(address: g, pattern: guessedPattern.trimmingCharacters(in: .whitespaces)) }
        return .none
    }

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isGuess: Bool { if case .guessed = self { return true }; return false }

    /// The address string, if any (real OR guessed — the caller distinguishes via `isGuess`).
    var address: String? {
        switch self {
        case .none: return nil
        case .confirmed(let a): return a
        case .guessed(let a, _): return a
        }
    }

    /// The badge text shown beside the address. A guess ALWAYS carries the honest, non-green words;
    /// a confirmed address carries no badge (it is simply the email). `nil` = no badge.
    var badge: String? {
        switch self {
        case .none, .confirmed: return nil
        case .guessed(_, let pattern):
            let p = pattern.trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? "Guessed · unverified" : "Guessed · unverified · \(p)"
        }
    }

    /// The SF Symbol the row uses. A guess uses a question-mark glyph — deliberately NOT the
    /// `checkmark.seal`/envelope-confirmed iconography a real address would earn.
    var icon: String {
        switch self {
        case .none: return "envelope.badge.person.crop"
        case .confirmed: return "envelope.fill"
        case .guessed: return "questionmark.circle"
        }
    }

    var colorRole: EmailColorRole {
        switch self {
        case .none: return .neutral
        case .confirmed: return .confirmed
        case .guessed: return .guess
        }
    }
}

/// Generates the in-house pattern guess for a lead. Pure wrapper over `EmailEngine.candidates` that
/// returns ONLY the top pattern pick (or nil when there isn't enough to guess from). Never fabricates
/// beyond a deterministic name+domain permutation, and never touches the network.
enum EmailGuessEngine {
    struct Guess: Equatable { var address: String; var pattern: String }

    /// The top pattern candidate for `name` @ `domain`, or nil if a guess can't be formed (no domain,
    /// or no usable first name). A single name with a domain still yields `first@domain`.
    static func topGuess(name: String, domain: String) -> Guess? {
        guard let top = EmailEngine.candidates(name: name, domain: domain).first else { return nil }
        return Guess(address: top.address, pattern: top.pattern)
    }

    /// True when a lead is eligible for a guess: no confirmed email yet, but has a name + domain.
    static func canGuess(email: String, name: String, domain: String) -> Bool {
        email.trimmingCharacters(in: .whitespaces).isEmpty && topGuess(name: name, domain: domain) != nil
    }
}
