import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct AceControlActivationReceipt: Equatable, Sendable {
    private(set) var activationCount = 0

    mutating func recordActivation() {
        activationCount += 1
    }

    var accessibilityValue: String {
        "activations=\(activationCount)"
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Low-level control for an immediate UI transition whose business outcome is
/// already rendered by its owning view. Unlike a raw SwiftUI Button, it always
/// exposes proof that the handler received the click, so a swallowed event and
/// a failed downstream action cannot masquerade as the same ghost control.
struct AceTrackedButton<Label: View>: View {
    private let role: ButtonRole?
    private let action: () -> Void
    @ViewBuilder private let label: () -> Label
    @State private var activationReceipt = AceControlActivationReceipt()

    init(
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.role = role
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: role) {
            activationReceipt.recordActivation()
            action()
        } label: {
            label()
        }
        .accessibilityCustomContent(LocalizedStringKey("Activation receipt"), activationReceipt.accessibilityValue)
        .pointerCursor()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AceTrackedButton where Label == Text {
    init(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) {
            Text(title)
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Toggle equivalent of AceTrackedButton. The binding still owns persistence
/// and rollback; this layer proves that the visible control delivered a user
/// transition request to that binding.
struct AceTrackedToggle<Label: View>: View {
    @Binding private var isOn: Bool
    @ViewBuilder private let label: () -> Label
    @State private var activationReceipt = AceControlActivationReceipt()

    init(
        isOn: Binding<Bool>,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isOn = isOn
        self.label = label
    }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isOn },
                set: { value in
                    activationReceipt.recordActivation()
                    isOn = value
                }
            ),
            label: label
        )
        .accessibilityCustomContent(LocalizedStringKey("Activation receipt"), activationReceipt.accessibilityValue)
        .pointerCursor()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AceTrackedToggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            Text(title)
        }
    }
}
#endif // circuit-convert

struct AceActionPresentation: Equatable, Sendable {
    let title: String
    let isEnabled: Bool
    let showsProgress: Bool
    let message: String?
    let recoveryTitle: String?
    let recovery: AceRecoveryRoute?
    let isFailure: Bool

    static func make(
        title: String,
        phase: AceActionPhase,
        blockedReason: String?
    ) -> AceActionPresentation {
        if let blockedReason, !blockedReason.isEmpty {
            return AceActionPresentation(
                title: title,
                isEnabled: false,
                showsProgress: false,
                message: blockedReason,
                recoveryTitle: nil,
                recovery: nil,
                isFailure: true
            )
        }

        switch phase {
        case .idle:
            return AceActionPresentation(
                title: title,
                isEnabled: true,
                showsProgress: false,
                message: nil,
                recoveryTitle: nil,
                recovery: nil,
                isFailure: false
            )
        case .running:
            return AceActionPresentation(
                title: "Working…",
                isEnabled: false,
                showsProgress: true,
                message: nil,
                recoveryTitle: nil,
                recovery: nil,
                isFailure: false
            )
        case let .succeeded(success):
            return AceActionPresentation(
                title: title,
                isEnabled: true,
                showsProgress: false,
                message: success.message,
                recoveryTitle: nil,
                recovery: nil,
                isFailure: false
            )
        case let .failed(failure), let .timedOut(failure):
            return AceActionPresentation(
                title: title,
                isEnabled: true,
                showsProgress: false,
                message: failure.message,
                recoveryTitle: failure.recoveryTitle,
                recovery: failure.recovery,
                isFailure: true
            )
        case .cancelled:
            return AceActionPresentation(
                title: title,
                isEnabled: true,
                showsProgress: false,
                message: "Action cancelled.",
                recoveryTitle: nil,
                recovery: nil,
                isFailure: false
            )
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AceActionButton<Label: View>: View {
    @ObservedObject var actionModel: AceActionModel

    let id: AceActionID
    let timeout: Duration
    let title: String
    var blockedReason: String?
    var showsStatus: Bool
    let operation:
        @MainActor @Sendable () async throws -> AceActionSuccess
    @ViewBuilder let label: (AceActionPresentation) -> Label

    init(
        id: AceActionID,
        actionModel: AceActionModel,
        timeout: Duration,
        title: String,
        blockedReason: String? = nil,
        showsStatus: Bool = true,
        operation:
            @MainActor @escaping @Sendable () async throws
                -> AceActionSuccess,
        @ViewBuilder label:
            @escaping (AceActionPresentation) -> Label
    ) {
        self.id = id
        self.actionModel = actionModel
        self.timeout = timeout
        self.title = title
        self.blockedReason = blockedReason
        self.showsStatus = showsStatus
        self.operation = operation
        self.label = label
    }

    var body: some View {
        let presentation = AceActionPresentation.make(
            title: title,
            phase: actionModel.phase(for: id),
            blockedReason: blockedReason
        )

        VStack(alignment: .leading, spacing: 7) {
            Button {
                Task {
                    await actionModel.execute(
                        id: id,
                        timeout: timeout,
                        operation: operation
                    )
                }
            } label: {
                label(presentation)
            }
            .buttonStyle(.plain)
            .disabled(!presentation.isEnabled)
            .pointerCursor(isEnabled: presentation.isEnabled)
            .accessibilityIdentifier("ace.action.\(id.rawValue)")

            if showsStatus {
                AceActionStatusView(presentation: presentation)
            }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AcePrimaryActionButton: View {
    @ObservedObject var actionModel: AceActionModel

    let id: AceActionID
    let title: String
    var symbol: String?
    var timeout: Duration = .seconds(30)
    var blockedReason: String?
    let operation:
        @MainActor @Sendable () async throws -> AceActionSuccess

    @State private var isHovering = false

    var body: some View {
        AceActionButton(
            id: id,
            actionModel: actionModel,
            timeout: timeout,
            title: title,
            blockedReason: blockedReason,
            operation: operation
        ) { presentation in
            HStack(spacing: 8) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(presentation.title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(
                presentation.isEnabled
                    ? DS.Colors.textOnAccent
                    : DS.Colors.textTertiary
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(
                    presentation.isEnabled
                        ? (
                            isHovering
                                ? DS.Colors.accentHover
                                : DS.Colors.accent
                        )
                        : DS.Colors.surface4
                )
            )
            .overlay {
                if !presentation.isEnabled {
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                }
            }
            .onHover {
                isHovering = presentation.isEnabled && $0
            }
            .animation(
                .easeOut(duration: 0.15),
                value: isHovering
            )
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AcePermissionActionButton: View {
    @ObservedObject var actionModel: AceActionModel

    let id: AceActionID
    let title: String
    let symbol: String
    var timeout: Duration = .seconds(30)
    var blockedReason: String?
    let operation:
        @MainActor @Sendable () async throws -> AceActionSuccess

    var body: some View {
        AceActionButton(
            id: id,
            actionModel: actionModel,
            timeout: timeout,
            title: title,
            blockedReason: blockedReason,
            operation: operation
        ) { presentation in
            HStack(spacing: 7) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(
                presentation.isEnabled
                    ? DS.Colors.textOnAccent
                    : DS.Colors.textTertiary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    presentation.isEnabled
                        ? DS.Colors.accent
                        : DS.Colors.surface4
                )
            )
            .overlay {
                if !presentation.isEnabled {
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                }
            }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AceImmediateButton<Label: View>: View {
    let accessibilityIdentifier: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AceManagedToggle: View {
    @Binding var isOn: Bool
    @ObservedObject var actionModel: AceActionModel

    let id: AceActionID
    let title: String
    var timeout: Duration = .seconds(15)
    var blockedReason: String?
    let persist:
        @MainActor @Sendable (Bool) async throws -> AceActionSuccess

    var body: some View {
        let presentation = AceActionPresentation.make(
            title: title,
            phase: actionModel.phase(for: id),
            blockedReason: blockedReason
        )

        VStack(alignment: .leading, spacing: 7) {
            Toggle(
                title,
                isOn: Binding(
                    get: { isOn },
                    set: { desiredValue in
                        let priorValue = isOn
                        isOn = desiredValue
                        Task {
                            await actionModel.execute(
                                id: id,
                                timeout: timeout
                            ) {
                                try await persist(desiredValue)
                            }
                            switch actionModel.phase(for: id) {
                            case .failed, .timedOut, .cancelled:
                                isOn = priorValue
                            case .idle, .running, .succeeded:
                                break
                            }
                        }
                    }
                )
            )
            .disabled(!presentation.isEnabled)
            .accessibilityIdentifier("ace.toggle.\(id.rawValue)")

            AceActionStatusView(presentation: presentation)
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AceActionStatusView: View {
    let presentation: AceActionPresentation

    var body: some View {
        if let message = presentation.message {
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(
                        presentation.isFailure
                            ? DS.Colors.destructiveText
                            : DS.Colors.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.action.status")

                if let recoveryTitle = presentation.recoveryTitle {
                    Text("Next: \(recoveryTitle)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .accessibilityIdentifier(
                            "ace.action.recovery-instruction"
                        )
                }
            }
        }
    }
}
#endif // circuit-convert
