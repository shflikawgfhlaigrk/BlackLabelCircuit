#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

struct PartnerModePanel: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var actionModel = AceActionModel()

    @State private var selectedVoice: PartnerVoiceProfile = .rowan
    @State private var resetIsArmed = false
    @AppStorage("AcePartnerComposerDraft.v1")
    private var composerDraft = ""
    @State private var attachmentImporterIsPresented = false

    private var controller: PartnerModeController? {
        companionManager.partnerModeController
    }

    private var phase: PartnerSessionPhase {
        companionManager.partnerSessionPhase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PARTNER MODE")
                        .font(
                            .system(
                                size: 10,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundColor(
                            companionManager.partnerModeIsActive
                                ? DS.Colors.agentGold
                                : DS.Colors.textSecondary
                        )
                    Text(
                        companionManager.partnerModeIsActive
                            ? "Ace is thinking with you."
                            : "Start a continuous conversation with Ace."
                    )
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(phaseLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(phaseColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(phaseColor.opacity(0.12))
                    )
                    .accessibilityLabel(
                        "Partner status: \(phaseLabel)"
                    )
                    .accessibilityIdentifier("ace.partner.status")
            }

            AceTrackedToggle(
                isOn: Binding(
                    get: {
                        companionManager.partnerModeIsActive
                    },
                    set: {
                        companionManager
                            .setPartnerModeEnabled($0)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ace, be my partner")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(
                        companionManager.partnerModeIsActive
                            ? "Open conversation is active"
                            : "User activated only"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(DS.Colors.agentGold)
            .accessibilityHint(
                "Starts or ends the private Partner conversation"
            )
            .accessibilityIdentifier("ace.partner.toggle")

            partnerComposer

            SyllabusCalendarPanel(
                companionManager: companionManager,
                workflow: companionManager.syllabusCalendarWorkflow
            )

            if companionManager.partnerModeIsActive {
                activeSessionControls
            } else {
                if !companionManager.isOnDeviceDictationReady {
                    Text("On-device dictation is unavailable for this language. Type below to chat and hear replies; the microphone stays muted.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                identityAndVoiceControls
            }

            if let receipt = controller?.visibleMemoryReceipt {
                memoryReceipt(receipt)
            }

            if let error = controller?.lastErrorDescription,
               !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Partner error: \(error)")
                    .accessibilityIdentifier("ace.partner.error")
            }
        }
        .padding(12)
        .background(AceGlassSurface(cornerRadius: DS.CornerRadius.large,
            accent: companionManager.partnerModeIsActive ? DS.Colors.agentGold : DS.Colors.borderSubtle))
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.large,
                style: .continuous
            )
            .stroke(
                companionManager.partnerModeIsActive
                    ? DS.Colors.agentGold.opacity(0.42)
                    : DS.Colors.borderSubtle,
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
        )
        .onAppear {
            companionManager.ensurePartnerProfileReady()
            loadIdentityPreferences()
        }
        .onChange(of: controller?.profile.updatedAt) { _ in
            loadIdentityPreferences()
        }
        .fileImporter(
            isPresented: $attachmentImporterIsPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                companionManager.importPartnerComposerAttachments(urls)
            }
        }
    }

    private var partnerComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("MESSAGE PARTNER")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Label(
                    controller?.screenContextEnabledForSession == true
                        ? "Screen context on" : "Screen context off",
                    systemImage:
                        controller?.screenContextEnabledForSession == true
                            ? "display.and.arrow.down" : "display"
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(
                    controller?.screenContextEnabledForSession == true
                        ? DS.Colors.success : DS.Colors.textTertiary
                )
            }

            TextField(
                "Message Partner",
                text: $composerDraft,
                axis: .vertical
            )
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .frame(minHeight: 58)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                        .allowsHitTesting(false)
                )
                .accessibilityLabel(
                    "Partner message. Paste text or HTTPS links here."
                )
                .accessibilityIdentifier("ace.partner.composer")
                .onSubmit {
                    submitComposer()
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        MenuBarPanelManager.shared?
                            .activatePanelForTextInput()
                    }
                )

            ForEach(companionManager.partnerComposerAttachments) {
                attachment in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                    Text(attachment.displayName)
                        .lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(attachment.byteCount),
                        countStyle: .file
                    ))
                    AceTrackedButton {
                        companionManager
                            .removePartnerComposerAttachment(attachment)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .accessibilityLabel(
                        "Remove \(attachment.displayName)"
                    )
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                )
            }

            HStack(spacing: 7) {
                AceTrackedButton {
                    attachmentImporterIsPresented = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                AceTrackedButton {
                    submitComposer()
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    composerDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        && companionManager
                            .partnerComposerAttachments.isEmpty
                )
                .accessibilityHint(
                    "Uses the same admitted work pipeline as Partner voice"
                )
                .accessibilityIdentifier("ace.partner.send")
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.16))
        )
    }

    private func submitComposer() {
        if companionManager.submitPartnerComposer(composerDraft) {
            composerDraft = ""
        }
    }

    private var activeSessionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = controller?.temporaryCaption,
               !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        "Current Partner transcript: \(caption)"
                    )
            }

            HStack(spacing: 7) {
                partnerActionButton(
                    controller?.isMicrophoneMuted == true ? "Resume" : "Mute",
                    systemImage:
                        controller?.isMicrophoneMuted == true
                            ? "mic.fill"
                            : "mic.slash.fill"
                ) {
                    companionManager.setPartnerMuted(
                        controller?.isMicrophoneMuted != true
                    )
                }

                partnerActionButton(
                    phase == .waiting ? "Continue" : "Think",
                    systemImage:
                        phase == .waiting
                            ? "play.fill"
                            : "pause.fill"
                ) {
                    companionManager.setPartnerWaiting(
                        phase != .waiting
                    )
                }
                .accessibilityHint(
                    phase == .waiting
                        ? "Resumes Partner listening"
                        : "Submits visible speech to Ace, or pauses listening when no speech is present"
                )

                partnerActionButton(
                    "End Partner",
                    systemImage: "xmark.circle.fill",
                    destructive: true
                ) {
                    companionManager
                        .setPartnerModeEnabled(false)
                }
            }


            AceTrackedButton(role: .destructive) {
                companionManager.escapePartnerMode()
            } label: {
                Label("Escape to normal Ace", systemImage: "escape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityHint(
                "Immediately closes the microphone and ends Partner Mode"
            )

            if controller?.screenContextEnabledForSession == true {
                HStack(spacing: 7) {
                    Image(systemName: "display.and.arrow.down")
                    Text("Screen context enabled for this session")
                    Spacer()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.success)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.06))
                )
                .accessibilityIdentifier(
                    "ace.partner.screen-context.enabled"
                )
            } else {
                AceActionButton(
                    id: AceActionID(
                        rawValue: "partner.screen-context"
                    ),
                    actionModel: actionModel,
                    timeout: .seconds(15),
                    title: "Use my screen for this session",
                    operation: {
                        try companionManager
                            .enablePartnerScreenContext()
                            .terminalSuccess()
                    }
                ) { presentation in
                    HStack(spacing: 7) {
                        if presentation.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "display")
                        }
                        Text(presentation.title)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.06))
                    )
                }
            }
        }
    }

    private var identityAndVoiceControls: some View {
        VStack(alignment: .leading, spacing: 9) {

            HStack {
                Text("ACE VOICE")
                    .font(
                        .system(
                            size: 9,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Text("Always Ace")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.agentGold)
            }

            HStack(spacing: 7) {
                Picker("Voice", selection: $selectedVoice) {
                    ForEach(
                        PartnerVoiceProfile.allCases,
                        id: \.self
                    ) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Ace voice profile")
                .disabled(AceLanguage.current != .english)
                .help("These eight profiles are for English. Other languages use their matching local voice.")

                AceActionButton(
                    id: AceActionID(
                        rawValue: "partner.voice-preview"
                    ),
                    actionModel: actionModel,
                    timeout: .seconds(30),
                    title: "Preview",
                    operation: {
                        let outcome = await companionManager
                            .previewPartnerVoice(selectedVoice)
                        return try outcome.terminalSuccess()
                    }
                ) { presentation in
                    HStack(spacing: 6) {
                        if presentation.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        Text(presentation.title)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )
                }
                .accessibilityHint(
                    PartnerVoiceConfiguration.forProfile(selectedVoice).previewSentence
                )

                if case let .succeeded(success) = actionModel.phase(
                    for: AceActionID(rawValue: "partner.voice-preview")
                ) {
                    Text(success.message)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                        .accessibilityIdentifier(
                            "ace.partner.voice-preview.success"
                        )
                }
            }

            Text(selectedVoice.deliveryDescription)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            Text(
                "Ace Voice is generated on this Mac by the engine and model sealed inside Ace. It requires no Siri voice, account, or download."
            )
            .font(.system(size: 9))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            AceActionButton(
                id: AceActionID(rawValue: "partner.identity-save"),
                actionModel: actionModel,
                timeout: .seconds(15),
                title: "Use this voice",
                operation: {
                    try saveIdentityPreferences()
                        .terminalSuccess()
                }
            ) { presentation in
                HStack(spacing: 7) {
                    if presentation.showsProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text(presentation.title)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(DS.Colors.agentGoldDeep)
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if case let .succeeded(success) = actionModel.phase(
                for: AceActionID(rawValue: "partner.identity-save")
            ) {
                Text(success.message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                    .accessibilityIdentifier(
                        "ace.partner.identity-save.success"
                    )
            }

            if resetIsArmed {
                Text("Clears Partner identity, memory and saved session summaries. Reset cannot be undone. The encryption key is kept for future Partner sessions; other Ace memory stays unchanged.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    AceTrackedButton("Cancel") {
                        resetIsArmed = false
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()

                    AceTrackedButton("Confirm reset") {
                        companionManager.resetPartnerProfile()
                        resetIsArmed = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Colors.destructiveText)
                    .pointerCursor()
                    .accessibilityHint(
                        "Clears Partner identity and memory; keeps the encryption key"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AceTrackedButton("Reset Partner memory") {
                    resetIsArmed = true
                }
                .buttonStyle(.bordered)
                .tint(DS.Colors.destructiveText)
                .pointerCursor()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHint(
                    "Requires a second confirmation"
                )
            }
        }
    }

    private func memoryReceipt(
        _ receipt: PartnerMemoryReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Memory saved", systemImage: "lock.shield.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.success)
            ForEach(
                Array(receipt.visibleChanges.enumerated()),
                id: \.offset
            ) { _, change in
                Text(change)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Undo is available for this change while this Partner session and receipt remain open.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            AceTrackedButton("Undo this memory change") {
                companionManager.undoPartnerMemoryReceipt()
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
        .partnerCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Partner memory receipt. \(receipt.visibleChanges.joined(separator: " "))"
        )
    }

    private func partnerActionButton(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        AceTrackedButton(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(
            destructive
                ? DS.Colors.destructiveText
                : DS.Colors.agentGold
        )
        .pointerCursor()
    }

    private var phaseLabel: String {
        switch phase {
        case .inactive: return "Off"
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .speaking: return "Speaking"
        case .waiting: return "Waiting"
        case .muted: return "Muted"
        case .error: return "Needs attention"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .error:
            return DS.Colors.destructiveText
        case .muted, .waiting:
            return DS.Colors.warning
        case .inactive:
            return DS.Colors.textTertiary
        default:
            return DS.Colors.success
        }
    }

    private func loadIdentityPreferences() {
        guard let preferences =
                controller?.profile.identityPreferences else {
            return
        }
        selectedVoice = preferences.voiceProfile
    }

    private func saveIdentityPreferences()
        -> AceControlActionOutcome {
        let existing = controller?.profile.identityPreferences
            ?? .genericDefault
        return companionManager.updatePartnerIdentityPreferences(
            PartnerIdentityPreferences(
                identityDescription: existing.identityDescription,
                subjectPronouns: existing.subjectPronouns,
                objectPronouns: existing.objectPronouns,
                possessivePronoun: existing.possessivePronoun,
                voiceProfile: selectedVoice,
                speakingRate: selectedVoice.defaultSpeakingRate,
                warmth: selectedVoice.defaultWarmth,
                energy: selectedVoice.defaultEnergy
            )
        )
    }
}

private struct SyllabusCalendarPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var workflow: SyllabusCalendarWorkflow
    @State private var selectedAttachmentID: UUID?
    @State private var syllabusImporterIsPresented = false

    var body: some View {
        DisclosureGroup("Syllabus → Calendar") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Attach a PDF or image, extract a proposed schedule, edit it, choose the exact calendar, then review and create. You never need to know an agent name."
                )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                if !companionManager.partnerComposerAttachments.isEmpty {
                    Picker(
                        "Syllabus attachment",
                        selection: $selectedAttachmentID
                    ) {
                        Text("Select attachment")
                            .tag(UUID?.none)
                        ForEach(
                            companionManager.partnerComposerAttachments
                        ) { attachment in
                            Text(attachment.displayName)
                                .tag(Optional(attachment.id))
                        }
                    }
                    .font(.system(size: 10))
                }

                HStack(spacing: 6) {
                    AceTrackedButton("Choose syllabus file") {
                        syllabusImporterIsPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    AceTrackedButton("Extract attachment") {
                        guard let selectedAttachmentID,
                              let attachment = companionManager
                                .partnerComposerAttachments.first(where: {
                                    $0.id == selectedAttachmentID
                                }) else { return }
                        Task { await workflow.prepare(
                            attachment: attachment
                        ) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedAttachmentID == nil)

                    AceTrackedButton("Use visible syllabus") {
                        Task {
                            await companionManager
                                .prepareVisibleSyllabusForCalendar()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if workflow.isWorking {
                    ProgressView().controlSize(.small)
                }

                Text(workflow.status)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !workflow.ambiguities.isEmpty {
                    Text("NEEDS REVIEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.warning)
                    ForEach(workflow.ambiguities, id: \.self) {
                        ambiguity in
                        Text("• \(ambiguity)")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.warning)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }

                if !workflow.proposals.isEmpty {
                    Text("EDITABLE PREVIEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.agentGold)

                    ForEach(workflow.proposals.indices, id: \.self) {
                        index in
                        VStack(alignment: .leading, spacing: 5) {
                            TextField(
                                "Assignment title",
                                text: Binding(
                                    get: {
                                        workflow.proposals[index].title
                                    },
                                    set: {
                                        workflow.proposals[index].title = $0
                                        workflow.invalidateAuthority()
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10))

                            DatePicker(
                                "Date and time",
                                selection: Binding(
                                    get: {
                                        workflow.proposals[index].dueAt
                                    },
                                    set: {
                                        workflow.proposals[index].dueAt = $0
                                        workflow.invalidateAuthority()
                                    }
                                )
                            )
                            .font(.system(size: 9))

                            HStack {
                                Stepper(
                                    "\(workflow.proposals[index].durationMinutes) min",
                                    value: Binding(
                                        get: {
                                            workflow.proposals[index]
                                                .durationMinutes
                                        },
                                        set: {
                                            workflow.proposals[index]
                                                .durationMinutes = $0
                                            workflow.invalidateAuthority()
                                        }
                                    ),
                                    in: 5...480,
                                    step: 5
                                )
                                .font(.system(size: 9))
                                Spacer()
                                AceTrackedButton(role: .destructive) {
                                    workflow.removeProposal(
                                        workflow.proposals[index].id
                                    )
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(AceMotionButtonStyle())
                            }
                        }
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.white.opacity(0.05))
                        )
                    }

                    AceTrackedButton("Add item") {
                        workflow.addBlankProposal()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Picker(
                        "Destination calendar",
                        selection: Binding(
                            get: { workflow.selectedCalendarID },
                            set: {
                                workflow.selectedCalendarID = $0
                                workflow.invalidateAuthority()
                            }
                        )
                    ) {
                        Text("Choose exact calendar").tag(String?.none)
                        ForEach(workflow.calendars) { calendar in
                            Text("\(calendar.sourceTitle) — \(calendar.title)")
                                .tag(Optional(calendar.id))
                        }
                    }
                    .font(.system(size: 10))

                    HStack(spacing: 6) {
                        AceTrackedButton("Review exact changes") {
                            workflow.armExactReview()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if workflow.authorityIsArmed {
                            AceTrackedButton("Create & Verify") {
                                Task { await workflow.createAndVerify() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.top, 7)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(DS.Colors.textSecondary)
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.16))
        )
        .accessibilityIdentifier("ace.syllabus-calendar.workflow")
        .fileImporter(
            isPresented: $syllabusImporterIsPresented,
            allowedContentTypes: [.pdf, .image, .plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first else { return }
            let priorIDs = Set(
                companionManager.partnerComposerAttachments.map(\.id)
            )
            companionManager.importPartnerComposerAttachments([url])
            guard let imported = companionManager
                    .partnerComposerAttachments.first(where: {
                        !priorIDs.contains($0.id)
                    }) else { return }
            selectedAttachmentID = imported.id
            Task { await workflow.prepare(attachment: imported) }
        }
    }
}

private extension View {
    func partnerTextField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 10))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.06))
            )
    }

    func partnerCard() -> some View {
        padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        DS.Colors.agentGold.opacity(0.18),
                        lineWidth: 0.6
                    )
                    .allowsHitTesting(false)
            )
    }
}
#endif // circuit-convert
