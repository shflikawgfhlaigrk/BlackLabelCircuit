// Sovereign — PREBUILT AGENTS (first-launch catalog).
//
// The app no longer opens to an empty "No agents yet" wall: on FIRST launch the store seeds ten
// prebuilt agents so the buyer can run something useful immediately. These are templates, not
// data — every one runs the same real plan→act→verify loop (AgentEngine) over the buyer's OWN
// data, and every tool granted below is a real, wired AgentTool. Nothing here fabricates output:
// an agent whose tools return nothing says so honestly.
//
// The seed is IN MEMORY ONLY until the buyer's first real edit (ship-no-data §5.2) — the edit
// persists whatever remains, so a buyer who deletes them writes an empty list and never has them
// forced back. A full data wipe (Guideline 5.1.1(v)) removes the payload entirely → factory-fresh
// relaunch shows the catalog again.
import Foundation

enum PrebuiltAgents {

    /// Seed only while NO agent payload has ever been written — once the buyer has saved anything
    /// (even an emptied list), their state is authoritative. Pure → testable.
    static func shouldSeed(hasStoredPayload: Bool) -> Bool {
        !hasStoredPayload
    }

    /// The ten prebuilt agents. Fresh ids/dates per call — callers seed the result, not share it.
    static var all: [CustomAgent] {
        [
            CustomAgent(name: "Morning Briefing",
                        blurb: "What actually moved, plus today's calendar.",
                        instructions: "Start my day: pull the daily digest of what really changed (deals, notes, activity), read today's calendar, and give me a short brief with the 3 things that most deserve my attention. Only report what the tools return.",
                        tools: [.dailyDigest, .readCalendar, .recallMemory],
                        icon: "sun.max.fill"),
            CustomAgent(name: "Meeting Prep",
                        blurb: "A one-page brief before any meeting.",
                        instructions: "Before a meeting, gather what I know about the topic and attendees from my notes, memory, and calendar, then produce a short brief: context, the people, the goal, and 3 questions I should ask.",
                        tools: [.searchKnowledge, .recallMemory, .readCalendar],
                        icon: "calendar.badge.clock"),
            CustomAgent(name: "Inbox Drafter",
                        blurb: "Drafts replies in my voice, grounded on my context.",
                        instructions: "Draft courteous, concise replies in my voice. Use my memory for tone and standing facts, and my knowledge for specifics. Never invent commitments — flag anything I need to confirm before sending.",
                        tools: [.recallMemory, .searchKnowledge],
                        icon: "arrowshape.turn.up.left.fill"),
            CustomAgent(name: "Research Scout",
                        blurb: "Reads a page, checks it against what I know, saves the takeaway.",
                        instructions: "When I give you a URL or topic, fetch the page, compare it against my own documents, and summarize what is new or contradicts what I have. Offer to save the key takeaway as a note — never save without confirmation.",
                        tools: [.fetchURL, .searchKnowledge, .saveNote],
                        icon: "globe"),
            CustomAgent(name: "Pipeline Analyst",
                        blurb: "Reads my clients and deal stages, flags what is stalling.",
                        instructions: "Look through my client records and deal pipeline. Tell me which deals changed stage, which have gone quiet, and which need a next step. Use only the records that exist — if the pipeline is empty, say so.",
                        tools: [.lookupClient, .dailyDigest, .recallMemory],
                        icon: "person.crop.rectangle.stack.fill"),
            CustomAgent(name: "File Finder",
                        blurb: "Finds the document I half-remember.",
                        instructions: "Help me find files: search my granted folders and indexed knowledge for what I describe, then show the best matches with where each lives. If nothing matches, say exactly that.",
                        tools: [.searchFiles, .searchKnowledge],
                        icon: "folder.fill.badge.questionmark"),
            CustomAgent(name: "Note Keeper",
                        blurb: "Turns what I tell it into durable memory.",
                        instructions: "When I tell you something worth remembering, distill it to one clear fact and save it to my memory (with my confirmation). Recall related memories first so we update rather than duplicate.",
                        tools: [.saveNote, .recallMemory],
                        icon: "square.and.pencil"),
            CustomAgent(name: "Week Planner",
                        blurb: "Lays out the week from my calendar and open threads.",
                        instructions: "Read my upcoming calendar and what recently moved, then propose a plan for the week: the fixed commitments, the gaps, and what I should slot into them. Base it only on real events and real activity.",
                        tools: [.readCalendar, .dailyDigest, .recallMemory],
                        icon: "calendar"),
            CustomAgent(name: "Follow-Up Chaser",
                        blurb: "Surfaces the people I owe a reply or a nudge.",
                        instructions: "Go through my clients and memory for promised follow-ups and threads that went quiet. List who I owe contact, why, and a suggested one-line opener. Offer to save the list as a note.",
                        tools: [.lookupClient, .recallMemory, .saveNote],
                        icon: "checklist"),
            CustomAgent(name: "Tool Runner",
                        blurb: "Drives my connected tools and apps toward a goal — asking before it acts.",
                        instructions: "When I give you a goal, discover what my connected tools can do and, when it helps, operate my apps directly (inspect first, then act) to get it done — checking with me before anything that acts. Prefer Accessibility controls and use visual control only for surfaces Accessibility cannot address. You approve every step through the operator dial, and payments/sends/deletes always stop for me. Report exactly what each tool returned — no more.",
                        tools: [.useConnectors, .operateUI, .visualControl, .recentActivity, .recallMemory, .searchKnowledge],
                        icon: "puzzlepiece.extension.fill"),
        ]
    }
}
