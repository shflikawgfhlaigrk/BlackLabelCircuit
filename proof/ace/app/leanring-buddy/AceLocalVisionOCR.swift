//
//  AceLocalVisionOCR.swift
//  Ace
//
//  Qwen3 30B-A3B is a text model. Ace keeps screenshot understanding fully
//  on-device by using Apple's Vision framework to turn each private capture
//  into bounded text plus exact image-space coordinates. The capture bytes are
//  never written by this bridge and no network transport exists here.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(ImageIO) && !CIRCUIT_WINDOWS_SIM
import ImageIO
#endif
#if canImport(Vision) && !CIRCUIT_WINDOWS_SIM
import Vision
#endif

nonisolated enum AceLocalVisionOCRError: LocalizedError {
    case invalidImage(label: String)
    case recognitionFailed(label: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let label):
            return "Ace could not decode the private screen image: \(label)"
        case .recognitionFailed(let label):
            return "Ace could not read text from the private screen image: \(label)"
        }
    }
}

nonisolated struct AceLocalOCRBox: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var centerX: Int { x + width / 2 }
    var centerY: Int { y + height / 2 }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum AceLocalVisionOCR {
    /// Converts Vision's bottom-left normalized box into the top-left pixel
    /// coordinate space used by Ace's [POINT:...] contract.
    static func pixelBox(
        normalizedBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> AceLocalOCRBox {
        let width = max(1, Int((normalizedBox.width * CGFloat(imageWidth)).rounded()))
        let height = max(1, Int((normalizedBox.height * CGFloat(imageHeight)).rounded()))
        let x = max(0, Int((normalizedBox.minX * CGFloat(imageWidth)).rounded()))
        let y = max(
            0,
            Int(((1 - normalizedBox.maxY) * CGFloat(imageHeight)).rounded())
        )
        return AceLocalOCRBox(
            x: min(x, max(0, imageWidth - 1)),
            y: min(y, max(0, imageHeight - 1)),
            width: min(width, max(1, imageWidth - x)),
            height: min(height, max(1, imageHeight - y))
        )
    }

    static func promptContext(
        images: [(data: Data, label: String)]
    ) async throws -> String {
        guard !images.isEmpty else { return "" }
        return try await Task.detached(priority: .userInitiated) {
            try images.enumerated().map { index, image in
                try context(for: image, index: index)
            }.joined(separator: "\n\n")
        }.value
    }

    private static func context(
        for image: (data: Data, label: String),
        index: Int
    ) throws -> String {
        guard let source = CGImageSourceCreateWithData(
                  image.data as CFData,
                  nil
              ),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AceLocalVisionOCRError.invalidImage(label: image.label)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:])
                .perform([request])
        } catch {
            throw AceLocalVisionOCRError.recognitionFailed(
                label: image.label
            )
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.005 {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var lines = [
            "screen\(index + 1): \(image.label)",
            "ocr coordinate space: \(cgImage.width)x\(cgImage.height) pixels; origin is top-left",
        ]
        for observation in observations.prefix(300) {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let text = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = pixelBox(
                normalizedBox: observation.boundingBox,
                imageWidth: cgImage.width,
                imageHeight: cgImage.height
            )
            lines.append(
                "text=\(quoted(text)) box=(x:\(box.x),y:\(box.y),w:\(box.width),h:\(box.height)) center=(x:\(box.centerX),y:\(box.centerY))"
            )
        }
        if observations.isEmpty {
            lines.append("no text recognized")
        }
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: [value],
                  options: [.withoutEscapingSlashes]
              ),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}
#endif // circuit-convert
