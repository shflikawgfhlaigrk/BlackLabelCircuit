// Sovereign — SkillSmith: the assistant DRAFTS and REFINES the buyer's own skills.
// This is the honest form of "self-improving skills" (a named Tier-5 differentiator): the
// brain PROPOSES a reusable skill (a real model call) and the buyer REVIEWS / edits / saves
// it — nothing is auto-written and nothing is fabricated. When the model can't produce a
// usable skill, `parse` returns nil and the UI says so honestly instead of inventing one.
//
// SkillSmith owns only the PROMPT CONTRACT and the PARSER — pure value logic, fully unit
// tested headless. The live brain call + the review sheet live in the UI layer (SkillsScreen).
import Foundation

enum SkillSmith {
    /// Icons SkillSmith may assign to a drafted skill — kept in lock-step with SkillEditor's
    /// picker so the review sheet shows the chosen icon selected. A model-suggested icon outside
    /// this set falls back to a safe default so a card never renders a blank glyph.
    static let allowedIcons = ["sparkles", "wand.and.stars", "text.append", "checklist",
                               "lightbulb.fill", "bolt.fill", "doc.text.fill",
                               "chevron.left.forwardslash.chevron.right", "envelope.fill", "magnifyingglass"]
    static let defaultIcon = "sparkles"

    /// System instruction for both drafting and refinement. Constrains the model to emit ONE
    /// strict, line-keyed block we can parse deterministically — no prose, no canned output.
    static let system = """
    You are a skill author for a personal assistant. A "skill" is a reusable instruction \
    template the user runs against the assistant over their own input. Design ONE skill that \
    fits the user's request. Reply with EXACTLY this block and nothing else:

    NAME: a short name, 40 characters or fewer
    BLURB: one line, 80 characters or fewer, describing what it does
    ICON: one of: sparkles, wand.and.stars, text.append, checklist, lightbulb.fill, bolt.fill, doc.text.fill, chevron.left.forwardslash.chevron.right, envelope.fill, magnifyingglass
    INSTRUCTION: a system instruction telling the assistant how to behave for this skill (one paragraph)
    TEMPLATE:
    the prompt template, with the literal token {input} where the user's text is inserted

    Rules: never invent facts; the TEMPLATE must contain the token {input}; keep it general and reusable.
    """

    /// Build the user prompt asking the model to draft a brand-new skill from a stated goal.
    static func draftPrompt(from goal: String) -> String {
        "Design a skill for this need:\n\n" + goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the user prompt asking the model to REFINE an existing skill given feedback.
    static func refinePrompt(_ skill: Skill, feedback: String) -> String {
        """
        Improve this existing skill. Keep what works; apply the feedback. Re-emit the FULL block.

        Current name: \(skill.name)
        Current blurb: \(skill.blurb)
        Current instruction: \(skill.instruction)
        Current template:
        \(skill.promptTemplate)

        Feedback to apply:
        \(feedback.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Parse the model's reply into a Skill. Returns nil (honest empty) when the reply lacks a
    /// usable name AND body — the UI then tells the buyer it couldn't draft one, never a fake.
    /// Drafted skills are always custom (builtIn=false). Pass `keepingID` on a refine so the
    /// editor's Save UPDATES the existing skill instead of adding a duplicate.
    static func parse(_ raw: String, keepingID id: UUID? = nil) -> Skill? {
        // Strip a Markdown code fence if the model wrapped the block.
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            let lines = body.components(separatedBy: "\n")
            body = lines.dropFirst().prefix { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        var name = "", blurb = "", icon = "", instruction = ""
        var templateLines: [String] = []
        var inTemplate = false
        for line in body.components(separatedBy: "\n") {
            if inTemplate { templateLines.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let v = value(of: "NAME:", in: trimmed) { name = v }
            else if let v = value(of: "BLURB:", in: trimmed) { blurb = v }
            else if let v = value(of: "ICON:", in: trimmed) { icon = v }
            else if let v = value(of: "INSTRUCTION:", in: trimmed) { instruction = v }
            else if matches(prefix: "TEMPLATE:", in: trimmed) {
                inTemplate = true
                let inline = value(of: "TEMPLATE:", in: trimmed) ?? ""
                if !inline.isEmpty { templateLines.append(inline) }
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var template = templateLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Honest empty: a real skill needs a name AND some body (template or instruction).
        guard !name.isEmpty, !(template.isEmpty && instruction.isEmpty) else { return nil }
        if template.isEmpty { template = "{input}" }
        if !template.contains("{input}") { template += "\n\n{input}" }
        let safeIcon = allowedIcons.contains(icon) ? icon : defaultIcon
        var skill = Skill(name: String(name.prefix(60)), blurb: blurb, icon: safeIcon,
                          instruction: instruction, promptTemplate: template, builtIn: false)
        if let id { skill.id = id }
        return skill
    }

    // MARK: - line parsing helpers (case-insensitive key match)
    private static func matches(prefix: String, in line: String) -> Bool {
        line.lowercased().hasPrefix(prefix.lowercased())
    }
    private static func value(of key: String, in line: String) -> String? {
        guard matches(prefix: key, in: line) else { return nil }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }
}
