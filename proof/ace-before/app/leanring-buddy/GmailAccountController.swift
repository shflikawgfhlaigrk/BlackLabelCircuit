#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  GmailAccountController.swift
//  Ace
//
//  Asks the buyer for one Google app password, proves it works against Google
//  before storing it, and keeps it in the login keychain.
//
//  Ace used to send and draft through Apple Mail. A Mac with no Mail account
//  configured could not do either, and the buyer was told to go set up Apple
//  Mail — a second mail client they never asked for. Ace now uses the account
//  they already have.
//
//  The password is verified by the same bundled wrapper that later sends with
//  it, so a password that passes here is a password that works. It is written
//  to the keychain only after Google accepts it.
//

#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import CircuitPortKit

@MainActor
final class GmailAccountController: ObservableObject {
    enum Status: Equatable {
        case idle
        case verifying
        case failed(String)
        case connected(String)
    }

    @Published var addressField: String = ""
    @Published var appPasswordField: String = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var configuredAddress: String?

    private let store: GmailAccountStore
    private let toolURLProvider: () -> URL?
    private let verificationAdmission: StealthModelProcessAdmission
    private var verificationGeneration: UInt64?
    private let googleConnection: any GmailGoogleConnecting
    private var googleTask: Task<GmailAccountCredential, Error>?

    init(
        store: GmailAccountStore = GmailAccountStore(),
        toolURLProvider: @escaping () -> URL? = {
            Bundle.main.resourceURL?
                .appendingPathComponent("tools", isDirectory: true)
                .appendingPathComponent("email-send", isDirectory: false)
        },
        verificationAdmission: StealthModelProcessAdmission = StealthModelProcessAdmission(),
        googleConnection: (any GmailGoogleConnecting)? = nil
    ) {
        self.store = store
        self.toolURLProvider = toolURLProvider
        self.verificationAdmission = verificationAdmission
        self.googleConnection = googleConnection ?? GmailGoogleConnection()
        refresh()
    }

    var needsAppPassword: Bool { configuredAddress == nil }

    func refresh() {
        configuredAddress = store.storedAddress()
        if let configuredAddress {
            status = .connected(configuredAddress)
        }
    }

    /// Validate, prove against Google, then store. Nothing is written to the
    /// keychain until Google has accepted the credential, so a typo cannot be
    /// saved and then fail silently the first time Ace tries to send.
    func save() async {
        guard status != .verifying,
              !StealthVisibilityGate.shared.isActive,
              let generation = verificationAdmission.claimGeneration() else { return }
        verificationGeneration = generation
        defer {
            verificationAdmission.finish(generation: generation)
            if verificationGeneration == generation { verificationGeneration = nil }
        }
        let addressResult = GmailAccountPolicy.normalizedAddress(addressField)
        guard case .success(let address) = addressResult else {
            if case .failure(let problem) = addressResult {
                status = .failed(GmailAccountPolicy.message(for: problem))
            }
            return
        }
        let passwordResult = GmailAccountPolicy
            .normalizedAppPassword(appPasswordField)
        guard case .success(let password) = passwordResult else {
            if case .failure(let problem) = passwordResult {
                status = .failed(GmailAccountPolicy.message(for: problem))
            }
            return
        }

        status = .verifying
        let credential = GmailAccountCredential(
            address: address,
            appPassword: password
        )
        let admission = verificationAdmission
        let verification = await withTaskCancellationHandler {
            await verify(credential, generation: generation)
        } onCancel: {
            admission.cancel(generation: generation)
        }
        // A disconnected attempt may return after a replacement attempt began.
        // Only the current attempt owns the fields and visible setup state.
        guard verificationGeneration == generation else { return }
        guard verificationAdmission.isCurrent(generation: generation),
              !Task.isCancelled,
              !StealthVisibilityGate.shared.isActive else {
            appPasswordField = ""
            status = .idle
            return
        }
        switch verification {
        case .failure(let message):
            status = .failed(message)
        case .success:
            do {
                try store.save(credential)
            } catch {
                status = .failed(
                    "Google accepted the app password, but this Mac's login keychain refused to store it."
                )
                return
            }
            // Clear the entered secret from the view's memory the moment it is
            // no longer needed; the keychain is the only place it lives now.
            appPasswordField = ""
            addressField = ""
            configuredAddress = address
            status = .connected(address)
            NotificationCenter.default.post(name: Notification.Name("AceGmailAccountChanged"), object: nil)
        }
    }

    func cancelVerification() {
        googleTask?.cancel(); googleTask = nil
        googleConnection.cancel()
        verificationAdmission.cancelAll()
        verificationGeneration = nil
        appPasswordField = ""
        addressField = ""
        status = configuredAddress.map(Status.connected) ?? .idle
    }

    func disconnect() {
        googleTask?.cancel(); googleTask = nil
        googleConnection.cancel()
        verificationAdmission.cancelAll()
        verificationGeneration = nil
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        do {
            try store.removeAll()
        } catch {
            status = .failed("This Mac's login keychain refused to remove the app password.")
            return
        }
        configuredAddress = nil
        appPasswordField = ""
        addressField = ""
        status = .idle
        NotificationCenter.default.post(name: Notification.Name("AceGmailAccountChanged"), object: nil)
    }

    private enum Verification {
        case success
        case failure(String)
    }

    func connectWithGoogle() async {
        guard status != .verifying, !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised,
              let generation = verificationAdmission.claimGeneration() else { return }
        verificationGeneration = generation
        status = .verifying
        appPasswordField = ""
        defer {
            verificationAdmission.finish(generation: generation)
            if verificationGeneration == generation {
                verificationGeneration = nil; googleTask = nil
                if status == .verifying { status = configuredAddress.map(Status.connected) ?? .idle }
            }
        }
        let connection = googleConnection
        let task = Task { try await connection.connect() }
        googleTask = task
        do {
            let credential = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard verificationGeneration == generation, verificationAdmission.isCurrent(generation: generation),
                  !Task.isCancelled, !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised else { return }
            let verification = await verify(credential, generation: generation)
            guard verificationGeneration == generation, verificationAdmission.isCurrent(generation: generation),
                  !Task.isCancelled, !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised else { return }
            switch verification {
            case .failure(let message): status = .failed(message)
            case .success:
                try store.save(credential)
                configuredAddress = credential.address
                addressField = ""
                status = .connected(credential.address)
                NotificationCenter.default.post(name: Notification.Name("AceGmailAccountChanged"), object: nil)
            }
        } catch {
            guard verificationGeneration == generation else { return }
            if Task.isCancelled || StealthVisibilityGate.shared.isActive || StealthEntryLatch.shared.isRaised {
                status = configuredAddress.map(Status.connected) ?? .idle
            } else if let error = error as? GmailOAuthError {
                status = .failed(error.localizedDescription)
            } else if error is GmailAccountStore.StoreError {
                status = .failed("Google connected, but this Mac could not save the account in its login keychain. Try connecting again.")
            } else {
                status = .failed("Google connection did not finish. Try Connect with Google again.")
            }
        }
    }

    /// Runs `email-send --verify-stdin`, which authenticates to Gmail and hangs
    /// up without composing or sending anything.
    private func verify(
        _ credential: GmailAccountCredential,
        generation: UInt64
    ) async -> Verification {
        guard let toolURL = toolURLProvider(),
              FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            return .failure("Ace could not find its own mail helper in this build.")
        }
        let payload = Data(
            [
                credential.transportSchema,
                credential.transportSecret,
                credential.address,
                "", "", "",
            ].joined(separator: "\n").utf8
        )

        let admission = verificationAdmission
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let input = Pipe()
                let output = Pipe()
                process.executableURL = toolURL
                process.arguments = ["--verify-stdin"]
                process.environment = ProcessInfo.processInfo.environment.merging(
                    ["ACE_GMAIL_TIMEOUT_SECONDS": "12"]
                ) { _, new in new }
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output
                do {
                    guard try admission.launchAndPublishIfCurrent(
                        generation: generation,
                        launch: {
                            try process.run()
                            return process.processIdentifier
                        },
                        publish: { _ in }
                    ) else {
                        try? input.fileHandleForWriting.close()
                        continuation.resume(returning: .failure("Email setup was cancelled."))
                        return
                    }
                } catch {
                    continuation.resume(
                        returning: .failure(
                            "Ace could not start its mail helper on this Mac."
                        )
                    )
                    return
                }
                var privateInput = payload
                try? input.fileHandleForWriting.write(contentsOf: privateInput)
                privateInput.resetBytes(in: 0..<privateInput.count)
                try? input.fileHandleForWriting.close()
                let text = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                admission.retireProcess(generation: generation)
                if process.terminationStatus == 0,
                   admission.isCurrent(generation: generation),
                   text == "Gmail connected inbox and sending for \(credential.address)" {
                    continuation.resume(returning: .success)
                } else {
                    continuation.resume(
                        returning: .failure(
                            process.terminationStatus == 0
                                ? "Ace's mail helper did not confirm the exact Gmail account."
                                : text.isEmpty
                                ? "Google did not accept the app password."
                                : text
                        )
                    )
                }
            }
        }
    }
}

/// The wrapper stdin schema, shared with the broker's private material without
/// exposing that broker-internal type to the UI layer.
enum GmailRequestMaterialSchema {
    static let value = "ACE-GMAIL-REQUEST-V1"
}
#endif // circuit-convert
