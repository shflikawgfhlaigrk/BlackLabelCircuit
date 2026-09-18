#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Memory screen. The buyer's explicit, editable model of themselves: standing
// facts the assistant should always know (name, role, preferences, ongoing projects). These
// are injected into EVERY brain call, so the assistant feels like it remembers you across
// conversations. HONEST: the buyer writes every memory by hand (or saves one from a chat);
// nothing is auto-mined, nothing is fabricated, the app ships EMPTY. The list shows exactly
// what is injected, and the buyer can disable or delete any item at any time.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct MemoryScreen: View {
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var crm: ClientStore
    @EnvironmentObject var store: Store          // SV-13: the Knowledge docs half of the vault
    @EnvironmentObject var settings: AppSettings // SV-13: the live brain, to prove a real swap
    @EnvironmentObject var recall: RecallStore   // SV-18: the opt-in cited recall vault (ships OFF)
    @State private var draft = ""
    @State private var editing: MemoryItem?
    @State private var confirmClear = false
    @State private var showClients = false
    @State private var durabilityProof: VaultDurabilityProof?   // SV-13 verify result
    @State private var recallQuery = ""                         // SV-18 cited recall search
    @State private var recallNote: String?                      // SV-18 honest last-capture outcome
    @State private var confirmRecallWipe = false
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "Memory", subtitle: "Standing facts the assistant always knows about you — injected into every conversation")
                Spacer()
                GhostButton(label: "Clients & Pipeline", icon: "person.crop.rectangle.stack.fill") { showClients = true }
                StatusPill(text: memory.memoryEnabled ? "\(memory.injectedCount) active" : "Memory off",
                           tint: memory.memoryEnabled && memory.injectedCount > 0 ? BLTheme.green : BLTheme.sub)
            }.padding(24).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Master switch + honesty note
                    Panel(title: "Memory", icon: "brain.head.profile") {
                        Toggle(isOn: $memory.memoryEnabled) {
                            Text("Use memory in every conversation").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        }.tint(BLTheme.gold)
                        Text(DataHandlingCopy.memoryContext + " Nothing is auto-collected — you decide what's remembered.")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }

                    // SV-13 — the durability guarantee, made buyer-visible AND verifiable. The vault
                    // (memories + Knowledge docs) is stored independently of the brain; this panel
                    // states it honestly with the live counts and lets the buyer PROVE it: capture the
                    // vault, swap the brain for real, re-read the vault from disk, compare.
                    durabilityPanel

                    // SV-18 — the opt-in, on-device, CITED recall vault. Ships OFF; captures nothing
                    // until the buyer turns it on; strips secrets before anything is written.
                    recallPanel

                    // Structured client history + deal pipeline (the CRM layer of the vault)
                    Panel(title: "Client history & deal pipeline", icon: "person.crop.rectangle.stack.fill") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(crm.clients.isEmpty ? "No clients yet"
                                     : "\(crm.clients.count) client\(crm.clients.count == 1 ? "" : "s") · \(crm.openDealCount) open deal\(crm.openDealCount == 1 ? "" : "s")")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                Text("Structured records — track contacts and move deals through your pipeline. The assistant can recall a client's history when you ask.")
                                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            GoldButton(label: "Open", icon: "arrow.up.right") { showClients = true }
                        }
                    }

                    // Add a memory
                    Panel(title: "Add a memory", icon: "plus.circle.fill") {
                        HStack(spacing: 10) {
                            TextField("e.g. I'm a product designer; prefer concise answers; building an app called Atlas", text: $draft, axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                                .lineLimit(1...4).focused($addFocused)
                                .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(addFocused ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                                .onSubmit(add)
                            GoldButton(label: "Remember", icon: "checkmark") { add() }
                        }
                    }

                    // The list
                    if memory.items.isEmpty {
                        EmptyState(icon: "brain.head.profile", title: "No memories yet",
                                   hint: "Add a fact about yourself or your work above, or save a reply from The Brain. The assistant will keep it in mind across every conversation.")
                            .padding(.top, 30)
                    } else {
                        HStack {
                            Text("\(memory.items.count) mem\(memory.items.count == 1 ? "ory" : "ories") · \(memory.injectedCount) injected")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                            Button(role: .destructive) { confirmClear = true } label: {
                                Label("Clear all", systemImage: "trash").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                            }.buttonStyle(.plain)
                        }
                        VStack(spacing: 10) { ForEach(memory.items) { m in memoryRow(m) } }
                    }
                }.padding(24)
            }
        }
        .sheet(item: $editing) { m in MemoryEditor(item: m).environmentObject(memory).sheetCloseBar() }
        .sheet(isPresented: $showClients) {
            // macOS sheets need the wide CRM canvas; on iPhone a 760pt min-frame would inflate the
            // sheet past the screen (min-frames floor at the child), so iOS sizes naturally.
            #if os(macOS)
            ClientsScreen().environmentObject(crm)
                .frame(minWidth: 760, minHeight: 580)
                .sheetCloseBar()
            #else
            ClientsScreen().environmentObject(crm)
                .sheetCloseBar()
            #endif
        }
        .alert("Clear all memories?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { memory.clearAll() }
        } message: { Text("This permanently removes every saved memory from this device. It can't be undone.") }
    }

    // MARK: - SV-13 durability panel (buyer-visible + verifiable "survives brain swaps")
    private var durabilityPanel: some View {
        Panel(title: "Your memory survives brain swaps", icon: "lock.rotation") {
            Text(VaultDurabilityProof.guaranteeLine(facts: memory.items.count, docs: store.groundedDocCount))
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On this device now")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Text("\(memory.items.count) memor\(memory.items.count == 1 ? "y" : "ies") · \(store.groundedDocCount) Knowledge doc\(store.groundedDocCount == 1 ? "" : "s") · brain: \(settings.brainProvider.label)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                GoldButton(label: "Verify a brain swap", icon: "arrow.triangle.2.circlepath") { verifyDurability() }
            }
            if let p = durabilityProof {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: p.survived ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundColor(p.survived ? BLTheme.green : .orange)
                    Text(p.statement)
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(p.survived ? BLTheme.text : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke((p.survived ? BLTheme.green : Color.orange).opacity(0.35), lineWidth: 1))
            }
        }
    }

    /// PROVE it, don't assert it: snapshot the vault under the current brain, swap the stored brain to
    /// a genuinely different provider, re-read the vault STRAIGHT from disk (a path that never consults
    /// the brain) plus the live Knowledge doc count, then restore the buyer's brain. Identical durable
    /// counts across a real from→to swap = the vault survived. No network probe (we don't re-resolve).
    private func verifyDurability() {
        let from = settings.brainProvider
        let before = VaultSnapshot(factCount: MemoryStore.persistedItems().count,
                                   injectedCount: memory.injectedCount,
                                   knowledgeDocCount: store.groundedDocCount,
                                   brain: from.label)
        let to = BrainProvider.allCases.first { $0 != from } ?? from
        settings.brainProvider = to          // a REAL, persisted swap of the stored brain
        let fresh = MemoryStore()            // re-open the vault from disk from scratch, no brain involved
        let after = VaultSnapshot(factCount: fresh.items.count,
                                  injectedCount: fresh.injectedCount,
                                  knowledgeDocCount: store.groundedDocCount,
                                  brain: to.label)
        settings.brainProvider = from        // restore the buyer's brain (net-zero change)
        durabilityProof = VaultDurabilityProof(before: before, after: after)
    }

    // MARK: - SV-18 recall panel (opt-in, on-device, cited, secrets redacted — ships OFF)

    /// The live gate for THIS Mac: the buyer's real opt-in + the real Screen Recording permission.
    /// Never assumed — on a platform without the keyless capture path it reports `.unsupported` and
    /// the panel shows an honest dead-end instead of a control that does nothing.
    private var recallAvailability: RecallPolicy.Availability {
        #if os(macOS)
        return RecallCapture.availability(optedIn: recall.optedIn)
        #else
        return RecallPolicy.availability(optedIn: recall.optedIn, screenAccessGranted: false, supported: false)
        #endif
    }

    private var recallPanel: some View {
        Panel(title: RecallCopy.title, icon: "clock.arrow.circlepath") {
            Toggle(isOn: Binding(get: { recall.optedIn }, set: { on in
                recall.optedIn = on
                #if os(macOS)
                // Ask for Screen Recording ONLY on the buyer's own opt-in tap — never on launch,
                // never on merely viewing this screen.
                if on && !RecallCapture.screenAccessGranted { RecallCapture.requestScreenAccess() }
                #endif
            })) {
                Text(RecallCopy.optInLabel).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(BLTheme.gold)

            // The honest state line — off / needs-permission / ready, straight from the pure gate.
            Text(RecallPolicy.reason(recallAvailability))
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            if recallAvailability == .noScreenAccess {
                // The denial names its fix: deep-link straight to the Screen Recording pane
                // (the one-time OS prompt never re-fires once denied).
                GhostButton(label: "Open Screen Recording Settings", icon: "gearshape.fill", tint: .orange) {
                    PrivacyPane.screenRecording.open()
                }
            }
            #endif

            Text(RecallCopy.scopeNote)
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text(RecallCopy.redactionNote)
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            // SV-18 residual — the SEPARATE scheduled-capture switch. Only offered once Recall itself
            // is on (scheduled sampling requires the base opt-in too), so it is never presented as a
            // standalone always-on recorder. Ships OFF; flipping it is a second, deliberate act.
            if recall.optedIn {
                Divider().overlay(BLTheme.stroke).padding(.vertical, 2)
                Toggle(isOn: Binding(get: { recall.scheduledOptedIn }, set: { on in
                    recall.scheduledOptedIn = on
                    #if os(macOS)
                    // Same discipline as the base opt-in: ask for Screen Recording only on the buyer's
                    // own tap enabling scheduled capture — never on launch, never on merely viewing this.
                    if on && !RecallCapture.screenAccessGranted { RecallCapture.requestScreenAccess() }
                    #endif
                })) {
                    Text(RecallCopy.scheduledLabel)
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)

                Text(recall.scheduledOptedIn ? RecallCopy.scheduledNote : RecallCopy.scheduledOffNote)
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                if recall.scheduledOptedIn {
                    HStack(spacing: 8) {
                        Text(RecallCopy.scheduledIntervalLabel)
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        Picker("", selection: Binding(get: { recall.scheduledInterval },
                                                      set: { recall.scheduledInterval = RecallPolicy.clampInterval($0) })) {
                            Text("1 min").tag(TimeInterval(60))
                            Text("5 min").tag(TimeInterval(300))
                            Text("15 min").tag(TimeInterval(900))
                            Text("30 min").tag(TimeInterval(1800))
                        }.labelsHidden().tint(BLTheme.gold).frame(width: 96)
                        Spacer()
                    }
                }
            }

            if recallAvailability == .ready {
                HStack(spacing: 10) {
                    TextField("Search what you've seen — e.g. the pricing page I had open", text: $recallQuery)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: RecallCopy.captureLabel, icon: "camera.viewfinder") { captureScreen() }
                }
            }

            if let note = recallNote {
                Text(note).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.champagne)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recall.entries.isEmpty {
                Text(RecallCopy.emptyHint)
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("\(recall.entries.count) screen\(recall.entries.count == 1 ? "" : "s") remembered · \(recall.redactedTotal) secret\(recall.redactedTotal == 1 ? "" : "s") stripped")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    Spacer()
                    Button(role: .destructive) { confirmRecallWipe = true } label: {
                        Label("Delete recall", systemImage: "trash")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                    }.buttonStyle(.plain)
                }
                let hits = recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                    ? recall.recall(recallQuery) : recall.entries
                if hits.isEmpty {
                    Text("Nothing in your recall matches “\(recallQuery)”.")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    VStack(spacing: 8) { ForEach(hits.prefix(20)) { e in recallRow(e) } }
                }
            }
        }
        .alert("Delete everything Sovereign remembers from your screen?", isPresented: $confirmRecallWipe) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) { recall.wipeAll() }
        } message: { Text("This permanently erases the recall vault from this device. It can't be undone.") }
    }

    /// One remembered screen — ALWAYS shown with its citation (which app, when). A recall that can't
    /// name its source isn't a memory, it's a claim (§5.1).
    @ViewBuilder private func recallRow(_ e: RecallEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                Text(e.fullCitation).font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                Spacer()
                if e.redactedCount > 0 {
                    Text("\(e.redactedCount) redacted")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(BLTheme.goldGrad).clipShape(Capsule())
                }
                Button { recall.forget(e) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain).help("Forget this screen")
            }
            Text(e.text).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.text)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    /// Read the screen ONCE, on the buyer's explicit tap, through the keyless Quartz + Vision path —
    /// then hand it to the store, which is the only thing allowed to decide whether a byte is kept.
    /// Every outcome (including a refusal) is reported honestly; none of them is silent.
    private func captureScreen() {
        #if os(macOS)
        let availability = RecallCapture.availability(optedIn: recall.optedIn)
        guard let raw = RecallCapture.captureFrontmost() else {
            recallNote = "Nothing to remember — no readable text on the window in front."
            return
        }
        switch recall.record(raw, availability: availability) {
        case .stored(let e):
            recallNote = e.redactedCount > 0
                ? "Remembered \(e.app) — \(e.redactedCount) secret\(e.redactedCount == 1 ? "" : "s") stripped before saving."
                : "Remembered \(e.app)."
        case .refusedCredentialSurface:
            recallNote = "Skipped — that looked like a password or Keychain prompt. Nothing was saved."
        case .refusedNotReady(let a):
            recallNote = RecallPolicy.reason(a)
        case .nothingToStore:
            recallNote = "Nothing left to save after removing secrets from that screen."
        }
        #endif
    }

    @ViewBuilder private func memoryRow(_ m: MemoryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: m.source == "chat" ? "bubble.left.fill" : "sparkle")
                .font(.system(size: 12, weight: .bold)).foregroundColor(m.enabled ? BLTheme.ink : BLTheme.sub)
                .frame(width: 32, height: 32).background(m.enabled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(m.trimmed).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(m.enabled ? BLTheme.text : BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                Text(m.source == "chat" ? "Saved from a chat" : "Added manually").font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { m.enabled }, set: { _ in memory.toggle(m) })).labelsHidden().tint(BLTheme.gold).help("Include in standing context")
            Button { editing = m } label: { Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Edit memory")
            Button { memory.delete(m) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Delete memory")
        }
        .padding(14).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        memory.add(t)
        draft = ""
    }
}

struct MemoryEditor: View {
    @EnvironmentObject var memory: MemoryStore
    @Environment(\.dismiss) var dismiss
    @State var item: MemoryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit memory").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            VStack(alignment: .leading, spacing: 4) {
                Text("MEMORY").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $item.text).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 120).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            Toggle(isOn: $item.enabled) { Text("Included in standing context").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
            HStack {
                Button("Delete", role: .destructive) { memory.delete(item); dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.danger)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") {
                    guard !item.trimmed.isEmpty else { return }
                    memory.update(item); dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(520).background(BLTheme.bg)
    }
}
#endif // circuit-convert
