// Sovereign — persistent Memory layer. This is the ChatGPT-style "saved memories" pattern,
// done on-device and HONEST: an explicit, user-editable set of facts the assistant should
// always know about the buyer (name, role, preferences, ongoing projects). Unlike Knowledge
// docs (retrieved by relevance) or Vault notes, memories are ALWAYS injected into every brain
// call as standing context — so the assistant feels like it remembers you across conversations.
//
// Critical honesty rules:
//  - The buyer writes every memory by hand (or saves one from a chat). NOTHING is auto-mined,
//    nothing is confabulated, no personal data is baked into the shipped app. Starts EMPTY.
//  - Each memory can be toggled off without deleting it.
//  - The UI shows exactly what is injected — the buyer can see and edit their own model of self.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct MemoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    var enabled: Bool = true
    var created = Date()
    var source: String = "manual"   // "manual" | "chat" — provenance, never fabricated

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isUsable: Bool { enabled && !trimmed.isEmpty }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class MemoryStore: ObservableObject {
    @Published var items: [MemoryItem] = [] { didSet { persist() } }
    @Published var memoryEnabled: Bool {                    // master switch (mirrors ChatGPT's toggle)
        didSet { d.set(memoryEnabled, forKey: Self.enabledStoreKey) }
    }

    private let d: UserDefaults
    // On-device store keys. STATIC + nonisolated so the durability check (SV-13) can read the
    // persisted vault straight from the store WITHOUT going through the main actor or the brain —
    // proving the vault lives independently of whichever brain is selected.
    nonisolated static let storeKey = "com.blacklabel.sovereign.memory.v1"
    nonisolated static let enabledStoreKey = "com.blacklabel.sovereign.memory.enabled.v1"

    // Honest cap on how much standing memory is injected, so the context window isn't blown
    // and the UI count never overstates what actually reaches the brain.
    nonisolated static let injectionCap = 25

    /// Demo Mode: keep synthetic sample memories in memory only, never in UserDefaults.
    private var demoEphemeral = false

    /// `defaults` is injectable so the durability suite can exercise the REAL persistence path in an
    /// isolated UserDefaults suite (no `.standard` pollution). Production wiring uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        d = defaults
        memoryEnabled = (d.object(forKey: Self.enabledStoreKey) as? Bool) ?? true
        if let data = d.data(forKey: Self.storeKey), let m = try? JSONDecoder().decode([MemoryItem].self, from: data) { items = m }
    }
    private func persist() {
        guard !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(items) { d.set(data, forKey: Self.storeKey) }
    }

    /// Seed clearly-labeled SAMPLE memories for Demo Mode — in memory only. Idempotent.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real memories in UserDefaults untouched; restored by endDemo()
        items = DemoSeed.memories
    }
    /// Leave Demo Mode: drop sample memories, restore the buyer's real on-disk memories, re-enable saves.
    func endDemo() {
        demoEphemeral = true
        if let data = d.data(forKey: Self.storeKey), let m = try? JSONDecoder().decode([MemoryItem].self, from: data) { items = m }
        else { items = [] }
        demoEphemeral = false
    }

    /// Permanently erase ALL standing memories and reset the master toggle — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        items = []
        memoryEnabled = true
    }

    func add(_ text: String, source: String = "manual") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // De-dupe exact repeats (case-insensitive) so saving the same fact twice is a no-op.
        guard !items.contains(where: { $0.trimmed.lowercased() == t.lowercased() }) else { return }
        items.insert(MemoryItem(text: t, source: source), at: 0)
    }
    func update(_ m: MemoryItem) { if let i = items.firstIndex(where: { $0.id == m.id }) { items[i] = m } }
    func delete(_ m: MemoryItem) { items.removeAll { $0.id == m.id } }
    func toggle(_ m: MemoryItem) { if let i = items.firstIndex(where: { $0.id == m.id }) { items[i].enabled.toggle() } }
    func clearAll() { items.removeAll() }

    /// How many memories actually reach the brain (honest UI count): enabled, non-empty, capped.
    var injectedCount: Int { min(items.filter { $0.isUsable }.count, Self.injectionCap) }

    /// Standing context injected into EVERY brain call. Returns "" when memory is off or empty,
    /// so the brain never receives — and never invents — anything the buyer didn't write.
    func standingContext() -> String { Self.standingContext(items, enabled: memoryEnabled) }

    /// Pure builder so it's unit-testable off the main actor.
    nonisolated static func standingContext(_ items: [MemoryItem], enabled: Bool) -> String {
        guard enabled else { return "" }
        let usable = items.filter { $0.isUsable }.prefix(injectionCap)
        guard !usable.isEmpty else { return "" }
        let lines = usable.map { "• \($0.trimmed)" }.joined(separator: "\n")
        return "What you know about the user (their saved memories — treat as standing facts, never contradict, never invent beyond these):\n" + lines
    }

    // MARK: Global search (⌘K)
    /// Find saved memories by free-text — so the buyer can locate their own standing facts from
    /// the command palette, exactly like conversations/docs/prompts/skills. Searches ALL non-empty
    /// memories (enabled OR disabled) so one can be found and re-enabled; the UI labels its state.
    func search(_ raw: String) -> [MemoryItem] { Self.search(items, query: raw) }

    /// Pure, nonisolated so it's deterministically unit-testable off the main actor. Matches with
    /// `range(of:options:.caseInsensitive)` on the memory text itself — never an index borrowed
    /// from a separate `.lowercased()` copy (undefined; traps on length-changing lowercase like
    /// "İ" -> "i̇"). Honest empty array below the 2-char floor or on no match.
    nonisolated static func search(_ items: [MemoryItem], query raw: String) -> [MemoryItem] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        return items.filter { !$0.trimmed.isEmpty && $0.trimmed.range(of: q, options: .caseInsensitive) != nil }
    }

    // MARK: - SV-13 durability — the vault is read straight from the on-device store, never the brain

    /// Read the buyer's standing memories STRAIGHT from the persisted on-device store, with NO
    /// reference to the selected brain. This is the honest proof behind "your memory survives brain
    /// swaps": the read path only ever touches UserDefaults, so swapping `settings.brainProvider`
    /// cannot change what comes back. Used by the durability check + a fresh-instance re-read.
    nonisolated static func persistedItems(_ defaults: UserDefaults = .standard) -> [MemoryItem] {
        guard let data = defaults.data(forKey: storeKey),
              let m = try? JSONDecoder().decode([MemoryItem].self, from: data) else { return [] }
        return m
    }

    /// A live snapshot of THIS store's durable vault, labelled with the brain it was read under.
    /// `knowledgeDocCount` is supplied by the caller (the Store owns Knowledge docs) so the snapshot
    /// covers the whole vault the buyer trusts to survive a swap.
    func vaultSnapshot(brain: String, knowledgeDocCount: Int) -> VaultSnapshot {
        VaultSnapshot(factCount: items.count, injectedCount: injectedCount,
                      knowledgeDocCount: knowledgeDocCount, brain: brain)
    }
}
#endif // circuit-convert

// MARK: - SV-13 — durable memory/knowledge vault survives a brain swap (buyer-visible + verifiable)

/// A snapshot of the on-device vault at a moment in time: the standing memories the buyer holds and
/// the Knowledge documents that ground retrieval. Both live in stores keyed INDEPENDENTLY of
/// `settings.brainProvider`, so switching the brain never reads, migrates, or clears them.
struct VaultSnapshot: Equatable, Codable {
    var factCount: Int          // standing memories held on-device (enabled + disabled)
    var injectedCount: Int      // how many actually reach the brain right now (honest)
    var knowledgeDocCount: Int  // Knowledge docs that can ground retrieval
    var brain: String           // the brain provider label this snapshot was read under

    /// Total durable items the buyer is trusting to survive a swap.
    var vaultItemCount: Int { factCount + knowledgeDocCount }
}

/// The buyer-visible, VERIFIABLE guarantee behind SV-13. Turns the structural fact (the vault stores
/// are decoupled from the brain) into an honest statement the buyer can inspect and check — never an
/// unbacked marketing line. A verify captures the vault BEFORE a brain swap and AFTER it, then
/// compares: durability is *proven*, not asserted.
struct VaultDurabilityProof: Equatable {
    let before: VaultSnapshot
    let after: VaultSnapshot

    /// The vault survived iff the DURABLE counts read back identical after the swap. Only the durable
    /// fields are compared — the `brain` label is expected to differ; that's the whole point.
    var survived: Bool {
        before.factCount == after.factCount
            && before.injectedCount == after.injectedCount
            && before.knowledgeDocCount == after.knowledgeDocCount
    }

    /// True only when the swap actually changed the brain (a real from→to). A same-brain "swap" is
    /// not a proof of anything, so the UI can label it honestly.
    var brainActuallyChanged: Bool { before.brain != after.brain }

    /// The buyer-facing verification line. Names the real counts and the real from→to brains, so the
    /// buyer reads exactly what was checked. Honest on both outcomes.
    var statement: String {
        if survived {
            return "Verified — your \(before.factCount) saved \(Self.facts(before.factCount)) and "
                + "\(before.knowledgeDocCount) Knowledge \(Self.docs(before.knowledgeDocCount)) stayed on this device "
                + "when the brain switched from \(before.brain) to \(after.brain). "
                + "Your memory is the vault; the brain is just the reader."
        }
        return "The vault changed across the swap (\(before.vaultItemCount) → \(after.vaultItemCount) items). "
            + "That must never happen — the vault is stored independently of the brain."
    }

    static func facts(_ n: Int) -> String { n == 1 ? "fact" : "facts" }
    static func docs(_ n: Int) -> String { n == 1 ? "doc" : "docs" }

    /// The RESTING guarantee shown before the buyer runs a verify. Reads the LIVE vault counts so the
    /// number is real, never asserted. Used in the Memory screen's durability panel.
    static func guaranteeLine(facts: Int, docs: Int) -> String {
        "Your \(facts) saved \(self.facts(facts)) and \(docs) Knowledge \(self.docs(docs)) live in an "
            + "on-device vault, stored separately from whichever brain you run. Switch brains anytime — "
            + "your memory comes with you."
    }
}
