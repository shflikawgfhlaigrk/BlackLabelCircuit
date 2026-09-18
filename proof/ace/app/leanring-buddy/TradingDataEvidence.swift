//
//  TradingDataEvidence.swift
//  Ace
//
//  A market value is displayable only when the response echoes one immutable
//  capture identity. Source and timestamp come from native capture state, not
//  from model text.
//

import Foundation

struct TradingCaptureContext: Equatable, Sendable {
    let generation: UUID
    let displayID: UInt32
    let source: String
    let capturedAt: Date
}

struct TradingDataEvidence: Equatable, Sendable {
    let symbol: String
    let timeframe: String
    let source: String
    let capturedAt: Date
    let values: String
}

enum TradingDataStatus: Equatable, Sendable {
    case inactive
    case unavailable(reason: String)
    case available(TradingDataEvidence)
}

enum TradingDataEvidenceDecoding: Equatable, Sendable {
    case available(spokenText: String, TradingDataEvidence)
    case unavailable(spokenText: String)
    case rejected(spokenText: String, reason: String)
}

enum TradingDataEvidenceDecoder {
    private static let availablePattern =
        #"\[TRADING:status=available;capture=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12});display=([0-9]+);symbol=([A-Za-z0-9.\-\/]{1,16});timeframe=([A-Za-z0-9.\-]{1,16});values=([^\]\r\n]{1,240})\]"#
    private static let unavailablePattern =
        #"\[TRADING:status=unavailable\]"#

    static func decode(
        _ response: String,
        captures: [TradingCaptureContext]
    ) -> TradingDataEvidenceDecoding {
        if let unavailable = firstMatch(
            unavailablePattern,
            in: response
        ), let range = Range(unavailable.range, in: response) {
            var spoken = response
            spoken.removeSubrange(range)
            return .unavailable(spokenText: spoken)
        }

        guard let match = firstMatch(availablePattern, in: response),
              let range = Range(match.range, in: response),
              let generationText = capture(1, match, response),
              let generation = UUID(uuidString: generationText),
              let displayText = capture(2, match, response),
              let displayID = UInt32(displayText),
              let symbol = capture(3, match, response),
              let timeframe = capture(4, match, response),
              let values = capture(5, match, response)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .rejected(
                spokenText: response,
                reason:
                    "No current capture-bound chart source, symbol, timeframe, and model-read values were supplied."
            )
        }
        let matches = captures.filter {
            $0.generation == generation && $0.displayID == displayID
        }
        guard matches.count == 1, let context = matches.first else {
            return .rejected(
                spokenText: response,
                reason: "Trading evidence referenced a stale or unknown capture."
            )
        }
        var spoken = response
        spoken.removeSubrange(range)
        return .available(
            spokenText: spoken,
            TradingDataEvidence(
                symbol: symbol,
                timeframe: timeframe,
                source: context.source,
                capturedAt: context.capturedAt,
                values: values
            )
        )
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else { return nil }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }

    private static func capture(
        _ index: Int,
        _ match: NSTextCheckingResult,
        _ value: String
    ) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: value) else {
            return nil
        }
        return String(value[range])
    }
}
