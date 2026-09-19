//
//  AceLocalBrainOutputParser.swift
//  Ace
//
//  Pure parser for llama-cli's deterministic single-turn stdout framing.
//

import Foundation

nonisolated enum AceLocalBrainOutputParser {
    /// llama-cli's single-turn conversation mode terminates with `Exiting...`.
    /// Short prompts can still be echoed even with `--no-display-prompt`, while
    /// real multiline prompts are suppressed completely. Prefer the echoed
    /// prompt boundary when present; otherwise accept only the deterministic
    /// answer-plus-exit frame produced by Ace's no-display runtime arguments.
    static func answer(
        from standardOutput: String,
        echoedPrompt: String
    ) -> String {
        let promptMarker = "> \(echoedPrompt)\n\n"
        let promptRange = standardOutput.range(
            of: promptMarker,
            options: .backwards
        )
        let exitMarker = "\n\nExiting..."
        let exitRange = standardOutput.range(
            of: exitMarker,
            options: .backwards
        )
        let responseStart: String.Index
        if let promptRange {
            responseStart = promptRange.upperBound
        } else {
            guard exitRange != nil else { return "" }
            responseStart = standardOutput.startIndex
        }
        let responseEnd = exitRange?.lowerBound ?? standardOutput.endIndex
        guard responseStart <= responseEnd else { return "" }
        let response = standardOutput[responseStart..<responseEnd]
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Structured calls still use the same llama.cpp conversation shell. With
    /// a suppressed multiline prompt that shell can precede the generated JSON
    /// with local status text. Admit only one slice that Foundation proves is a
    /// complete top-level object; banners and partial objects stay out.
    static func structuredJSONObject(from response: String) -> String? {
        let starts = response.indices.filter { response[$0] == "{" }
        let ends = response.indices.filter { response[$0] == "}" }
        for start in starts {
            for end in ends.reversed() where start <= end {
                let candidate = String(response[start...end])
                guard let data = candidate.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(
                        with: data
                      ),
                      object is [String: Any] else {
                    continue
                }
                return candidate
            }
        }
        return nil
    }
}
