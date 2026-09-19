//
//  GmailAccount.swift
//  Ace
//
//  The buyer's own Gmail sending identity. Ace no longer drives Apple Mail to
//  send or draft: Apple Mail required a configured local account, and on a Mac
//  where Mail was never set up every email request dead-ended at "connect Apple
//  Mail". The buyer now hands Ace one Google app password, which Ace stores in
//  the login keychain and uses to talk to Google's own SMTP and IMAP servers.
//
//  The password is a credential, so it lives in exactly one place. It is never
//  written to UserDefaults, a receipt, a log line, a process argument, or a
//  file on disk. The bundled wrappers receive it on a private stdin pipe that
//  is closed and zeroed after one use, the same shape the Messages wrapper
//  already uses for private recipient material.
//

import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif

/// Pure validation. No I/O, so the walkthrough, the broker and the tests can
/// all agree on what a usable Gmail identity looks like before anything is
/// stored or sent.
enum GmailAccountPolicy {
    static let smtpHost = "smtp.gmail.com"
    static let smtpPort = 465
    static let imapHost = "imap.gmail.com"
    /// Google's own app-password page. Shown to the buyer verbatim; Ace never
    /// asks for the Google account password itself, only a generated app
    /// password, which the buyer can revoke without touching their account.
    static let appPasswordURL = "https://myaccount.google.com/apppasswords"
    /// Google will not issue an app password until 2-Step Verification is on:
    /// without it the app-password page tells the buyer the setting is not
    /// available, with no way forward. Ace links this first so that page is
    /// never a dead end.
    static let twoStepVerificationURL =
        "https://myaccount.google.com/signinoptions/twosv"
    /// Shown when Google will not offer app passwords at all. Work and school
    /// accounts can have them disabled by an administrator, and accounts on
    /// Advanced Protection cannot use them.
    static let appPasswordUnavailableHelp =
        "If Google says app passwords are not available, turn on 2-Step Verification first. On a work or school account an administrator can switch them off entirely, and accounts using Advanced Protection cannot use them at all — in that case use a personal Gmail address here instead."

    enum AddressProblem: Error, Equatable, Sendable {
        case empty
        case malformed
    }

    enum PasswordProblem: Error, Equatable, Sendable {
        case empty
        case tooShort
        case tooLong
        case containsControlCharacters
    }

    /// Apple Mail hands back "Name <addr@host>"; buyers paste the same shape.
    /// Accept it, and accept any domain — Google Workspace accounts on custom
    /// domains send through the same SMTP host as gmail.com.
    static func normalizedAddress(_ raw: String) -> Result<String, AddressProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let candidate: String
        if let open = trimmed.range(of: "<", options: .backwards),
           let close = trimmed.range(of: ">", options: .backwards),
           open.upperBound <= close.lowerBound {
            candidate = String(trimmed[open.upperBound..<close.lowerBound])
        } else {
            candidate = trimmed
        }
        let address = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard address.range(
            of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+$"#,
            options: .regularExpression
        ) != nil else {
            return .failure(.malformed)
        }
        return .success(address)
    }

    /// Google displays an app password as four groups of four ("abcd efgh ijkl
    /// mnop"). Buyers paste it with the spaces, and SMTP rejects the spaces, so
    /// strip every whitespace character rather than telling the buyer they
    /// typed it wrong.
    static func normalizedAppPassword(
        _ raw: String
    ) -> Result<String, PasswordProblem> {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        guard !stripped.isEmpty else { return .failure(.empty) }
        guard !stripped.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return .failure(.containsControlCharacters)
        }
        // A Google app password is 16 characters. Accept a little either side
        // rather than hard-failing a format Google may change, but refuse the
        // obviously-wrong cases (an empty paste, or the whole account password
        // page pasted in).
        guard stripped.count >= 8 else { return .failure(.tooShort) }
        guard stripped.count <= 128 else { return .failure(.tooLong) }
        return .success(stripped)
    }

    /// True for the exact 16-letter shape Google issues today. Used only to
    /// phrase the hint, never to reject.
    static func looksLikeGoogleAppPassword(_ normalized: String) -> Bool {
        normalized.count == 16
            && normalized.allSatisfy { $0.isLetter && $0.isASCII }
    }

    static func message(for problem: AddressProblem) -> String {
        switch problem {
        case .empty:
            return "Enter the Gmail address Ace should send from."
        case .malformed:
            return "That does not look like an email address."
        }
    }

    static func message(for problem: PasswordProblem) -> String {
        switch problem {
        case .empty:
            return "Paste the 16-character app password from Google."
        case .tooShort:
            return "That is shorter than a Google app password. Generate one at \(appPasswordURL) — it is not your Google account password."
        case .tooLong:
            return "That is longer than a Google app password."
        case .containsControlCharacters:
            return "That contains characters an app password cannot hold."
        }
    }
}

/// One buyer Gmail identity: the address is ordinary data, the app password is
/// a credential and is only ever read back out for a single send.
struct GmailAccountCredential: Equatable, Sendable {
    let address: String
    let appPassword: String
    var oauth: GmailOAuthCredential? = nil

    var transportSecret: String { oauth?.accessToken ?? appPassword }
    var transportSchema: String { oauth == nil ? "ACE-GMAIL-REQUEST-V1" : "ACE-GMAIL-OAUTH-V1" }
}

struct GmailOAuthCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

protocol GmailKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemGmailKeychainAccess: GmailKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Login-keychain storage for the buyer's Gmail app password.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps it off iCloud Keychain
/// and off any other Mac: an app password is bound to this install's use of it,
/// and a buyer who revokes it in Google should not find it resurrected on a
/// second machine.
struct GmailAccountStore {
    static let service = "com.blacklabel.assistant.gmail-smtp"

    enum StoreError: Error, Equatable {
        case keychain(OSStatus)
        case malformedStoredItem
    }

    private let service: String
    private let keychain: any GmailKeychainAccess

    init(
        service: String = GmailAccountStore.service,
        keychain: (any GmailKeychainAccess)? = nil
    ) {
        self.service = service
        self.keychain = keychain ?? SystemGmailKeychainAccess()
    }

    /// The address only. Cheap enough for readiness checks and UI, and it never
    /// unseals the password.
    func storedAddress() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        query[kSecReturnData as String] = false
        let (status, item) = keychain.copyMatching(query)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              !account.isEmpty else {
            return nil
        }
        return account
    }

    var isConfigured: Bool { storedAddress() != nil }

    /// Reads the full credential. Callers must hand the password straight to
    /// one send and drop it; nothing else may retain it.
    func loadCredential() throws -> GmailAccountCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let (status, item) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let attributes = item as? [String: Any],
              let address = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              !address.isEmpty, !password.isEmpty else {
            throw StoreError.malformedStoredItem
        }
        if password.hasPrefix("ACE-GMAIL-OAUTH-V1\n") {
            guard let encoded = password.dropFirst("ACE-GMAIL-OAUTH-V1\n".count).data(using: .utf8),
                  let oauth = try? JSONDecoder().decode(GmailOAuthCredential.self, from: encoded),
                  !oauth.accessToken.isEmpty, !oauth.refreshToken.isEmpty else {
                throw StoreError.malformedStoredItem
            }
            return GmailAccountCredential(address: address, appPassword: "", oauth: oauth)
        }
        return GmailAccountCredential(address: address, appPassword: password)
    }

    /// Replaces any previously stored identity: Ace sends as exactly one
    /// address, so a second save is a change of identity, not an addition.
    func save(_ credential: GmailAccountCredential) throws {
        let secret: Data
        if let oauth = credential.oauth {
            secret = Data("ACE-GMAIL-OAUTH-V1\n".utf8) + (try JSONEncoder().encode(oauth))
        } else { secret = Data(credential.appPassword.utf8) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccount as String: credential.address,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "Ace — Gmail account",
            kSecAttrDescription as String:
                "Lets Ace send and draft mail as \(credential.address).",
        ]
        // Replacing a credential must be atomic. Deleting first loses the
        // working account if a locked keychain rejects the subsequent write.
        var status = keychain.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = keychain.add(query.merging(attributes) { _, new in new })
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Buyer-facing disconnect. After this Ace cannot send until a new app
    /// password is provided, which is the point.
    @discardableResult
    func removeAll() throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let status = keychain.delete(query)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw StoreError.keychain(status)
    }
}

/// What Ace should do next about email, given what is stored. Mirrors the shape
/// the Apple Mail path used so the panel keeps one decision site.
enum GmailAccountReadiness: Equatable, Sendable {
    case needsAppPassword
    case ready(String)

    static func evaluate(storedAddress: String?) -> GmailAccountReadiness {
        guard let storedAddress, !storedAddress.isEmpty else {
            return .needsAppPassword
        }
        return .ready(storedAddress)
    }
}
