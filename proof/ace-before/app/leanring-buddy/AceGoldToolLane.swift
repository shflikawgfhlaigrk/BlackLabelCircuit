import Foundation

/// The gold tool lane: instead of asking the model to hand-format the gold
/// envelope in free text (the 2026-08-12 snag class — finished answers
/// discarded over formatting wobble), the Claude brain is given exactly three
/// typed decisions and the runtime enforces their schemas. Ace's own binary is the
/// MCP stdio server (`--ace-gold-tool-server`), so nothing new ships in the
/// bundle and the buyer posture is unchanged: buyer's own CLI login, no API
/// keys, no network surface beyond the brain call that already exists.
///
/// Authority note: the server only ACKs tool calls. The app reads the typed
/// calls back out of the CLI's stream-json stdout and translates them into the
/// same GoldTurnResponse the envelope decoder admits. The app still binds an
/// execute decision to the admitted owner request before Red may claim it.
nonisolated enum AceGoldToolServer {
    static let launchFlag = "--ace-gold-tool-server"
    static let replyToolName = "reply"
    static let clarifyToolName = "clarify"
    static let executeToolName = "execute_objective"
    static let foregroundToolName = "open_on_screen"

    /// Runs the stdio JSON-RPC loop and never returns. Called before any
    /// SwiftUI/AppKit state exists: this process is a plain headless child of
    /// the brain CLI, so no status item, delegate, lifecycle receipt, or
    /// single-instance behavior may activate.
    static func runForever() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let response = response(forRequestLine: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
        exit(0)
    }

    /// Pure JSON-RPC core, split from the IO loop so the battery can prove the
    /// protocol without a process. Returns nil for notifications and noise.
    static func response(forRequestLine line: String) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any],
            let method = object["method"] as? String,
            let identifier = object["id"]
        else { return nil }

        let result: [String: Any]
        switch method {
        case "initialize":
            let parameters = object["params"] as? [String: Any]
            result = [
                "protocolVersion":
                    parameters?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "ace", "version": "1.0"],
            ]
        case "tools/list":
            result = [
                "tools": [
                    [
                        "name": replyToolName,
                        "description":
                            "Return the final spoken answer to the owner. "
                            + "Call exactly once with the complete natural "
                            + "answer, including the point tag.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string", "maxLength": 4000]
                            ],
                            "required": ["text"],
                            "additionalProperties": false,
                        ],
                    ],
                    [
                        "name": clarifyToolName,
                        "description":
                            "Ask the owner one short question only when a "
                            + "required value cannot be bound from the request.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string", "maxLength": 4000]
                            ],
                            "required": ["text"],
                            "additionalProperties": false,
                        ],
                    ],
                    [
                        "name": foregroundToolName,
                        "description":
                            "Open or bring forward the requested installed app or website on the owner's screen. "
                            + "Resolve the destination from the current request and recent conversation, including it/that follow-ups. "
                            + "Choose application for an installed app and website for an exact HTTP(S) URL. "
                            + "Ace performs the visible action and verifies it; do not claim it already opened.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "destination": ["type": "string", "enum": ["application", "website"]],
                                "target": ["type": "string", "maxLength": 2048],
                            ],
                            "required": ["destination", "target"],
                            "additionalProperties": false,
                        ],
                    ],
                    [
                        "name": executeToolName,
                        "description":
                            "Send background work using APIs or files to Red. Use open_on_screen for visible app or website navigation. Never provide commands, paths, "
                            + "identities, approvals, environment, or work IDs.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "objective": [
                                    "type": "string",
                                    "maxLength": 1200,
                                ],
                            ],
                            "required": ["objective"],
                            "additionalProperties": false,
                        ],
                    ],
                ]
            ]
        case "tools/call":
            // ACK only: the app consumes the typed call from the CLI event
            // stream; the server is never an authority or delivery channel.
            // Claude otherwise interprets a bare "ok" as an invitation to
            // call reply after execute and falsely announce that work ran.
            result = [
                "content": [[
                    "type": "text",
                    "text":
                        "Decision recorded. Stop now. Do not call another tool or report completion.",
                ]]
            ]
        default:
            result = [:]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": identifier,
                "result": result,
            ])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Translates a gold tool-lane transcript (the CLI's stream-json stdout) into
/// the exact envelope text the gold decoder admits. Typed tool calls win; a
/// turn with no typed call falls back to the model's free text, which the
/// decoder's salvage already guards — the lane can only add reliability,
/// never remove an answer that today's path would have delivered.
nonisolated enum GoldToolEventTranslation {
    static func envelopeText(fromStreamJSON transcript: String) -> String? {
        var typedResponse: GoldTurnResponse?
        var resultText: String?
        var assistantText = ""

        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let event = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any]
            else { continue }
            switch event["type"] as? String {
            case "assistant":
                let blocks = (event["message"] as? [String: Any])?["content"]
                    as? [[String: Any]] ?? []
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_use":
                        let input = block["input"] as? [String: Any]
                        switch block["name"] as? String {
                        case "mcp__ace__\(AceGoldToolServer.foregroundToolName)":
                            if let input,
                               Set(input.keys) == ["destination", "target"],
                               let data = try? JSONSerialization.data(withJSONObject: input),
                               let action = try? JSONDecoder().decode(GoldForegroundAction.self, from: data),
                               action.isValid, typedResponse == nil {
                                typedResponse = GoldTurnResponse(
                                    kind: .foreground, spokenResponse: "", objective: nil,
                                    foregroundAction: action
                                )
                            }
                        case "mcp__ace__\(AceGoldToolServer.replyToolName)":
                            if let text = input?["text"] as? String,
                               !text.trimmingCharacters(
                                   in: .whitespacesAndNewlines
                               ).isEmpty {
                                if typedResponse == nil {
                                    typedResponse =
                                    GoldTurnResponse(
                                        kind: .reply,
                                        spokenResponse: text,
                                        objective: nil
                                    )
                                }
                            }
                        case "mcp__ace__\(AceGoldToolServer.clarifyToolName)":
                            if let text = input?["text"] as? String,
                               !text.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                               ).isEmpty {
                                if typedResponse == nil {
                                    typedResponse =
                                    GoldTurnResponse(
                                        kind: .clarify,
                                        spokenResponse: text,
                                        objective: nil
                                    )
                                }
                            }
                        case "mcp__ace__\(AceGoldToolServer.executeToolName)":
                            if let objective = input?["objective"]
                                as? String,
                               !objective.trimmingCharacters(
                                in: .whitespacesAndNewlines
                               ).isEmpty,
                               objective.count <= 1_200 {
                                if typedResponse == nil {
                                    typedResponse =
                                    GoldTurnResponse(
                                        kind: .execute,
                                        spokenResponse: "",
                                        objective: objective
                                    )
                                }
                            }
                        default:
                            break
                        }
                    case "text":
                        assistantText += (block["text"] as? String) ?? ""
                    default:
                        break
                    }
                }
            case "result":
                resultText = event["result"] as? String
            default:
                break
            }
        }

        guard let response = typedResponse else {
            // No typed call: hand back the free text for the decoder's
            // salvage, exactly as the pre-tool lane behaved.
            let fallback = resultText ?? assistantText
            return fallback.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : fallback
        }
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
