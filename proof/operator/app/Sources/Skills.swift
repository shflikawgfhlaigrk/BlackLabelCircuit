// Sovereign — the Skills system. A skill is a named, reusable instruction template the
// buyer can run against the on-device brain over any input (typed, pasted, or a knowledge
// doc). Built-in skills ship as TEMPLATES (no fabricated output) and the buyer can add
// their own. Running a skill is a real brain call — output is never invented.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct Skill: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var blurb: String
    var icon: String
    var instruction: String       // system instruction for the skill
    var promptTemplate: String    // {input} is replaced with the buyer's input
    var builtIn: Bool = false

    func buildPrompt(_ input: String) -> String {
        promptTemplate.replacingOccurrences(of: "{input}", with: input)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class SkillStore: ObservableObject {
    @Published var custom: [Skill] = [] { didSet { persist() } }
    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.skills.v1"
    /// Demo Mode: keep synthetic sample skills in memory only, never in UserDefaults.
    private var demoEphemeral = false

    init() {
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode([Skill].self, from: data) { custom = s }
    }
    private func persist() {
        guard !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(custom) { d.set(data, forKey: key) }
    }
    func add(_ s: Skill) { custom.insert(s, at: 0) }
    func delete(_ s: Skill) { custom.removeAll { $0.id == s.id } }
    func update(_ s: Skill) { if let i = custom.firstIndex(where: { $0.id == s.id }) { custom[i] = s } }

    /// Seed clearly-labeled SAMPLE custom skills for Demo Mode — in memory only. Idempotent.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real skills in UserDefaults untouched; restored by endDemo()
        custom = DemoSeed.skills
    }
    /// Leave Demo Mode: drop sample skills, restore the buyer's real on-disk skills, re-enable saves.
    func endDemo() {
        demoEphemeral = true
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode([Skill].self, from: data) { custom = s }
        else { custom = [] }
        demoEphemeral = false
    }

    /// Permanently erase ALL of the buyer's custom skills (built-ins remain) — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        custom = []
    }

    var all: [Skill] { Self.builtIns + custom }

    // Built-in skill TEMPLATES. These are instruction templates, not canned answers —
    // every result is produced live by the on-device brain over the buyer's own input.
    static let builtIns: [Skill] = [
        Skill(name: "Summarize", blurb: "Condense any text into tight bullet points.",
              icon: "text.append",
              instruction: "You are a precise summarizer. Produce a faithful summary. Never add facts not present in the text.",
              promptTemplate: "Summarize the following into 4-6 concise bullet points:\n\n{input}", builtIn: true),
        Skill(name: "Rewrite — professional", blurb: "Polish text to a clear, professional tone.",
              icon: "wand.and.stars",
              instruction: "You rewrite text to be clear, professional, and concise while preserving meaning.",
              promptTemplate: "Rewrite the following in a professional tone, keeping all facts:\n\n{input}", builtIn: true),
        Skill(name: "Extract action items", blurb: "Pull tasks & owners out of notes or a transcript.",
              icon: "checklist",
              instruction: "You extract concrete action items. Only list tasks actually implied by the text.",
              promptTemplate: "Extract a checklist of action items (with an owner if named) from:\n\n{input}", builtIn: true),
        Skill(name: "Explain simply", blurb: "Explain a concept in plain language.",
              icon: "lightbulb.fill",
              instruction: "You explain concepts simply and accurately, without dumbing down the facts.",
              promptTemplate: "Explain this clearly to a smart non-expert:\n\n{input}", builtIn: true),
        Skill(name: "Draft a reply", blurb: "Draft a courteous reply to a message or email.",
              icon: "arrowshape.turn.up.left.fill",
              instruction: "You draft courteous, concise replies. Match the sender's register. Do not invent commitments.",
              promptTemplate: "Draft a concise, courteous reply to this message:\n\n{input}", builtIn: true),
        Skill(name: "Brainstorm", blurb: "Generate a focused list of ideas.",
              icon: "sparkles",
              instruction: "You brainstorm focused, practical ideas.",
              promptTemplate: "Brainstorm 8 distinct, practical ideas for:\n\n{input}", builtIn: true),
        Skill(name: "Code review", blurb: "Spot bugs & suggest improvements in a snippet.",
              icon: "chevron.left.forwardslash.chevron.right",
              instruction: "You are a careful code reviewer. Identify real bugs and concrete improvements. Don't fabricate APIs.",
              promptTemplate: "Review this code for bugs and improvements:\n\n{input}", builtIn: true),
        Skill(name: "Translate to plain English", blurb: "De-jargon dense or legal text.",
              icon: "character.book.closed.fill",
              instruction: "You translate dense or jargon-heavy text into plain English while preserving meaning.",
              promptTemplate: "Rewrite this in plain English:\n\n{input}", builtIn: true)
    ]
}
#endif // circuit-convert
