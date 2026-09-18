#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AccessibilityVisualTargetResolver.swift
//  Ace
//
//  Resolves an explicitly named visible control from the frontmost app's
//  accessibility tree. Exact, unique labels avoid a model round trip; an
//  absent or ambiguous result falls back to the capture-bound visual path.
//

#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation

struct AccessibilityVisualTargetCandidate: Equatable, Sendable {
    let point: CGPoint
    let role: String?
    let title: String?
    let value: String?
    let description: String?
    let help: String?
    let identifier: String?
    let isEnabled: Bool
}

enum AccessibilityVisualTargetResolution: Equatable, Sendable {
    case unique(CGPoint)
    case ambiguous
    case missing
}

enum AccessibilityVisualTargetGeometry {
    static func anchorPoint(
        in bounds: CGRect,
        textFrames: [CGRect]? = nil
    ) -> CGPoint? {
        guard isValid(bounds) else { return nil }
        guard let textFrames else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // Web headings often span the entire column. Their text descendants
        // locate the words instead of the whitespace beside those words.
        let visibleText = textFrames.filter { frame in
            isValid(frame)
                && bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }.sorted { left, right in
            let leftArea = left.width * left.height
            let rightArea = right.width * right.height
            if leftArea != rightArea { return leftArea > rightArea }
            if left.minY != right.minY { return left.minY < right.minY }
            return left.minX < right.minX
        }
        guard let text = visibleText.first else { return nil }
        return CGPoint(x: text.midX, y: text.midY)
    }

    private static func isValid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite
            && bounds.maxX.isFinite && bounds.maxY.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 1 && bounds.height > 1
    }
}

enum AccessibilityVisualTargetMatcher {
    private static let roleWords: Set<String> = [
        "the", "a", "an", "button", "link", "control", "item",
        "menu", "tab", "option", "checkbox", "radio", "field",
    ]

    static func uniquePoint(
        for targetDescription: String,
        candidates: [AccessibilityVisualTargetCandidate]
    ) -> CGPoint? {
        guard case .unique(let point) = resolution(
            for: targetDescription,
            candidates: candidates
        ) else {
            return nil
        }
        return point
    }

    static func resolution(
        for targetDescription: String,
        candidates: [AccessibilityVisualTargetCandidate]
    ) -> AccessibilityVisualTargetResolution {
        let query = normalizedWords(targetDescription)
            .filter { !roleWords.contains($0) }
        guard !query.isEmpty else { return .missing }
        if query == ["heading"] {
            let headings = candidates.filter {
                $0.isEnabled && $0.role == "AXHeading"
            }
            if headings.count > 1 { return .ambiguous }
            if let heading = headings.first {
                return .unique(heading.point)
            }
        }

        let scored = candidates.compactMap { candidate -> (CGPoint, Int)? in
            guard candidate.isEnabled else { return nil }
            let fields: [(String?, Int)] = [
                (candidate.title, 6),
                (candidate.identifier, 5),
                (candidate.description, 4),
                (candidate.help, 3),
                (candidate.value, 2),
            ]
            let score = fields.compactMap { value, priority in
                value.flatMap {
                    matchScore(
                        query: query,
                        candidate: normalizedWords($0),
                        priority: priority
                    )
                }
            }.max() ?? 0
            return score > 0 ? (candidate.point, score) : nil
        }.sorted { lhs, rhs in lhs.1 > rhs.1 }

        guard let best = scored.first else { return .missing }
        if scored.dropFirst().first?.1 == best.1 {
            return .ambiguous
        }
        return .unique(best.0)
    }

    private static func matchScore(
        query: [String],
        candidate: [String],
        priority: Int
    ) -> Int? {
        guard !candidate.isEmpty else { return nil }
        if candidate == query {
            return 100 + priority
        }
        if candidate.count >= query.count,
           candidate.windows(ofCount: query.count).contains(query) {
            return 80 + priority
        }
        let querySet = Set(query)
        let candidateSet = Set(candidate)
        if querySet.isSubset(of: candidateSet) {
            return 70 + priority
        }
        return nil
    }

    private static func normalizedWords(_ value: String) -> [String] {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalizedScalars = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar)
                ? String(scalar)
                : " "
        }.joined()
        return normalizedScalars
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private extension Array where Element: Equatable {
    func windows(ofCount count: Int) -> [[Element]] {
        guard count > 0, self.count >= count else { return [] }
        return (0...(self.count - count)).map {
            Array(self[$0..<($0 + count)])
        }
    }
}

enum PointingApplicationSelectionPolicy {
    static func processIdentifier(
        frontmost: Int32?, own: Int32, panelIsVisible: Bool,
        externalBeforePanel: Int32?
    ) -> Int32? {
        guard let frontmost, frontmost > 0 else { return nil }
        if frontmost != own { return frontmost }
        guard panelIsVisible, let externalBeforePanel,
              externalBeforePanel > 0, externalBeforePanel != own else {
            return nil
        }
        return externalBeforePanel
    }
}

@MainActor
enum AccessibilityVisualTargetResolver {
    private static let maximumVisitedElements = 3_000
    private static let maximumDepth = 24
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    static func uniquePoint(for targetDescription: String) -> CGPoint? {
        guard case .unique(let point) = resolution(
            for: targetDescription
        ) else {
            return nil
        }
        return point
    }

    static func resolution(
        for targetDescription: String,
        includesReadOnlyContent: Bool = false,
        applicationProcessIdentifier: pid_t? = nil
    ) -> AccessibilityVisualTargetResolution {
        guard let processIdentifier = applicationProcessIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              processIdentifier > 0 else {
            return .missing
        }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let root = copyElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: app
        ) ?? app
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var nextIndex = 0
        var visited: Set<CFHashCode> = []
        var candidates: [AccessibilityVisualTargetCandidate] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        let asksForHeading = includesReadOnlyContent
            && targetDescription.range(of: #"(?i)\bheading\b"#, options: .regularExpression) != nil
        let query = includesReadOnlyContent
            ? targetDescription.replacingOccurrences(of: #"(?i)^(?:large|big|small)\s+|\s+(?:heading|text|label)$"#,
                with: "", options: .regularExpression)
            : targetDescription

        while nextIndex < queue.count,
              visited.count < maximumVisitedElements {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .missing }
            let (element, depth) = queue[nextIndex]
            nextIndex += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }

            let role = copyStringAttribute(
                kAXRoleAttribute as CFString,
                from: element
            )
            let isReadableContent = includesReadOnlyContent
                && (asksForHeading ? role == "AXHeading" : ["AXHeading", "AXStaticText"].contains(role ?? ""))
            if (isReadableContent || (!asksForHeading
                    && (actionNames(of: element).contains(kAXPressAction as String)
                        || role.map(editableRoles.contains) == true))),
               let point = centerPoint(
                   of: element,
                   preferTextContent: isReadableContent && role == "AXHeading",
                   deadline: deadline
               ) {
                candidates.append(
                    AccessibilityVisualTargetCandidate(
                        point: point,
                        role: role,
                        title: copyStringAttribute(
                            kAXTitleAttribute as CFString,
                            from: element
                        ),
                        value: copyStringAttribute(
                            kAXValueAttribute as CFString,
                            from: element
                        ),
                        description: copyStringAttribute(
                            kAXDescriptionAttribute as CFString,
                            from: element
                        ),
                        help: copyStringAttribute(
                            kAXHelpAttribute as CFString,
                            from: element
                        ),
                        identifier: copyStringAttribute(
                            "AXIdentifier" as CFString,
                            from: element
                        ),
                        isEnabled: copyBoolAttribute(
                            kAXEnabledAttribute as CFString,
                            from: element
                        ) ?? true
                    )
                )
            }

            guard depth < maximumDepth else { continue }
            for child in copyElementArrayAttribute(
                kAXChildrenAttribute as CFString,
                from: element
            ) {
                queue.append((child, depth + 1))
            }
        }

        guard nextIndex == queue.count else { return .missing }
        return AccessibilityVisualTargetMatcher.resolution(
            for: query,
            candidates: candidates
        )
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private static func centerPoint(
        of element: AXUIElement,
        preferTextContent: Bool = false,
        deadline: TimeInterval
    ) -> CGPoint? {
        guard let bounds = frame(of: element) else { return nil }
        let textFrames = preferTextContent
            ? readableTextFrames(in: element, deadline: deadline) : nil
        return AccessibilityVisualTargetGeometry.anchorPoint(
            in: bounds, textFrames: textFrames
        )
    }

    private static func readableTextFrames(
        in element: AXUIElement, deadline: TimeInterval
    ) -> [CGRect] {
        var queue = copyElementArrayAttribute(
            kAXChildrenAttribute as CFString, from: element
        ).map { ($0, 1) }
        var nextIndex = 0
        var result: [CGRect] = []
        while nextIndex < queue.count, nextIndex < 64 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            let (child, depth) = queue[nextIndex]
            nextIndex += 1
            guard copyBoolAttribute("AXHidden" as CFString, from: child) != true,
                  copyBoolAttribute(kAXEnabledAttribute as CFString, from: child) != false
            else { continue }
            if copyStringAttribute(kAXRoleAttribute as CFString, from: child) == "AXStaticText",
               let text = copyStringAttribute(kAXValueAttribute as CFString, from: child)
                    ?? copyStringAttribute(kAXTitleAttribute as CFString, from: child),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let textFrame = frame(of: child) {
                result.append(textFrame)
            }
            let children = copyElementArrayAttribute(
                kAXChildrenAttribute as CFString, from: child
            )
            guard depth < 4 else {
                if !children.isEmpty { return [] }
                continue
            }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        guard nextIndex == queue.count else { return [] }
        return result
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func copyStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyBoolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func copyElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyElementArrayAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }
}
#endif // circuit-convert
