#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation

nonisolated enum GmailBackendHeadlessCommand {
    static let launchFlag = "--ace-gmail-backend"

    static func runForever() -> Never {
        Task { @MainActor in await runRequest() }
        dispatchMain()
    }

    @MainActor private static func runRequest() async -> Never {
        do {
            let data = try FileHandle.standardInput.read(upToCount: 65537) ?? Data()
            guard !data.isEmpty, data.count <= 65536 else { throw GmailBackendError.invalidRequest }
            let request = try JSONDecoder().decode(GmailBackendRequest.self, from: data)
            try request.validate()
            try checkAuthority()
            let store = GmailAccountStore()
            guard let address = store.storedAddress() else { throw GmailBackendError.missingAccount }
            if request.operation == .account {
                write(["status": "configured", "account": address], code: 0)
            }
            guard request.account?.caseInsensitiveCompare(address) == .orderedSame
            else { throw GmailBackendError.accountMismatch }
            guard let credential = try await store.loadUsableCredential(), credential.address == address
            else { throw GmailBackendError.missingAccount }
            try checkPrivacy()
            let session = try GmailIMAPSession(wire: GmailNetworkWire(), address: credential.address,
                                              password: credential.transportSecret, usesOAuth: credential.oauth != nil, beforeCommand: checkPrivacy)
            let response = try GmailBackend(session: session).execute(request)
            write(response, code: 0)
        } catch {
            let message: String
            switch error as? GmailBackendError {
            case .missingAccount: message = "Connect the Gmail account in Ace before using its backend."
            case .accountMismatch: message = "The requested account does not match Ace's connected Gmail account."
            case .mailboxChanged: message = "The mailbox identity or target messages changed. Search again before continuing."
            case .unconfirmedMutation: message = "The label change is unconfirmed. Read the same messages and reconcile their labels before another write."
            case .invalidRequest: message = "The Gmail backend request is invalid."
            case .refused: message = "Gmail refused the backend command. No completion is verified."
            default: message = "The Gmail backend did not return a complete verified result. Check the connection and read current labels before retrying a change."
            }
            write(["status": "failed", "message": message], code: 3)
        }
    }

    private static func checkAuthority() throws {
        guard let guardURL = Bundle.main.resourceURL?.appendingPathComponent("tools/effect-guard.sh")
        else { throw GmailBackendError.refused }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\"; ace_effect_guard_require_approval && ace_effect_guard_recheck", "ace-gmail-boundary", guardURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GmailBackendError.refused }
    }

    private static func checkPrivacy() throws {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BlackLabel")
        for name in ["stealth-entry-request-v1", "stealth-intent-v1", "stealth-active"] {
            let url = support.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                throw GmailBackendError.refused
            }
        }
    }

    private static func write(_ object: [String: Any], code: Int32) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
        exit(code)
    }
}
#endif // circuit-convert
