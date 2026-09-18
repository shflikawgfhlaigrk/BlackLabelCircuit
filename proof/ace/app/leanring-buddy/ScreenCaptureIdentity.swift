import Foundation

struct ScreenCaptureIdentity: Codable, Equatable, Sendable {
    let generation: UUID
    let displayID: UInt32
    let originXPoints: Double
    let originYPoints: Double
    let widthPoints: Double
    let heightPoints: Double
    let widthPixels: Int
    let heightPixels: Int
    let scale: Double
    let imageSHA256: String

    var promptLabel: String {
        "capture_id=\(generation.uuidString.lowercased()) "
            + "display_id=\(displayID) "
            + "image=\(widthPixels)x\(heightPixels)px "
            + "display=\(Int(widthPoints))x\(Int(heightPoints))pt "
            + "scale=\(String(format: "%.3f", scale))"
    }
}

struct PointTarget: Equatable, Sendable {
    let capture: ScreenCaptureIdentity
    let imageX: Double
    let imageY: Double
    let confidence: Double
    let label: String

    var appKitX: Double {
        capture.originXPoints
            + imageX * capture.widthPoints
                / Double(capture.widthPixels)
    }

    var appKitY: Double {
        capture.originYPoints
            + capture.heightPoints
            - imageY * capture.heightPoints
                / Double(capture.heightPixels)
    }
}

enum PointTargetDecoding: Equatable, Sendable {
    case target(spokenText: String, PointTarget)
    case none(spokenText: String)
    case rejected(spokenText: String, reason: String)
}

enum PointTargetDecoder {
    static let minimumConfidence = 0.70

    private static let targetPattern =
        #"\[POINT:capture=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12});display=([0-9]+);x=([0-9]+(?:\.[0-9]+)?);y=([0-9]+(?:\.[0-9]+)?);confidence=(0(?:\.[0-9]+)?|1(?:\.0+)?);label=([^\]\r\n]{1,80})\]\s*$"#
    private static let nonePattern = #"\[POINT:none\]\s*$"#

    /// Removes any [POINT:…] remnant — malformed, legacy-form, or truncated —
    /// so a rejected decode never returns tag fragments as speakable text.
    private static func strippingPointTagRemnants(
        from response: String
    ) -> String {
        response
            .replacingOccurrences(
                of: #"\[POINT:[^\]\r\n]*\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[POINT:[^\r\n]*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(
        _ response: String,
        captures: [ScreenCaptureIdentity]
    ) -> PointTargetDecoding {
        if let none = firstMatch(nonePattern, in: response),
           let range = Range(none.range, in: response) {
            return .none(
                spokenText: String(response[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let match = firstMatch(targetPattern, in: response),
              let tagRange = Range(match.range, in: response) else {
            // Every other branch slices the tag off. A malformed tag (bad
            // label, legacy form, truncated frame) must not leak raw
            // "[POINT:…" fragments into the spoken text, the conversation
            // history, and the transcript.
            return .rejected(
                spokenText: strippingPointTagRemnants(from: response),
                reason: "Missing immutable capture or display identity."
            )
        }
        let spokenText = String(response[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let generationText = capture(1, match, response),
              let generation = UUID(uuidString: generationText),
              let displayText = capture(2, match, response),
              let displayID = UInt32(displayText),
              let xText = capture(3, match, response),
              let x = Double(xText),
              let yText = capture(4, match, response),
              let y = Double(yText),
              let confidenceText = capture(5, match, response),
              let confidence = Double(confidenceText),
              let label = capture(6, match, response)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return .rejected(
                spokenText: spokenText,
                reason: "Malformed point response."
            )
        }
        guard confidence >= minimumConfidence else {
            return .rejected(
                spokenText: spokenText,
                reason: "Point confidence was too low."
            )
        }
        let matches = captures.filter {
            $0.generation == generation
                && $0.displayID == displayID
        }
        guard matches.count == 1,
              let identity = matches.first else {
            return .rejected(
                spokenText: spokenText,
                reason: "The point did not match one current display capture."
            )
        }
        guard identity.widthPixels > 0,
              identity.heightPixels > 0,
              identity.widthPoints > 0,
              identity.heightPoints > 0,
              x >= 0,
              y >= 0,
              x < Double(identity.widthPixels),
              y < Double(identity.heightPixels) else {
            return .rejected(
                spokenText: spokenText,
                reason: "Point coordinates were outside the bound capture."
            )
        }
        return .target(
            spokenText: spokenText,
            PointTarget(
                capture: identity,
                imageX: x,
                imageY: y,
                confidence: confidence,
                label: label
            )
        )
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }
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
