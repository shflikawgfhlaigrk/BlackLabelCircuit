#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  DesktopActionHeadlessCommand.swift
//  Ace
//
//  Single-request stdio entry point used by the bundled desktop-action tool.
//

import Foundation

nonisolated enum DesktopActionHeadlessCommand {
    static let launchFlag = "--ace-desktop-action"
    private static let maximumRequestBytes = 65_536

    static func runForever() -> Never {
        guard ProcessInfo.processInfo.environment["ACE_BACKGROUND_EXECUTION_MODE"] != "backend" else {
            writeFailure("background work requires a backend operation; desktop control was not started", status: 6)
        }
        let input: Data
        do {
            input = try FileHandle.standardInput.read(
                upToCount: maximumRequestBytes + 1
            ) ?? Data()
        } catch {
            writeFailure("the desktop request could not be read", status: 2)
        }
        guard !input.isEmpty, input.count <= maximumRequestBytes,
              let request = try? JSONDecoder().decode(
                DesktopActionRequest.self,
                from: input
              ) else {
            writeFailure("the desktop request is invalid", status: 2)
        }

        guard let authority = NativeHeadlessEffectAuthority.acquire(),
              StealthEntryLatch.shared.requireExternalAdmission({ authority.isValid() }) else {
            writeFailure("no active owner request admitted this desktop action", status: 6)
        }
        Task { @MainActor in
            let receipt = await DesktopActionExecutor(
                backend: DesktopActionSystemBackend(isAllowed: { authority.isValid() }),
                isAllowed: { authority.isValid() }
            ).execute(request)
            write(receipt, status: receipt.status == .verified ? 0 : 3)
        }
        dispatchMain()
    }

    private static func writeFailure(
        _ reason: String,
        status: Int32
    ) -> Never {
        write(
            DesktopActionReceipt(
                status: .failed,
                observedApplication: nil,
                observedRole: nil,
                observedValueDigest: nil,
                reason: reason
            ),
            status: status
        )
    }

    private static func write(
        _ receipt: DesktopActionReceipt,
        status: Int32
    ) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(receipt) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(status)
    }
}
#endif // circuit-convert
