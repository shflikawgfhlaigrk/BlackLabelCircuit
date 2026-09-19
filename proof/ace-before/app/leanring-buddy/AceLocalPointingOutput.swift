//
//  AceLocalPointingOutput.swift
//  Ace
//
//  Converts grammar-constrained local-brain JSON into the one immutable
//  capture-bound point frame understood by Ace's existing screen target gate.
//

import Foundation

nonisolated enum AcePointingProviderEncoding: Equatable, Sendable {
    case taggedText
    case localJSON
}

nonisolated enum AcePointingProviderPolicy {
    static func encoding(
        for provider: BrainCLI
    ) -> AcePointingProviderEncoding {
        provider == .qwen ? .localJSON : .taggedText
    }
}

nonisolated enum AceLocalPointingOutput {
    static let systemContract = """
    For the local runtime, express the requested screen-point decision as the required JSON object. Put any short speakable comment in spoken_response. Set has_point true only when one exact OCR capture and display identity plus a clickable coordinate are supported. When has_point is false, use empty capture, display, and label strings with zero numeric values. Never invent or shorten a capture UUID or display ID.
    """

    private struct Envelope: Decodable {
        let spokenResponse: String
        let hasPoint: Bool
        let capture: String
        let display: String
        let x: Double
        let y: Double
        let confidence: Double
        let label: String

        enum CodingKeys: String, CodingKey {
            case spokenResponse = "spoken_response"
            case hasPoint = "has_point"
            case capture
            case display
            case x
            case y
            case confidence
            case label
        }
    }

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "spoken_response": ["type": "string"],
            "has_point": ["type": "boolean"],
            "capture": ["type": "string"],
            "display": ["type": "string"],
            "x": ["type": "number"],
            "y": ["type": "number"],
            "confidence": ["type": "number"],
            "label": ["type": "string"],
        ],
        "required": [
            "spoken_response",
            "has_point",
            "capture",
            "display",
            "x",
            "y",
            "confidence",
            "label",
        ],
        "additionalProperties": false,
    ]

    static func renderedResponse(
        from json: String,
        privateAnswer: Bool = false
    ) -> String? {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: data
              ) else {
            return nil
        }
        // Private answers have no spoken or visible label. An option's prose
        // must not invalidate otherwise valid capture-bound coordinates.
        let spoken = privateAnswer ? "" : envelope.spokenResponse.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !spoken.contains("[POINT:") else { return nil }

        if !envelope.hasPoint {
            return spoken.isEmpty
                ? "[POINT:none]"
                : "\(spoken) [POINT:none]"
        }

        guard let capture = UUID(uuidString: envelope.capture),
              let display = UInt32(envelope.display),
              envelope.x.isFinite,
              envelope.y.isFinite,
              envelope.confidence.isFinite,
              envelope.x >= 0,
              envelope.y >= 0,
              (0...1).contains(envelope.confidence) else {
            return nil
        }
        let label = privateAnswer ? "answer" : envelope.label.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let forbiddenLabelCharacters = CharacterSet(
            charactersIn: "[];\r\n"
        )
        guard !label.isEmpty,
              label.count <= 80,
              label.rangeOfCharacter(
                from: forbiddenLabelCharacters
              ) == nil else {
            return nil
        }

        let tag = "[POINT:capture="
            + capture.uuidString.lowercased()
            + ";display=\(display)"
            + ";x=\(envelope.x)"
            + ";y=\(envelope.y)"
            + ";confidence=\(envelope.confidence)"
            + ";label=\(label)]"
        return spoken.isEmpty ? tag : "\(spoken) \(tag)"
    }
}

/// Qwen receives semantic OCR choices, never capture identities or coordinate
/// syntax. App code maps its final numbered choice back to the immutable OCR
/// box. This keeps ordinary screen pointing reliable without trusting a text
/// model to copy UUIDs, display IDs, and eight JSON fields perfectly.
nonisolated enum AceLocalSemanticPointing {
    private struct Target {
        let capture: UUID
        let display: UInt32
        let label: String
        let centerX: Int
        let centerY: Int
    }

    static func semanticPrompt(
        systemPrompt: String,
        userPrompt: String,
        ocrContext: String,
        centerBandOnly: Bool
    ) -> String {
        let candidates = targets(
            from: ocrContext,
            centerBandOnly: centerBandOnly
        )
        let listedTargets = candidates.enumerated().map { index, target in
            "TARGET_\(index + 1): \(target.label)"
        }.joined(separator: "\n")
        let wantsReaction = systemPrompt
            .localizedCaseInsensitiveContains("react")
        return """
        Screen task: \(userPrompt)

        Visible OCR targets:
        \(listedTargets)

        Choose the one numbered target that best satisfies the screen task. Compare the visible labels before deciding. Do not invent another target. Return exactly two final lines and no coordinate data:
        COMMENT: \(wantsReaction ? "a dry lowercase reaction of at most six words" : "a concise lowercase description of the chosen target")
        FINAL_TARGET: <target number>
        """
    }

    static func renderedResponse(
        reasoning: String,
        ocrContext: String,
        centerBandOnly: Bool
    ) -> String? {
        let candidates = targets(
            from: ocrContext,
            centerBandOnly: centerBandOnly
        )
        guard let lastLine = reasoning
                .split(whereSeparator: \Character.isNewline)
                .map(String.init)
                .last(where: {
                    !$0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                }),
              let finalMatch = firstMatch(
                  pattern: #"(?i)^\s*FINAL_TARGET\s*:\s*([0-9]+)\s*$"#,
                  in: lastLine
              ),
              finalMatch.count > 1,
              let oneBasedIndex = Int(finalMatch[1]),
              candidates.indices.contains(oneBasedIndex - 1) else {
            return nil
        }
        let target = candidates[oneBasedIndex - 1]
        let commentLine = reasoning
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .last(where: {
                $0.range(
                    of: #"(?i)^\s*COMMENT\s*:"#,
                    options: .regularExpression
                ) != nil
            })
        let rawComment = commentLine?.replacingOccurrences(
            of: #"(?i)^\s*COMMENT\s*:\s*"#,
            with: "",
            options: .regularExpression
        ) ?? "found \(target.label)"
        let safeComment = sanitizedWords(rawComment, maximum: 6)
        let object: [String: Any] = [
            "spoken_response": safeComment,
            "has_point": true,
            "capture": target.capture.uuidString.lowercased(),
            "display": String(target.display),
            "x": Double(target.centerX),
            "y": Double(target.centerY),
            "confidence": 1.0,
            "label": target.label,
        ]
        guard let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return AceLocalPointingOutput.renderedResponse(from: json)
    }

    private static func targets(
        from ocrContext: String,
        centerBandOnly: Bool
    ) -> [Target] {
        ocrContext
            .components(separatedBy: "\n\n")
            .flatMap { screenBlock -> [Target] in
                guard let identity = firstMatch(
                          pattern: #"capture_id=([0-9A-Fa-f\-]{36})\s+display_id=([0-9]+)"#,
                          in: screenBlock
                      ),
                      identity.count > 2,
                      let capture = UUID(uuidString: identity[1]),
                      let display = UInt32(identity[2]),
                      let dimensions = firstMatch(
                          pattern: #"ocr coordinate space:\s*([0-9]+)x([0-9]+)\s+pixels"#,
                          in: screenBlock
                      ),
                      dimensions.count > 2,
                      let imageWidth = Int(dimensions[1]),
                      let imageHeight = Int(dimensions[2]) else {
                    return []
                }
                return screenBlock
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .compactMap { rawLine -> Target? in
                        let line = String(rawLine)
                        guard let text = decodedOCRText(from: line),
                              let center = firstMatch(
                                  pattern: #"center=\(x:([0-9]+),y:([0-9]+)\)"#,
                                  in: line
                              ),
                              center.count > 2,
                              let centerX = Int(center[1]),
                              let centerY = Int(center[2]) else {
                            return nil
                        }
                        if centerBandOnly {
                            guard Double(centerX) >= Double(imageWidth) * 0.2,
                                  Double(centerX) <= Double(imageWidth) * 0.8,
                                  Double(centerY) >= Double(imageHeight) * 0.2,
                                  Double(centerY) <= Double(imageHeight) * 0.8 else {
                                return nil
                            }
                        }
                        let label = sanitizedLabel(text)
                        guard !label.isEmpty else { return nil }
                        return Target(
                            capture: capture,
                            display: display,
                            label: label,
                            centerX: centerX,
                            centerY: centerY
                        )
                    }
            }
    }

    private static func sanitizedLabel(_ value: String) -> String {
        String(
            value
                .components(
                    separatedBy: CharacterSet(charactersIn: "[];\r\n")
                )
                .joined(separator: " ")
                .prefix(80)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedWords(
        _ value: String,
        maximum: Int
    ) -> String {
        let safe = value
            .components(
                separatedBy: CharacterSet(charactersIn: "[];\r\n")
            )
            .joined(separator: " ")
            .lowercased()
        return safe
            .split(whereSeparator: \Character.isWhitespace)
            .prefix(maximum)
            .joined(separator: " ")
    }

    private static func decodedOCRText(from line: String) -> String? {
        guard let match = firstMatch(
                  pattern: #"^text=(\"(?:\\.|[^\"])*\")\s+box="#,
                  in: line
              ),
              match.count > 1,
              let data = ("[" + match[1] + "]").data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String],
              let value = values.first else {
            return nil
        }
        return value
    }

    private static func firstMatch(
        pattern: String,
        in value: String
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ) else {
            return nil
        }
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }
}

/// Qwen is a text model: Vision supplies OCR, Qwen reasons about only the
/// question and options, and app code maps its explicit final option letter
/// back to one immutable OCR box. This prevents coordinate syntax or the
/// question box itself from competing with answer reasoning.
nonisolated enum AceLocalMultipleChoicePointing {
    private struct Option: Equatable {
        let letter: String
        let label: String
        let centerX: Int
        let centerY: Int
        let capture: UUID
        let display: UInt32
    }

    static func semanticPrompt(ocrContext: String) -> String {
        let visibleText = ocrContext
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { decodedOCRText(from: String($0)) }
        return """
        Visible screen text in reading order:
        \(visibleText.map { "- " + $0 }.joined(separator: "\n"))

        Clickable answer choices detected by Ace:
        \(identifiedOptions(from: ocrContext).map { "\($0.letter): \($0.label)" }.joined(separator: "\n"))

        Solve the one single-answer multiple-choice question shown above. Explain the governing fact, calculation, or logic; compare every option; then double-check the result. If the screen says select all, choose all, multiple answers, or does not show exactly one complete question, do not choose an option. End with exactly one final line in this form:
        FINAL_ANSWER: <option letter or number>
        """
    }

    static func renderedResponse(
        reasoning: String,
        ocrContext: String
    ) -> String? {
        guard !requiresMultipleSelections(ocrContext),
              let answerLetter = finalAnswerLetter(from: reasoning) else {
            return nil
        }
        let matches = identifiedOptions(from: ocrContext)
            .filter { $0.letter == answerLetter }
        guard matches.count == 1, let match = matches.first else {
            return nil
        }

        let safeLabel = String(
            match.label
                .components(separatedBy: CharacterSet(charactersIn: "[];\r\n"))
                .joined(separator: " ")
                .prefix(80)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeLabel.isEmpty else { return nil }
        let object: [String: Any] = [
            "spoken_response": "",
            "has_point": true,
            "capture": match.capture.uuidString.lowercased(),
            "display": String(match.display),
            "x": Double(match.centerX),
            "y": Double(match.centerY),
            "confidence": 1.0,
            "label": safeLabel,
        ]
        guard let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return AceLocalPointingOutput.renderedResponse(from: json)
    }

    private static func finalAnswerLetter(
        from reasoning: String
    ) -> String? {
        guard let lastLine = reasoning
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .last(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
            return nil
        }
        let normalized = lastLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        guard let match = firstMatch(
            pattern: #"(?i)^FINAL_ANSWER\s*:\s*([A-Z]|(?:[1-9]|1[0-9]|2[0-6]))(?:\b|\s*[\.\)\:\-])"#,
            in: normalized
        ),
        match.count > 1,
        let identifier = normalizedOptionIdentifier(match[1]) else {
            return nil
        }
        return identifier
    }

    private static func requiresMultipleSelections(
        _ ocrContext: String
    ) -> Bool {
        ocrContext.range(
            of: #"(?i)\b(?:select|choose|check)\s+all(?:\s+that\s+apply)?\b|\ball\s+that\s+apply\b|\b(?:select|choose|check)\s+(?:exactly\s+)?(?:two|three|four|2|3|4)\s+(?:answers?|options?|responses?|choices?)\b|\b(?:select|choose|check)\s+(?:each|every)\s+correct\s+(?:answer|option|response|choice)\b|\bmultiple\s+(?:answers|responses|selections)\b|\b(?:two|three|four|2|3|4)\s+correct\s+(?:answers?|options?|responses?|choices?)\b|\bmore\s+than\s+one\s+(?:answer|option)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func identifiedOptions(
        from ocrContext: String
    ) -> [Option] {
        ocrContext.components(separatedBy: "\n\n")
            .flatMap { block -> [Option] in
                guard let identity = firstMatch(
                    pattern: #"capture_id=([0-9A-Fa-f\-]{36})\s+display_id=([0-9]+)"#,
                    in: block
                ), identity.count > 2,
                let capture = UUID(uuidString: identity[1]),
                let display = UInt32(identity[2]) else {
                    return []
                }
                let lines = block.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).map(String.init)
                let labeled = lines.compactMap {
                    option(
                        from: $0,
                        capture: capture,
                        display: display
                    )
                }
                if !labeled.isEmpty { return labeled }

                // True/False questions commonly omit A/B prefixes. Accept
                // only one exact pair in one capture; unrelated page text or
                // multiple screens therefore cannot become a click target.
                let binary = lines.compactMap { line -> Option? in
                    guard let text = decodedOCRText(from: line),
                          let centerMatch = firstMatch(
                              pattern: #"center=\(x:([0-9]+),y:([0-9]+)\)"#,
                              in: line
                          ), centerMatch.count > 2,
                          let centerX = Int(centerMatch[1]),
                          let centerY = Int(centerMatch[2]) else {
                        return nil
                    }
                    let normalized = text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).lowercased()
                    guard normalized == "true" || normalized == "false"
                    else { return nil }
                    return Option(
                        letter: normalized == "true" ? "A" : "B",
                        label: text,
                        centerX: centerX,
                        centerY: centerY,
                        capture: capture,
                        display: display
                    )
                }
                guard binary.count == 2,
                      Set(binary.map { $0.label.lowercased() })
                        == Set(["true", "false"]) else { return [] }
                return binary
            }
    }

    private static func option(
        from line: String,
        capture: UUID,
        display: UInt32
    ) -> Option? {
        guard let text = decodedOCRText(from: line) else {
            return nil
        }
        // Vision preserves common prefixes such as "Option H" and usually
        // normalizes typographic dashes to a plain hyphen. Accept the ordinary
        // label forms users encounter while still requiring either an explicit
        // prefix or delimiter; bare menu text such as "A 71°F" must never be
        // mistaken for a clickable answer.
        let labelPatterns = [
            #"(?i)^\s*(?:(?:option|choice|answer)\s+)?(?:[\(\[]\s*)?([A-Z]|(?:[1-9]|1[0-9]|2[0-6]))\s*(?:[\)\]]|[\.\:\-–—])\s*(\S.*)$"#,
            #"(?i)^\s*(?:option|choice|answer)\s+(?:[\(\[]\s*)?([A-Z]|(?:[1-9]|1[0-9]|2[0-6]))(?:\s*[\)\]])?\s+(\S.*)$"#,
        ]
        guard let optionMatch = labelPatterns.compactMap({ pattern in
                  firstMatch(pattern: pattern, in: text)
              }).first,
              optionMatch.count > 2,
              let identifier = normalizedOptionIdentifier(optionMatch[1]),
              let centerMatch = firstMatch(
                  pattern: #"center=\(x:([0-9]+),y:([0-9]+)\)"#,
                  in: line
              ),
              centerMatch.count > 2,
              let centerX = Int(centerMatch[1]),
              let centerY = Int(centerMatch[2]) else {
            return nil
        }
        return Option(
            letter: identifier,
            label: text,
            centerX: centerX,
            centerY: centerY,
            capture: capture,
            display: display
        )
    }

    private static func normalizedOptionIdentifier(
        _ rawValue: String
    ) -> String? {
        let value = rawValue.uppercased()
        if value.count == 1,
           let scalar = value.unicodeScalars.first,
           (UnicodeScalar("A").value...UnicodeScalar("Z").value)
                .contains(scalar.value) {
            return value
        }
        guard let ordinal = Int(value), (1...26).contains(ordinal),
              let scalar = UnicodeScalar(
                  UnicodeScalar("A").value + UInt32(ordinal - 1)
              ) else {
            return nil
        }
        return String(Character(scalar))
    }

    private static func decodedOCRText(from line: String) -> String? {
        guard let match = firstMatch(
                  pattern: #"^text=(\"(?:\\.|[^\"])*\")\s+box="#,
                  in: line
              ),
              match.count > 1,
              let data = ("[" + match[1] + "]").data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String],
              let value = values.first else {
            return nil
        }
        return value
    }

    private static func firstMatch(
        pattern: String,
        in value: String
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ) else {
            return nil
        }
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }
}
