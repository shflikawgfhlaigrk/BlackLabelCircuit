// Black Label Marketing — Keychain routing helper.
//
// Founder directive (2026-07-03): kill the recurring macOS password prompts
// ("Black Label Marketing wants to use your confidential information…") for good.
//
// ROOT CAUSE: Keychain items written with SecItemAdd but WITHOUT
// kSecUseDataProtectionKeychain land in the LEGACY (file-based) login keychain, whose
// per-item ACL is bound to the *full* code signature (CDHash) of the binary that created
// it. Local builds are ad-hoc re-signed on every rebuild, so each rebuild is a new
// signature — a stranger to the ACL — and macOS re-prompts. "Always Allow" can never stick.
//
// THE FIX (mirrors `enum SovereignKeychain` in ~/BlackLabelSovereign): route EVERY SecItem
// call through this helper so items land in the DATA-PROTECTION keychain, whose access is
// keyed to the app's code-sign IDENTIFIER (the bundle id — stable across ad-hoc re-signs),
// not the CDHash. A signed build (ad-hoc /Applications copy OR Developer-ID/notarized) keeps
// its keychain access across rebuilds and never prompts again.
//
//  (a) targets the data-protection keychain (kSecUseDataProtectionKeychain = true);
//  (b) on interactive/allowed READ, migrates any readable item found only in the legacy keychain
//      forward into DP. Silent reads do NOT attempt legacy secret reads because macOS can still
//      block inside SecItemCopyMatching for ACL-bound legacy items; those paths use exists() to
//      report "saved but unreadable" without hanging;
//  (c) falls back to the legacy keychain when the data-protection add is unavailable for this
//      local/ad-hoc signature. So unsigned/headless paths keep working with no regression, and
//      nothing about the shipped behavior changes for them.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif

/// One boundary decides whether a Keychain recovery is even eligible to run.
/// Passive callers pass `false`, so their file miss returns without executing
/// the recovery closure (and therefore without touching Security.framework).
enum MarketingCredentialReadPolicy {
    static func resolve(
        fileData: Data?,
        allowAuthenticationUI: Bool,
        recoverLegacy: () -> Data?
    ) -> Data? {
        if let fileData { return fileData }
        guard allowAuthenticationUI else { return nil }
        return recoverLegacy()
    }
}

/// Credential mutations are permanently file-only. The legacy closure exists
/// solely as an injectable canary for regression tests: it is intentionally
/// never executed, even when the private-file operation fails.
enum MarketingCredentialMutationPolicy {
    static func store(
        fileMutation: () -> Bool,
        legacyMutation: () -> Void = {}
    ) -> Bool {
        _ = legacyMutation
        return fileMutation()
    }

    static func delete(
        fileMutation: () -> Bool,
        legacyMutation: () -> Void = {}
    ) -> Bool {
        _ = legacyMutation
        return fileMutation()
    }
}

/// All real-Keychain traffic in Marketing routes through here. `base` is the item's identity
/// dictionary (class + service + account); this helper adds the data-protection flag, the value,
/// and the accessibility class.
enum MarketingKeychain {
    /// Overwrite-style write: clears any prior item in BOTH keychains (so a stale legacy copy
    /// can't shadow the new one), then adds to the data-protection keychain, legacy on fallback.
    /// `accessible` preserves each store's original protection class (default: device-only).
    /// Service+account identity for the file store. Nil when the caller's
    /// dictionary is not a normal generic-password item.
    private static func fileIdentity(
        _ base: [String: Any]
    ) -> (service: String, account: String)? {
        guard let service = base[kSecAttrService as String] as? String,
              let account = base[kSecAttrAccount as String] as? String,
              !service.isEmpty, !account.isEmpty else { return nil }
        return (service, account)
    }

    /// FOUNDER DIRECTIVE 2026-08-07 — "put them somewhere else."
    ///
    /// Every write now lands in `MarketingSecretFile` (0700 dir / 0600 files),
    /// never the Keychain. The Keychain is the ONLY thing in this app that can
    /// put a password dialog on screen; correct data-protection routing made
    /// prompts rare, and removing the Keychain as the store makes them
    /// impossible. Legacy rows are left untouched — deleting them would destroy
    /// credentials — and are read once, forward, by `copy()`.
    @discardableResult
    static func set(_ base: [String: Any], data: Data,
                    accessible _: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) -> Bool {
        guard let identity = fileIdentity(base) else { return false }
        let stored = MarketingCredentialMutationPolicy.store {
            MarketingSecretFile.set(
                service: identity.service,
                account: identity.account,
                data: data
            )
        }
        if stored {
            // The file is authoritative. Do not touch the legacy row here:
            // deleting an ACL-bound row can itself summon SecurityAgent.
            // The marker is cleared so no later recovery can shadow this value.
            clearLegacyReadMarker(base)
        }
        return stored
    }

    /// Metadata-only presence check. This never asks for secret bytes, and it never probes stale
    /// legacy items unless a build of THIS APP wrote the legacy fallback marker. Old legacy
    /// ACL rows from anything else can block even metadata reads, so those stay untouched and
    /// UI/status paths treat them as needing re-entry.
    ///
    /// DOD-7.4: the marker match is deliberately per-BUNDLE, not per-binary. The old exact-build
    /// marker (bundle|mtime|size) meant every update orphaned every legacy credential: build 71
    /// refused rows build 70 wrote, all three social tokens reported unreadable, and the buyer
    /// had to reconnect everything after every update. A row this app wrote under a previous
    /// build is legitimate user data and stays visible; the read paths below migrate it forward.
    static func exists(_ base: [String: Any]) -> Bool {
        if let identity = fileIdentity(base),
           MarketingSecretFile.exists(
            service: identity.service,
            account: identity.account
           ) {
            return true
        }
        // Presence UI is passive too. The marker was written only after this
        // app successfully created/read the legacy row, and avoids a metadata
        // query whose legacy ACL behavior varies across macOS releases.
        return legacyReadMarkerWrittenByThisApp(base)
    }

    /// Read, preferring the data-protection keychain. A readable hit found only in the legacy
    /// keychain is copied forward when authentication UI is allowed. Silent/background reads return
    /// nil after the DP miss instead of touching legacy secret bytes, because that legacy ACL path
    /// can block despite kSecUseAuthenticationUIFail.
    static func copy(_ base: [String: Any],
                     accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                     allowAuthenticationUI: Bool = false) -> Data? {
        let fileData = fileIdentity(base).flatMap {
            MarketingSecretFile.copy(service: $0.service, account: $0.account)
        }
        return MarketingCredentialReadPolicy.resolve(
            fileData: fileData,
            allowAuthenticationUI: allowAuthenticationUI
        ) {
            // Only an explicit foreground recovery reaches this closure.
            // Prefer a data-protection row, then the legacy login Keychain.
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var dataProtectionQuery = query
            dataProtectionQuery[kSecUseDataProtectionKeychain as String] = true
            var output: AnyObject?
            if SecItemCopyMatching(dataProtectionQuery as CFDictionary, &output) == errSecSuccess,
               let data = output as? Data {
                adoptIntoFileStore(base, data: data)
                return data
            }

            output = nil
            guard legacyReadMarkerWrittenByThisApp(base),
                  SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
                  let data = output as? Data else { return nil }
            adoptIntoFileStore(base, data: data)
            return data
        }
    }

    /// Human-triggered reconnect path for saved legacy items. This may show the macOS Keychain
    /// access prompt once; when granted, the item is copied into the stable data-protection
    /// keychain and future connector smokes can read it silently.
    static func migrate(_ base: [String: Any],
                        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) -> Bool {
        guard copy(base, accessible: accessible, allowAuthenticationUI: true) != nil else { return false }
        return copy(base, accessible: accessible, allowAuthenticationUI: false) != nil
    }

    /// Delete from both keychains (data-protection + legacy). Neither delete ever prompts.
    /// Copies a credential that was read out of the Keychain into the file
    /// store, so that item can never require the Keychain — and therefore can
    /// never prompt — again. Best effort by design: a failure here must not
    /// break a read that already succeeded.
    private static func adoptIntoFileStore(_ base: [String: Any], data: Data) {
        guard let identity = fileIdentity(base) else { return }
        if MarketingSecretFile.set(
            service: identity.service,
            account: identity.account,
            data: data
        ) {
            clearLegacyReadMarker(base)
        }
    }

    @discardableResult
    static func delete(_ base: [String: Any]) -> Bool {
        guard let identity = fileIdentity(base) else { return false }
        let deleted = MarketingCredentialMutationPolicy.delete {
            MarketingSecretFile.delete(
                service: identity.service,
                account: identity.account
            )
        }
        // Legacy rows are deliberately retained. A normal sign-out, expiry, or
        // credential rotation must never ask macOS to authorize their deletion.
        // Clearing the marker makes them unreachable until an explicit recovery.
        clearLegacyReadMarker(base)
        return deleted
    }

    private static func clearLegacyReadMarker(_ base: [String: Any]) {
        guard let key = legacyReadMarkerKey(base) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// True when SOME build of this app recorded the legacy fallback for this item. The marker's
    /// build components (mtime|size) are provenance, not a gate: comparing them exactly is what
    /// orphaned every credential across updates (DOD-7.4). Bundle identity is the boundary that
    /// matters — rows never written by this app are never probed.
    private static func legacyReadMarkerWrittenByThisApp(_ base: [String: Any]) -> Bool {
        guard let key = legacyReadMarkerKey(base),
              let marker = UserDefaults.standard.string(forKey: key) else { return false }
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        return marker == currentBuildMarker() || marker.hasPrefix(bundleID + "|")
    }

    private static func legacyReadMarkerKey(_ base: [String: Any]) -> String? {
        guard let service = base[kSecAttrService as String] as? String,
              let account = base[kSecAttrAccount as String] as? String,
              !service.isEmpty, !account.isEmpty else { return nil }
        return "blm.keychain.legacy-readable.\(service).\(account)"
    }

    private static func currentBuildMarker() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let values = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(bundleID)|\(Int(modified))|\(size)"
    }
}
