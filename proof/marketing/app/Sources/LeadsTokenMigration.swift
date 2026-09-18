// Lead-Database token carry-over from the retired Black Label Leads app.
//
// The standalone Leads app stored its Lead Database access token in ITS OWN UserDefaults
// domain (com.blacklabel.leads → ~/Library/Preferences/com.blacklabel.leads.plist), under the
// same key the ported LeadDB code uses. The merged Marketing app runs in its own domain, so the
// carry-over must read the retired app's domain explicitly — UserDefaults.standard can never
// see it. Split out of LeadsMigration so the decision + cross-domain read are provable in the
// standalone suite (Tests/LeadsTokenMigrationTests.swift) without the full app graph.
import Foundation

enum LeadsTokenMigration {
    /// The retired Leads app's defaults domain. Reading it requires the non-sandboxed
    /// Developer-ID build (same constraint as reading its Application Support container).
    static let legacySuiteName = "com.blacklabel.leads"

    /// Import only when the merged app has no token yet and the retired app had one —
    /// never clobber a token the buyer already entered in Marketing.
    static func tokenToImport(current: String?, legacy: String?) -> String? {
        guard current?.isEmpty ?? true, let tok = legacy, !tok.isEmpty else { return nil }
        return tok
    }

    /// The retired Leads app's token from its own defaults domain.
    static func legacyToken(tokenKey: String, suiteName: String = legacySuiteName) -> String? {
        let v = UserDefaults(suiteName: suiteName)?.string(forKey: tokenKey)
        return (v?.isEmpty == false) ? v : nil
    }
}
