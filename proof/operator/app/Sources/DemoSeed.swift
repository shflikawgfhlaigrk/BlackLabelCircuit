#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — DEMO SEED: the synthetic, clearly-labeled SAMPLE data used by Demo Mode.
//
// Every record here is FICTIONAL and obviously a sample (generic personas, neutral facts,
// "Demo"/"Sample" naming). It contains NO real leads, metrics, personal data, tokens, or Utah
// data. It is handed to the stores' `seedDemo()` methods, which keep it IN MEMORY ONLY — none of
// it is ever written to the buyer's on-disk store (see DemoMode.swift for the full contract).
//
// This is the populated world a reviewer/buyer sees when they tap "Explore with sample data":
// real-looking conversations, memories, knowledge docs, prompts, skills, agents, automations,
// reminders, and proof-of-execution receipts — enough to exercise every signature screen with
// zero external accounts.
import Foundation

enum DemoSeed {
    // Stable "now" anchor so timestamps read naturally relative to each other.
    private static let now = Date()
    private static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private static func ahead(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    // MARK: - Conversations (The Brain) — sample threads, with a clear sample marker
    static var conversations: [Conversation] {
        var c1 = Conversation(title: "Quarterly board update", personaName: "", created: ago(2880), updated: ago(40))
        c1.messages = [
            ChatMessage(role: .user, text: "Help me outline a board update for Q3. Focus: growth, retention, and what we need from the board.", created: ago(60)),
            ChatMessage(role: .assistant, text: "Here's a tight outline for your Q3 board update:\n\n1. Headline — one sentence on the quarter\n2. Growth — new logos, pipeline, net-new revenue vs. plan\n3. Retention — gross/net retention, notable churn + saves\n4. Product — what shipped, what's next\n5. Team — key hires, open roles\n6. Asks — the 2–3 decisions or intros you need from the board\n\nWant me to draft the narrative for any section? (This is a SAMPLE thread shown in Demo Mode.)", created: ago(58)),
            ChatMessage(role: .user, text: "Draft the Growth section. Assume we beat plan by 12%.", created: ago(44)),
            ChatMessage(role: .assistant, text: "Growth — We closed the quarter 12% ahead of plan. New-logo bookings drove the beat, with pipeline coverage now at 3.4x for Q4. Expansion held steady, and our top three deals all came in at or above target ACV. The takeaway: demand is healthy and the motion is repeatable — the constraint is now sales capacity, not interest.\n\nIn the full app this is generated live by the brain you connect: Ornith 1.0 locally through Ollama by default, or the private on-device model where available.", created: ago(42)),
        ]
        var c2 = Conversation(title: "Refactor: extract the rate limiter", personaName: "", created: ago(1440), updated: ago(220))
        c2.messages = [
            ChatMessage(role: .user, text: "I want to pull our inline rate-limiting into its own component. What's the cleanest seam?", created: ago(230)),
            ChatMessage(role: .assistant, text: "Define a small protocol — `RateLimiter` with `func allow(_ key: String) -> Bool` — and inject it where you currently inline the checks. That lets you swap a token-bucket for a sliding-window later without touching call sites, and makes it trivially testable with a deterministic fake. Start by wrapping today's logic behind the protocol with zero behavior change, then refactor the internals. (Sample thread — Demo Mode.)", created: ago(228)),
        ]
        var c3 = Conversation(title: "Trip planning — Lisbon", personaName: "", created: ago(720), updated: ago(300))
        c3.messages = [
            ChatMessage(role: .user, text: "Give me a loose 3-day Lisbon itinerary, walkable, not too touristy.", created: ago(305)),
            ChatMessage(role: .assistant, text: "Day 1 — Alfama at a slow pace: São Jorge castle early, then wander down through the miradouros for lunch. Day 2 — LX Factory + a tram out to Belém, pastéis at the source. Day 3 — Príncipe Real for the design shops and a long lunch, sunset at Miradouro de Santa Catarina. Keep evenings open for fado you stumble into rather than book. (Sample itinerary shown in Demo Mode.)", created: ago(303)),
        ]
        return [c1, c2, c3]
    }

    // MARK: - Knowledge docs (RAG) — sample, enabled, groundable
    static var documents: [KnowledgeDoc] {
        [
            KnowledgeDoc(name: "Sample — Product brief.md", kind: "markdown",
                body: "# Product Brief (SAMPLE)\n\nSovereign is a device-hosted AI workspace the buyer owns outright. It can use Ornith locally through Ollama, Apple's on-device model where available, or a provider the buyer connects, and grounds answers on enabled memory, knowledge, and notes.\n\n## Principles\n- Local storage: workspace records live in the buyer's app data.\n- Buyer-selected processing: local brains keep inference on-device; connected providers process the requests and enabled context sent to them.\n- No bundled keys: provider credentials belong to the buyer.\n- Zero fabrication: empty states over invented results.\n\n## Surfaces\nChat, Memory, Knowledge (RAG), Prompts, Skills, Agents, Automations, Activity, Connectors.",
                created: ago(5000)),
            KnowledgeDoc(name: "Sample — Onboarding checklist.txt", kind: "text",
                body: "Onboarding checklist (SAMPLE)\n\n1. Install Ollama and pull Ornith 1.0.\n2. Add a few memories so the assistant knows you.\n3. Import a document to ground answers.\n4. Save a prompt you reuse.\n5. Try a skill on some text.\n6. Build a small automation.\n\nEverything here is sample data shown in Demo Mode.",
                created: ago(4200)),
            KnowledgeDoc(name: "Sample — Meeting notes (2026-06).md", kind: "markdown",
                body: "# Weekly sync — notes (SAMPLE)\n\n- Shipped the new onboarding flow; early activation up.\n- Decision: move pricing sign-off to Finance, due Friday.\n- Risk: Riverstone Logistics lead time on hardware — order early to de-risk.\n- Next: draft the Q3 board update; prep the Harborlight Studios demo script.\n\nThese are synthetic notes for the Demo Mode walkthrough.",
                created: ago(180)),
        ]
    }

    // MARK: - Memories (standing facts) — sample persona, clearly fictional
    static var memories: [MemoryItem] {
        [
            MemoryItem(text: "I'm a sample user exploring Sovereign in Demo Mode (this is synthetic data).", enabled: true, created: ago(6000), source: "manual"),
            MemoryItem(text: "I prefer concise, direct answers with concrete examples.", enabled: true, created: ago(5800), source: "manual"),
            MemoryItem(text: "I run a small software team and care about retention and shipping velocity.", enabled: true, created: ago(5600), source: "manual"),
            MemoryItem(text: "Key accounts I'm working: Harborlight Studios (renewal) and Cedar & Vine Catering (new proposal); Riverstone Logistics is my hardware vendor.", enabled: true, created: ago(5500), source: "manual"),
            MemoryItem(text: "Default tone for drafts: professional but warm.", enabled: true, created: ago(5400), source: "chat"),
            MemoryItem(text: "Time zone is US Eastern; I plan my week on Sunday evenings.", enabled: true, created: ago(5200), source: "manual"),
        ]
    }

    // MARK: - Vault notes + dispatch log (Operator/AppModel)
    static var notes: [Note] {
        [
            Note(title: "Sample — Demo script", body: "Walkthrough order for the demo:\n1. Operator dashboard (the populated overview)\n2. The Brain (a sample conversation)\n3. Memory + Knowledge (what grounds answers)\n4. Skills + Agents (reusable power)\n5. Automations + Activity (proof of execution)\n\nThis is a synthetic note shown in Demo Mode.", created: ago(900), updated: ago(120)),
            Note(title: "Sample — Ideas backlog", body: "- A weekly digest automation\n- A skill that turns transcripts into action items\n- A custom agent that preps meeting briefs from my calendar\n\nSample data — Demo Mode.", created: ago(1500), updated: ago(800)),
        ]
    }
    static var dispatches: [Dispatch] {
        [
            Dispatch(command: "Summarize today's meeting notes", note: "sample", created: ago(75)),
            Dispatch(command: "Draft a follow-up email to Riverstone Logistics", note: "sample", created: ago(160)),
            Dispatch(command: "What's on my calendar tomorrow?", note: "sample", created: ago(240)),
        ]
    }

    // MARK: - Custom prompts (on top of the built-in starters)
    static var prompts: [SavedPrompt] {
        [
            SavedPrompt(title: "Weekly digest", body: "Summarize my week from the notes I paste below into Wins / In progress / Blocked, then suggest the top 3 priorities for next week. Notes:", category: .productivity, tags: ["sample", "digest"], builtIn: false, pinned: true, useCount: 7),
            SavedPrompt(title: "Tighten this paragraph", body: "Rewrite the following to be 30% shorter without losing meaning. Keep my voice. Text:", category: .writing, tags: ["sample", "editing"], builtIn: false, useCount: 4),
            SavedPrompt(title: "Stress-test a decision", body: "I'm about to make this decision. Argue the strongest case AGAINST it, then tell me what would change your mind. Decision:", category: .research, tags: ["sample", "decision"], builtIn: false, useCount: 2),
        ]
    }

    // MARK: - Custom skills (on top of the built-ins)
    static var skills: [Skill] {
        [
            Skill(name: "Meeting → brief", blurb: "Turn raw meeting notes into a one-page brief.",
                  icon: "doc.text.fill",
                  instruction: "You produce concise one-page briefs from meeting notes. Use only facts present in the input.",
                  promptTemplate: "Turn these meeting notes into a one-page brief with Decisions, Owners, and Next steps:\n\n{input}", builtIn: false),
            Skill(name: "Polish for LinkedIn", blurb: "Rewrite a rough thought as a sharp post.",
                  icon: "megaphone.fill",
                  instruction: "You rewrite rough notes into clear, non-cringe professional posts. No hype, no emojis unless asked.",
                  promptTemplate: "Rewrite this into a sharp, professional LinkedIn post:\n\n{input}", builtIn: false),
        ]
    }

    // MARK: - Custom agents (NL-defined, restricted tool surface)
    static var customAgents: [CustomAgent] {
        [
            CustomAgent(name: "Meeting Prep", blurb: "Pulls together a brief before a meeting (sample).",
                        instructions: "Before a meeting, gather what I know about the topic from my notes and memory, then produce a short brief: context, the people, the goal, and 3 questions I should ask.",
                        tools: [.searchKnowledge, .recallMemory, .readCalendar],
                        icon: "calendar.badge.clock", created: ago(3000)),
            CustomAgent(name: "Inbox Drafter", blurb: "Drafts replies grounded on my context (sample).",
                        instructions: "Draft courteous, concise replies in my voice. Use my memory for tone and standing facts. Never invent commitments — flag anything I need to confirm.",
                        tools: [.recallMemory, .searchKnowledge],
                        icon: "arrowshape.turn.up.left.fill", created: ago(2600)),
        ]
    }

    // MARK: - Automations + reminders
    static var automations: [Automation] {
        var a1 = Automation(name: "Sample — Daily standup digest", instruction: "Summarize my open items and suggest today's top 3 priorities.", schedule: .daily, enabled: true, groundOnKnowledge: true, created: ago(4000))
        a1.lastRun = ago(120); a1.runCount = 9
        a1.lastOutput = "Top 3 today: (1) finalize the Q3 board update, (2) send the Riverstone Logistics follow-up, (3) review the onboarding metrics. [Sample output — Demo Mode]"
        var a2 = Automation(name: "Sample — Weekly review prompt", instruction: "Ask me three reflection questions for a weekly review.", schedule: .weekly, enabled: false, groundOnKnowledge: false, created: ago(3500))
        a2.lastRun = ago(8000); a2.runCount = 2
        a2.lastOutput = "1) What moved the needle this week? 2) What got stuck and why? 3) What's the one thing to protect time for next week? [Sample]"
        return [a1, a2]
    }
    static var reminders: [Reminder] {
        [
            Reminder(title: "Sample — Send Q3 board update", fireAt: ahead(180), repeats: .once, created: ago(1000)),
            Reminder(title: "Sample — Weekly review", fireAt: ahead(2880), repeats: .weekly, created: ago(2000)),
        ]
    }

    // MARK: - Activity ledger (proof-of-execution receipts)
    static var activity: [ActivityEntry] {
        var out: [ActivityEntry] = []
        out.append(ActivityEntry(kind: .automation, title: "Sample — Daily standup digest",
            detail: "Top 3 today: finalize the Q3 board update, send the Riverstone Logistics follow-up, review onboarding metrics. [Sample output — Demo Mode]",
            outcome: .success, at: ago(120), durationMS: 1840))
        out.append(ActivityEntry(kind: .skill, title: "Meeting → brief",
            detail: "Produced a one-page brief from 412 words of meeting notes: 3 decisions, 4 owners, 5 next steps. [Sample]",
            outcome: .success, at: ago(300), durationMS: 2200))
        // A multi-step agent run with linked step receipts (demonstrates the agent trace UI).
        let runHead = ActivityEntry(kind: .agent, title: "Meeting Prep — board sync",
            detail: "Prepared a meeting brief grounded on sample notes, memory, and calendar. [Sample agent run]",
            outcome: .success, at: ago(420), durationMS: 5400, stepCount: 3)
        out.append(runHead)
        out.append(ActivityEntry(kind: .agent, title: "recall_memory",
            detail: "Recalled 5 standing memories (tone, role, schedule). [Sample step]", outcome: .success, at: ago(421), parentID: runHead.id))
        out.append(ActivityEntry(kind: .agent, title: "search_knowledge",
            detail: "Matched 'Meeting notes (2026-06)' and 'Product brief'. [Sample step]", outcome: .success, at: ago(421), parentID: runHead.id))
        out.append(ActivityEntry(kind: .agent, title: "read_calendar",
            detail: "Found 2 upcoming events relevant to the board sync. [Sample step]", outcome: .success, at: ago(420), parentID: runHead.id))
        out.append(ActivityEntry(kind: .reminder, title: "Sample — Weekly review",
            detail: "Reminder fired (notification). [Sample]", outcome: .info, at: ago(700)))
        out.append(ActivityEntry(kind: .skill, title: "Polish for LinkedIn",
            detail: "Rewrote a 90-word draft into a 60-word post. [Sample]", outcome: .success, at: ago(1500), durationMS: 1600))
        out.append(ActivityEntry(kind: .connector, title: "Knowledge (Demo)",
            detail: "Sample knowledge documents loaded for the Demo Mode walkthrough.", outcome: .info, at: ago(8000)))
        return out
    }

    // MARK: - CRM (clients + deal pipeline)
    static var crm: (clients: [Client], deals: [Deal]) {
        let harbor = UUID()
        let cedar = UUID()
        let riverstone = UUID()

        let clients = [
            Client(id: harbor, name: "Sample — Mira Chen", org: "Harborlight Studios (Demo)",
                   email: "mira.chen@example.com", phone: "555-0103",
                   notes: "Sample renewal account. Prefers concise monthly progress notes.", created: ago(1600), updated: ago(90)),
            Client(id: cedar, name: "Sample — Owen Patel", org: "Cedar & Vine Catering (Demo)",
                   email: "owen.patel@example.com", phone: "555-0108",
                   notes: "Sample new proposal. Asked for a Friday follow-up with implementation options.", created: ago(1400), updated: ago(130)),
            Client(id: riverstone, name: "Sample — Lena Ortiz", org: "Riverstone Logistics (Demo)",
                   email: "lena.ortiz@example.com", phone: "555-0112",
                   notes: "Sample vendor contact for hardware lead-time planning.", created: ago(1200), updated: ago(240)),
        ]

        var renewal = Deal(clientID: harbor, title: "Sample — Studio renewal", stage: .proposal,
                           value: 18000, nextAction: "Send revised scope by Thursday", created: ago(900), updated: ago(75))
        renewal.history = [
            StageChange(from: nil, to: .lead, at: ago(900), note: "Sample deal created in Demo Mode."),
            StageChange(from: .lead, to: .qualified, at: ago(720), note: "Budget and timing confirmed."),
            StageChange(from: .qualified, to: .proposal, at: ago(180), note: "Proposal sent for review."),
        ]

        var catering = Deal(clientID: cedar, title: "Sample — Catering launch package", stage: .qualified,
                            value: 7200, nextAction: "Prepare two launch options", created: ago(760), updated: ago(140))
        catering.history = [
            StageChange(from: nil, to: .lead, at: ago(760), note: "Sample inbound request."),
            StageChange(from: .lead, to: .qualified, at: ago(300), note: "Confirmed decision maker and timeline."),
        ]

        var hardware = Deal(clientID: riverstone, title: "Sample — Sensor procurement", stage: .won,
                            value: 4300, nextAction: "Track shipment date", created: ago(1100), updated: ago(260))
        hardware.history = [
            StageChange(from: nil, to: .lead, at: ago(1100), note: "Sample sourcing need."),
            StageChange(from: .lead, to: .qualified, at: ago(980), note: "Vendor fit confirmed."),
            StageChange(from: .qualified, to: .proposal, at: ago(820), note: "Quote received."),
            StageChange(from: .proposal, to: .won, at: ago(420), note: "Approved sample purchase order."),
        ]

        return (clients, [renewal, catering, hardware])
    }
}

// MARK: - MCP servers (Demo Mode) — clearly-labeled SAMPLE remote servers, never connected.
// These exist only so a reviewer can SEE the Integrations-via-MCP surface populated. They are
// in-memory only (never persisted), carry obviously-sample example.com URLs, and are NEVER dialed
// in Demo Mode (no network) — so the UI never fakes a "connected" state or a real tool result.
extension DemoSeed {
    static var mcpServers: [MCPServerConfig] {
        [
            MCPServerConfig(name: "Sample — Linear (MCP)", url: "https://mcp.example.com/linear"),
            MCPServerConfig(name: "Sample — Filesystem (MCP)", url: "https://mcp.example.com/fs"),
        ]
    }
    /// Sample tool catalogs keyed by the sample server name. Labeled as samples; not a live tools/list.
    static var mcpTools: [String: [MCPTool]] {
        [
            "Sample — Linear (MCP)": [
                MCPTool(server: "Sample — Linear (MCP)", name: "create_issue",
                        desc: "Create an issue in a project (SAMPLE — connect your own server to use).",
                        paramNames: ["title", "team"], requiredParams: ["title"]),
                MCPTool(server: "Sample — Linear (MCP)", name: "list_issues",
                        desc: "List issues assigned to you (SAMPLE).", paramNames: ["status"], requiredParams: []),
            ],
            "Sample — Filesystem (MCP)": [
                MCPTool(server: "Sample — Filesystem (MCP)", name: "read_file",
                        desc: "Read a text file the server is allowed to access (SAMPLE).",
                        paramNames: ["path"], requiredParams: ["path"]),
            ],
        ]
    }
}
#endif // circuit-convert
