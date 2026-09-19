import Foundation

nonisolated enum PartnerMemoryReducerError: Error, Equatable {
    case tooManyMutations
    case invalidStableKey
    case invalidContent
    case invalidConfidence
    case missingRecordForCorrection
    case secretShapedContent
    case receiptCannotBeUndone
}

nonisolated struct PartnerMemoryReducer {
    private static let maximumMutationsPerTurn = 12
    private static let maximumStableKeyCharacters = 160
    private static let maximumContentCharacters = 2_000

    static func applying(
        _ mutations: [PartnerMemoryMutation],
        to profile: PartnerProfile,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        timestamp: Date
    ) throws -> PartnerMemoryReduction {
        guard mutations.count <= maximumMutationsPerTurn else {
            throw PartnerMemoryReducerError.tooManyMutations
        }

        for mutation in mutations {
            try validate(mutation)
        }

        let profileBeforeChanges = profile
        var updatedProfile = profile
        var visibleChanges: [String] = []

        for mutation in mutations {
            let matchingRecordIndex =
                updatedProfile.memoryRecords.firstIndex {
                    $0.stableKey == mutation.stableKey
                }

            switch mutation.operation {
            case .upsert:
                if let matchingRecordIndex {
                    let existingRecord =
                        updatedProfile.memoryRecords[matchingRecordIndex]
                    if existingRecord.normalizedContent
                        == mutation.normalizedContent {
                        continue
                    }

                    if existingRecord.confirmationState == .confirmed,
                       mutation.confirmationState != .confirmed {
                        appendContradiction(
                            mutation: mutation,
                            existingRecord: existingRecord,
                            sourceSessionIdentifier:
                                sourceSessionIdentifier,
                            sourceTurnIdentifier:
                                sourceTurnIdentifier,
                            timestamp: timestamp,
                            profile: &updatedProfile,
                            visibleChanges: &visibleChanges
                        )
                        continue
                    }

                    replaceRecord(
                        at: matchingRecordIndex,
                        mutation: mutation,
                        sourceSessionIdentifier:
                            sourceSessionIdentifier,
                        sourceTurnIdentifier:
                            sourceTurnIdentifier,
                        timestamp: timestamp,
                        profile: &updatedProfile
                    )
                    visibleChanges.append(
                        "Updated: \(mutation.userVisibleWording)"
                    )
                } else {
                    updatedProfile.memoryRecords.append(
                        makeRecord(
                            mutation: mutation,
                            sourceSessionIdentifier:
                                sourceSessionIdentifier,
                            sourceTurnIdentifier:
                                sourceTurnIdentifier,
                            timestamp: timestamp
                        )
                    )
                    visibleChanges.append(
                        "Saved: \(mutation.userVisibleWording)"
                    )
                }

            case .correct:
                guard let matchingRecordIndex else {
                    throw PartnerMemoryReducerError
                        .missingRecordForCorrection
                }
                let existingRecord =
                    updatedProfile.memoryRecords[matchingRecordIndex]
                guard existingRecord.normalizedContent
                        != mutation.normalizedContent else {
                    continue
                }
                replaceRecord(
                    at: matchingRecordIndex,
                    mutation: mutation,
                    sourceSessionIdentifier: sourceSessionIdentifier,
                    sourceTurnIdentifier: sourceTurnIdentifier,
                    timestamp: timestamp,
                    profile: &updatedProfile
                )
                updatedProfile.contradictions.removeAll {
                    $0.stableKey == mutation.stableKey
                        && $0.status == .unresolved
                }
                visibleChanges.append(
                    "Corrected: \(mutation.userVisibleWording)"
                )

            case .forget:
                guard let matchingRecordIndex else {
                    continue
                }
                updatedProfile.memoryRecords.remove(
                    at: matchingRecordIndex
                )
                updatedProfile.contradictions.removeAll {
                    $0.stableKey == mutation.stableKey
                }
                visibleChanges.append(
                    "Forgot: \(mutation.userVisibleWording)"
                )

            case .contradict:
                guard let matchingRecordIndex else {
                    updatedProfile.memoryRecords.append(
                        makeRecord(
                            mutation: mutation,
                            sourceSessionIdentifier:
                                sourceSessionIdentifier,
                            sourceTurnIdentifier:
                                sourceTurnIdentifier,
                            timestamp: timestamp
                        )
                    )
                    visibleChanges.append(
                        "Saved as unconfirmed: "
                            + mutation.userVisibleWording
                    )
                    continue
                }
                appendContradiction(
                    mutation: mutation,
                    existingRecord:
                        updatedProfile.memoryRecords[matchingRecordIndex],
                    sourceSessionIdentifier: sourceSessionIdentifier,
                    sourceTurnIdentifier: sourceTurnIdentifier,
                    timestamp: timestamp,
                    profile: &updatedProfile,
                    visibleChanges: &visibleChanges
                )
            }
        }

        if !visibleChanges.isEmpty {
            updatedProfile.updatedAt = timestamp
        }
        let receipt = PartnerMemoryReceipt(
            identifier: UUID(),
            visibleChanges: visibleChanges,
            createdAt: timestamp,
            profileBeforeChanges:
                visibleChanges.isEmpty ? nil : profileBeforeChanges
        )
        return PartnerMemoryReduction(
            profile: updatedProfile,
            receipt: receipt
        )
    }

    static func undo(
        receipt: PartnerMemoryReceipt,
        in profile: PartnerProfile,
        timestamp: Date
    ) throws -> PartnerMemoryReduction {
        guard var restoredProfile = receipt.profileBeforeChanges else {
            throw PartnerMemoryReducerError.receiptCannotBeUndone
        }
        restoredProfile.updatedAt = timestamp
        return PartnerMemoryReduction(
            profile: restoredProfile,
            receipt: PartnerMemoryReceipt(
                identifier: UUID(),
                visibleChanges: ["Undid the last saved memory change."],
                createdAt: timestamp,
                profileBeforeChanges: nil
            )
        )
    }

    static func relevantContext(
        for query: String,
        in profile: PartnerProfile,
        maximumCharacters: Int
    ) -> String {
        guard maximumCharacters > 0 else {
            return ""
        }
        let queryTokens = searchableTokens(in: query)
        guard !queryTokens.isEmpty else {
            return ""
        }

        let rankedRecords = profile.memoryRecords.compactMap {
            memoryRecord -> (score: Int, record: PartnerMemoryRecord)? in
            let searchableText = [
                memoryRecord.stableKey,
                memoryRecord.normalizedContent,
                memoryRecord.userVisibleWording,
                memoryRecord.domain.rawValue,
            ].joined(separator: " ")
            let memoryTokens = searchableTokens(in: searchableText)
            let score = queryTokens.intersection(memoryTokens).count
            guard score > 0 else {
                return nil
            }
            return (score, memoryRecord)
        }.sorted {
            if $0.score == $1.score {
                return $0.record.lastUpdatedAt
                    > $1.record.lastUpdatedAt
            }
            return $0.score > $1.score
        }

        var result = ""
        for rankedRecord in rankedRecords {
            let record = rankedRecord.record
            let candidateLine =
                "[\(record.domain.rawValue)] "
                + record.normalizedContent
                + " (confidence: "
                + String(format: "%.2f", record.confidence)
                + ", state: "
                + record.confirmationState.rawValue
                + ")"
            let separator = result.isEmpty ? "" : "\n"
            let remainingCharacters =
                maximumCharacters - result.count - separator.count
            guard remainingCharacters > 0 else {
                break
            }
            if candidateLine.count <= remainingCharacters {
                result += separator + candidateLine
            } else if result.isEmpty {
                result = String(
                    candidateLine.prefix(maximumCharacters)
                )
            }
        }
        return result
    }

    private static func validate(
        _ mutation: PartnerMemoryMutation
    ) throws {
        let stableKey = mutation.stableKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !stableKey.isEmpty,
              stableKey.count <= maximumStableKeyCharacters,
              stableKey.range(
                  of: #"^[a-z0-9]+(?:[._-][a-z0-9]+)*$"#,
                  options: .regularExpression
              ) != nil else {
            throw PartnerMemoryReducerError.invalidStableKey
        }
        guard mutation.confidence.isFinite,
              (0...1).contains(mutation.confidence) else {
            throw PartnerMemoryReducerError.invalidConfidence
        }
        if mutation.operation != .forget {
            guard !mutation.normalizedContent
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                  !mutation.userVisibleWording
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                  mutation.normalizedContent.count
                    <= maximumContentCharacters,
                  mutation.userVisibleWording.count
                    <= maximumContentCharacters else {
                throw PartnerMemoryReducerError.invalidContent
            }
        }
        let receiptCandidate =
            mutation.normalizedContent
            + " "
            + mutation.userVisibleWording
        if containsSecretShapedContent(receiptCandidate) {
            throw PartnerMemoryReducerError.secretShapedContent
        }
    }

    private static func makeRecord(
        mutation: PartnerMemoryMutation,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        timestamp: Date
    ) -> PartnerMemoryRecord {
        PartnerMemoryRecord(
            identifier: UUID(),
            domain: mutation.domain,
            stableKey: mutation.stableKey,
            normalizedContent: mutation.normalizedContent,
            userVisibleWording: mutation.userVisibleWording,
            confidence: mutation.confidence,
            confirmationState: mutation.confirmationState,
            linkedRecordIdentifiers:
                Array(Set(mutation.linkedRecordIdentifiers)),
            sourceSessionIdentifier: sourceSessionIdentifier,
            sourceTurnIdentifier: sourceTurnIdentifier,
            firstLearnedAt: timestamp,
            lastUpdatedAt: timestamp,
            lastConfirmedAt:
                mutation.confirmationState == .confirmed
                    ? timestamp
                    : nil,
            correctionHistory: []
        )
    }

    private static func replaceRecord(
        at recordIndex: Int,
        mutation: PartnerMemoryMutation,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        timestamp: Date,
        profile: inout PartnerProfile
    ) {
        var record = profile.memoryRecords[recordIndex]
        record.correctionHistory.append(
            PartnerMemoryRecordVersion(
                normalizedContent: record.normalizedContent,
                userVisibleWording: record.userVisibleWording,
                confirmationState: record.confirmationState,
                replacedAt: timestamp,
                sourceSessionIdentifier:
                    record.sourceSessionIdentifier,
                sourceTurnIdentifier:
                    record.sourceTurnIdentifier
            )
        )
        record.domain = mutation.domain
        record.normalizedContent = mutation.normalizedContent
        record.userVisibleWording = mutation.userVisibleWording
        record.confidence = mutation.confidence
        record.confirmationState = mutation.confirmationState
        record.linkedRecordIdentifiers = Array(
            Set(
                record.linkedRecordIdentifiers
                    + mutation.linkedRecordIdentifiers
            )
        )
        record.sourceTurnIdentifier = sourceTurnIdentifier
        record.lastUpdatedAt = timestamp
        if mutation.confirmationState == .confirmed {
            record.lastConfirmedAt = timestamp
        }
        profile.memoryRecords[recordIndex] = record
    }

    private static func appendContradiction(
        mutation: PartnerMemoryMutation,
        existingRecord: PartnerMemoryRecord,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        timestamp: Date,
        profile: inout PartnerProfile,
        visibleChanges: inout [String]
    ) {
        let alreadyExists = profile.contradictions.contains {
            $0.stableKey == mutation.stableKey
                && $0.existingContent
                    == existingRecord.normalizedContent
                && $0.conflictingContent
                    == mutation.normalizedContent
                && $0.status == .unresolved
        }
        guard !alreadyExists else {
            return
        }
        profile.contradictions.append(
            PartnerContradictionRecord(
                identifier: UUID(),
                stableKey: mutation.stableKey,
                existingRecordIdentifier:
                    existingRecord.identifier,
                existingContent:
                    existingRecord.normalizedContent,
                conflictingContent:
                    mutation.normalizedContent,
                sourceSessionIdentifier:
                    sourceSessionIdentifier,
                sourceTurnIdentifier: sourceTurnIdentifier,
                createdAt: timestamp,
                status: .unresolved
            )
        )
        visibleChanges.append(
            "Conflict to resolve: \(mutation.userVisibleWording)"
        )
    }

    private static func searchableTokens(
        in text: String
    ) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "about", "and", "did", "do", "for", "i", "in",
            "is", "it", "me", "my", "of", "on", "the", "to",
            "what", "you",
        ]
        let normalizedText = text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
        return Set(
            normalizedText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter {
                    $0.count > 1 && !stopWords.contains($0)
                }
        )
    }

    private static func containsSecretShapedContent(
        _ text: String
    ) -> Bool {
        if text.range(
            of: #"(?i)\b(?:sk|pk|rk)_[a-z0-9_-]{16,}\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        guard let regularExpression = try? NSRegularExpression(
            pattern: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#
        ) else {
            return true
        }
        let fullRange = NSRange(
            text.startIndex..<text.endIndex,
            in: text
        )
        return regularExpression.matches(
            in: text,
            range: fullRange
        ).contains { match in
            guard let matchRange = Range(match.range, in: text) else {
                return false
            }
            let digits = String(text[matchRange])
                .replacingOccurrences(
                    of: #"[^0-9]"#,
                    with: "",
                    options: .regularExpression
                )
            return (13...19).contains(digits.count)
                && passesLuhnCheck(digits)
        }
    }

    private static func passesLuhnCheck(_ digits: String) -> Bool {
        var sum = 0
        let reversedDigits = digits.reversed().compactMap {
            $0.wholeNumberValue
        }
        for (index, digit) in reversedDigits.enumerated() {
            if index.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubledDigit = digit * 2
                sum += doubledDigit > 9
                    ? doubledDigit - 9
                    : doubledDigit
            }
        }
        return !reversedDigits.isEmpty
            && sum.isMultiple(of: 10)
    }
}
