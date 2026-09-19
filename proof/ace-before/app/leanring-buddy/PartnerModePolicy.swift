import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(EventKit) && !CIRCUIT_WINDOWS_SIM
import EventKit
#endif
#if canImport(PDFKit) && !CIRCUIT_WINDOWS_SIM
import PDFKit
#endif
#if canImport(Vision) && !CIRCUIT_WINDOWS_SIM
import Vision
#endif
import CircuitPortKit

nonisolated struct PartnerComposerAttachment:
    Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let storedFilename: String
    let byteCount: Int
    let importedAt: Date
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Copies owner-selected documents into Ace's private support directory and
/// persists a content-free manifest. Provider input receives bounded extracted
/// text, never an unbounded file or a silent attachment.
nonisolated enum PartnerComposerAttachmentStore {
    private static let manifestKey = "AcePartnerComposerAttachments.v1"
    static let maximumAttachmentCount = 12
    private static let maximumAttachmentBytes = 25 * 1024 * 1024
    private static let maximumContextCharacters = 6_000

    static func load() -> [PartnerComposerAttachment] {
        guard let data = UserDefaults.standard.data(forKey: manifestKey),
              let values = try? JSONDecoder().decode(
                  [PartnerComposerAttachment].self,
                  from: data
              ) else { return [] }
        return values.filter {
            FileManager.default.fileExists(
                atPath: storedURL(for: $0).path
            )
        }
    }

    static func importURLs(
        _ urls: [URL],
        existing: [PartnerComposerAttachment]
    ) throws -> [PartnerComposerAttachment] {
        guard !urls.isEmpty else { return existing }
        try validateImportCapacity(
            existingCount: existing.count,
            requestedCount: urls.count
        )
        let directory = try supportDirectory()
        var pending: [(attachment: PartnerComposerAttachment, data: Data)] = []
        for source in urls {
            let didStart = source.startAccessingSecurityScopedResource()
            defer {
                if didStart { source.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: source)
            guard !data.isEmpty,
                  data.count <= maximumAttachmentBytes else {
                throw NSError(
                    domain: "AcePartnerComposer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Each attachment must be between 1 byte and 25 MB."]
                )
            }
            let fileID = UUID()
            let safeExtension = source.pathExtension
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let storedFilename = fileID.uuidString.lowercased()
                + (safeExtension.isEmpty ? "" : "." + safeExtension)
            pending.append((
                PartnerComposerAttachment(
                    id: fileID,
                    displayName: String(source.lastPathComponent.prefix(180)),
                    storedFilename: storedFilename,
                    byteCount: data.count,
                    importedAt: Date()
                ),
                data
            ))
        }

        var createdURLs: [URL] = []
        do {
            for item in pending {
                let target = directory.appendingPathComponent(
                    item.attachment.storedFilename
                )
                try item.data.write(
                    to: target,
                    options: [.atomic, .withoutOverwriting]
                )
                createdURLs.append(target)
            }
            let result = existing + pending.map(\.attachment)
            try save(result)
            return result
        } catch {
            for url in createdURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    static func validateImportCapacity(
        existingCount: Int,
        requestedCount: Int
    ) throws {
        guard existingCount >= 0,
              requestedCount >= 0,
              existingCount + requestedCount <= maximumAttachmentCount else {
            throw NSError(
                domain: "AcePartnerComposer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Partner supports up to 12 attached documents at a time. Remove an attachment before adding another."]
            )
        }
    }

    static func remove(
        _ attachment: PartnerComposerAttachment,
        from existing: [PartnerComposerAttachment]
    ) -> [PartnerComposerAttachment] {
        try? FileManager.default.removeItem(at: storedURL(for: attachment))
        let result = existing.filter { $0.id != attachment.id }
        try? save(result)
        return result
    }

    static func clear(
        _ attachments: [PartnerComposerAttachment]
    ) -> [PartnerComposerAttachment] {
        for attachment in attachments {
            try? FileManager.default.removeItem(
                at: storedURL(for: attachment)
            )
        }
        try? save([])
        return []
    }

    static func boundedContext(
        for attachments: [PartnerComposerAttachment]
    ) -> String {
        guard !attachments.isEmpty else { return "" }
        var remaining = maximumContextCharacters
        var sections: [String] = [
            "OWNER-ATTACHED CONTEXT (selected explicitly in Partner):"
        ]
        for attachment in attachments {
            guard remaining > 0 else { break }
            let extracted = extractedText(from: storedURL(for: attachment))
            let body = extracted.isEmpty
                ? "No readable text was extracted; attachment metadata only."
                : String(extracted.prefix(remaining))
            let section = "Attachment: \(attachment.displayName) (\(attachment.byteCount) bytes)\n\(body)"
            sections.append(section)
            remaining -= min(remaining, section.count)
        }
        return String(
            sections.joined(separator: "\n\n")
                .prefix(maximumContextCharacters)
        )
    }

    static func readableText(
        for attachment: PartnerComposerAttachment
    ) -> String {
        extractedText(from: storedURL(for: attachment))
    }

    static func storedURL(
        for attachment: PartnerComposerAttachment
    ) -> URL {
        (try? supportDirectory())?
            .appendingPathComponent(attachment.storedFilename)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func extractedText(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: url) {
            return document.string ?? ""
        }
        if ["txt", "md", "csv", "json", "html", "rtf"].contains(ext) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        if ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext),
           let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage)
                .perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        return ""
    }

    private static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("BlackLabel/Ace/PartnerAttachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func save(
        _ attachments: [PartnerComposerAttachment]
    ) throws {
        let data = try JSONEncoder().encode(attachments)
        UserDefaults.standard.set(data, forKey: manifestKey)
    }
}
#endif // circuit-convert

struct SyllabusCalendarProposal: Equatable, Identifiable {
    let id: UUID
    var title: String
    var dueAt: Date
    var durationMinutes: Int
}

struct SyllabusDestinationCalendar: Equatable, Identifiable {
    let id: String
    let title: String
    let sourceTitle: String
}

struct SyllabusProposalCreationSelection: Equatable {
    let unique: [SyllabusCalendarProposal]
    let duplicateIDs: Set<UUID>
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class SyllabusCalendarWorkflow: ObservableObject {
    @Published var proposals: [SyllabusCalendarProposal] = []
    @Published private(set) var calendars:
        [SyllabusDestinationCalendar] = []
    @Published var selectedCalendarID: String?
    @Published private(set) var ambiguities: [String] = []
    @Published private(set) var sourceDescription: String?
    @Published private(set) var status =
        "Attach a PDF or image, or explicitly select the visible syllabus."
    @Published private(set) var authorityIsArmed = false
    @Published private(set) var isWorking = false

    private let eventStore = EKEventStore()
    private var armedDigest: String?
    private var authorityExpiresAt: Date?

    func prepare(
        attachment: PartnerComposerAttachment
    ) async {
        isWorking = true
        defer { isWorking = false }
        let text = PartnerComposerAttachmentStore.readableText(
            for: attachment
        )
        sourceDescription = attachment.displayName
        proposals = Self.extractProposals(from: text)
        ambiguities = Self.extractAmbiguities(from: text)
        authorityIsArmed = false
        let calendarAccessGranted = await requestCalendarAccess()
        await refreshCalendars()
        if !calendarAccessGranted {
            status =
                "The syllabus was loaded, but Calendar access was not granted. Allow Calendar access, then choose the file again."
        } else {
            status = proposals.isEmpty
                ? "No assignment/date pairs were extracted. Add or edit items manually, then choose the destination calendar."
                : "Extracted \(proposals.count) proposed calendar items. Edit every title and date, then select the destination calendar."
        }
    }

    func reportSelectionFailure(_ message: String) {
        status = message
    }

    func prepareVisibleSyllabusImage(
        _ imageData: Data,
        sourceLabel: String
    ) async {
        isWorking = true
        defer { isWorking = false }
        let text: String
        if let image = NSImage(data: imageData),
           let cgImage = image.cgImage(
               forProposedRect: nil,
               context: nil,
               hints: nil
           ) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage)
                .perform([request])
            text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } else {
            text = ""
        }
        sourceDescription = sourceLabel
        proposals = Self.extractProposals(from: text)
        ambiguities = Self.extractAmbiguities(from: text)
        authorityIsArmed = false
        let calendarAccessGranted = await requestCalendarAccess()
        await refreshCalendars()
        if !calendarAccessGranted {
            status =
                "The visible syllabus was read, but Calendar access was not granted. Allow Calendar access and try again."
        } else {
            status = proposals.isEmpty
                ? "No assignment/date pairs were readable in the selected visible syllabus."
                : "Extracted \(proposals.count) proposed items from the explicitly selected visible syllabus."
        }
    }

    func addBlankProposal() {
        proposals.append(
            SyllabusCalendarProposal(
                id: UUID(),
                title: "Assignment",
                dueAt: Date().addingTimeInterval(24 * 60 * 60),
                durationMinutes: 30
            )
        )
        authorityIsArmed = false
    }

    func removeProposal(_ id: UUID) {
        proposals.removeAll { $0.id == id }
        authorityIsArmed = false
    }

    func invalidateAuthority() {
        authorityIsArmed = false
        armedDigest = nil
        authorityExpiresAt = nil
    }

    func armExactReview() {
        guard !proposals.isEmpty,
              proposals.allSatisfy({
                  !$0.title.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
              }),
              let selectedCalendarID,
              calendars.contains(where: { $0.id == selectedCalendarID }),
              CrossAppActionPolicy.requiresConfirmation(
                  "create calendar events"
              ) else {
            status =
                "Finish the editable preview and choose the exact destination calendar first."
            return
        }
        armedDigest = digest(
            proposals: proposals,
            calendarID: selectedCalendarID
        )
        authorityExpiresAt = Date().addingTimeInterval(60)
        authorityIsArmed = true
        status =
            "Exact calendar review armed for 60 seconds. Confirm Create & Verify to perform only the items shown."
    }

    func createAndVerify() async {
        guard authorityIsArmed,
              let expiry = authorityExpiresAt,
              expiry >= Date(),
              let selectedCalendarID,
              armedDigest == digest(
                  proposals: proposals,
                  calendarID: selectedCalendarID
              ) else {
            invalidateAuthority()
            status =
                "The exact review changed or expired. Review and arm it again; no events were created."
            return
        }
        invalidateAuthority()
        isWorking = true
        defer { isWorking = false }
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore
                    .requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation {
                    continuation in
                    eventStore.requestAccess(to: .event) { allowed, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: allowed)
                        }
                    }
                }
            }
            guard granted,
                  let calendar = eventStore.calendar(
                      withIdentifier: selectedCalendarID
                  ) else {
                status =
                    "Calendar access or the selected destination is unavailable. No events were created."
                return
            }
            let verificationWindowStart = proposals
                .map(\.dueAt).min() ?? Date()
            let verificationWindowEnd = proposals.map {
                $0.dueAt.addingTimeInterval(
                    TimeInterval(max(5, $0.durationMinutes) * 60)
                )
            }.max() ?? Date()
            let predicate = eventStore.predicateForEvents(
                withStart: verificationWindowStart
                    .addingTimeInterval(-60),
                end: verificationWindowEnd
                    .addingTimeInterval(60),
                calendars: [calendar]
            )
            let existing = eventStore.events(matching: predicate)
            let sourceSelection = Self.creationSelection(
                from: proposals
            )
            let existingDuplicateIDs = Set(sourceSelection.unique.compactMap {
                proposal -> UUID? in
                existing.contains {
                    $0.calendar.calendarIdentifier == selectedCalendarID
                        && $0.title == proposal.title
                        && abs($0.startDate.timeIntervalSince(
                            proposal.dueAt
                        )) < 1
                } ? proposal.id : nil
            })
            let duplicateProposalIDs = sourceSelection.duplicateIDs
                .union(existingDuplicateIDs)
            let proposalsToCreate = sourceSelection.unique.filter {
                !duplicateProposalIDs.contains($0.id)
            }
            guard !proposalsToCreate.isEmpty else {
                status =
                    "No events were created. All \(duplicateProposalIDs.count) proposals already exist as exact duplicates in \(calendar.title)."
                return
            }
            for proposal in proposalsToCreate {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = proposal.title
                event.startDate = proposal.dueAt
                event.endDate = proposal.dueAt.addingTimeInterval(
                    TimeInterval(max(5, proposal.durationMinutes) * 60)
                )
                try eventStore.save(event, span: .thisEvent, commit: false)
            }
            try eventStore.commit()
            let observed = eventStore.events(matching: predicate)
            let verifiedCount = proposalsToCreate.filter { proposal in
                observed.contains {
                    $0.calendar.calendarIdentifier == selectedCalendarID
                        && $0.title == proposal.title
                        && abs($0.startDate.timeIntervalSince(
                            proposal.dueAt
                        )) < 1
                }
            }.count
            let duplicateSuffix = duplicateProposalIDs.isEmpty
                ? ""
                : " Skipped \(duplicateProposalIDs.count) exact duplicate(s)."
            status = verifiedCount == proposalsToCreate.count
                ? "Created and verified all \(verifiedCount) new events in \(calendar.title).\(duplicateSuffix)"
                : "Created the transaction, but verified only \(verifiedCount) of \(proposalsToCreate.count) new events.\(duplicateSuffix) Inspect Calendar before retrying anything."
        } catch {
            eventStore.reset()
            status =
                "Calendar creation failed: \(error.localizedDescription). No completion is claimed."
        }
    }

    func refreshCalendars() async {
        let listed = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                SyllabusDestinationCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                ($0.sourceTitle, $0.title)
                    < ($1.sourceTitle, $1.title)
            }
        calendars = listed
        if let selectedCalendarID,
           !listed.contains(where: { $0.id == selectedCalendarID }) {
            self.selectedCalendarID = nil
        }
    }

    private func requestCalendarAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            }
            return try await withCheckedThrowingContinuation {
                continuation in
                eventStore.requestAccess(to: .event) { allowed, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: allowed)
                    }
                }
            }
        } catch {
            return false
        }
    }

    private func digest(
        proposals: [SyllabusCalendarProposal],
        calendarID: String
    ) -> String {
        ([calendarID] + proposals.map {
            "\($0.id.uuidString)|\($0.title)|\($0.dueAt.timeIntervalSince1970)|\($0.durationMinutes)"
        }).joined(separator: "\n")
    }

    nonisolated static func extractProposals(
        from text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SyllabusCalendarProposal] {
        let lines = text.components(separatedBy: .newlines)
        let monthPattern =
            #"(?i)\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,?\s+\d{4})?\b"#
        let numericPattern = #"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#
        let timePattern =
            #"(?i)\b(?:[01]?\d|2[0-3]):[0-5]\d\s*(?:a\.?m\.?|p\.?m\.?)?\b|\b(?:1[0-2]|[1-9])\s*(?:a\.?m\.?|p\.?m\.?)\b"#
        var result: [SyllabusCalendarProposal] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard line.count >= 4 else { continue }
            let dateText: String?
            if let range = line.range(
                of: monthPattern,
                options: .regularExpression
            ) {
                dateText = String(line[range])
            } else if let range = line.range(
                of: numericPattern,
                options: .regularExpression
            ) {
                dateText = String(line[range])
            } else {
                dateText = nil
            }
            guard let dateText,
                  let parsed = parsedDate(
                      dateText,
                      now: now,
                      calendar: calendar
                  ) else { continue }
            let timeText = line.range(
                of: timePattern,
                options: .regularExpression
            ).map { String(line[$0]) }
            var title = line.replacingOccurrences(
                of: dateText,
                with: ""
            )
            if let timeText {
                title = title.replacingOccurrences(
                    of: timeText,
                    with: ""
                )
                title = title.replacingOccurrences(
                    of: #"(?i)\b(?:at|by)\s*$"#,
                    with: "",
                    options: .regularExpression
                )
            }
            title = title
            .trimmingCharacters(
                in: CharacterSet(charactersIn: " -–—:|\t")
            )
            guard !title.isEmpty else { continue }
            let dueAt: Date
            if let timeText,
               let clock = parsedTime(timeText) {
                dueAt = calendar.date(
                    bySettingHour: clock.hour,
                    minute: clock.minute,
                    second: 0,
                    of: parsed
                ) ?? parsed
            } else {
                dueAt = calendar.date(
                    bySettingHour: 9,
                    minute: 0,
                    second: 0,
                    of: parsed
                ) ?? parsed
            }
            result.append(
                SyllabusCalendarProposal(
                    id: UUID(),
                    title: String(title.prefix(180)),
                    dueAt: dueAt,
                    durationMinutes: 30
                )
            )
        }
        return Array(result.prefix(120))
    }

    nonisolated static func extractAmbiguities(
        from text: String
    ) -> [String] {
        let assignmentPattern =
            #"(?i)\b(assignment|exam|quiz|project|paper|reading|homework|midterm|final|due)\b"#
        let dateTokenPattern =
            #"(?i)\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,?\s+\d{4})?\b|\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#
        let timePattern =
            #"(?i)\b(?:[01]?\d|2[0-3]):[0-5]\d\s*(?:a\.?m\.?|p\.?m\.?)?\b|\b(?:1[0-2]|[1-9])\s*(?:a\.?m\.?|p\.?m\.?)\b"#
        var results: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty,
                  line.range(
                      of: assignmentPattern,
                      options: .regularExpression
                  ) != nil else { continue }
            let proposals = extractProposals(from: line)
            var reasons: [String] = []
            if proposals.isEmpty {
                reasons.append("No exact date extracted")
            }
            if line.range(
                of: #"(?i)\b(?:tba|tbd|to be announced|to be determined|today|tomorrow|next\s+\w+day)\b"#,
                options: .regularExpression
            ) != nil {
                reasons.append("Relative or unset date")
            }
            let dateTokenCount = (try? NSRegularExpression(
                pattern: dateTokenPattern
            ))?.numberOfMatches(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) ?? 0
            let hasRangeConnector = line.range(
                of: #"(?i)\b(?:through|thru|until)\b|\d\s*[-–—]\s*\d"#,
                options: .regularExpression
            ) != nil
            let hasTwoDatesJoinedByTo = dateTokenCount > 1
                && line.range(
                    of: #"(?i)\bto\b"#,
                    options: .regularExpression
                ) != nil
            if hasRangeConnector || hasTwoDatesJoinedByTo {
                reasons.append("Date range needs one exact due date")
            }
            if let numeric = line.range(
                of: #"\b(\d{1,2})/(\d{1,2})(?:/\d{2,4})?\b"#,
                options: .regularExpression
            ) {
                let parts = line[numeric].split(separator: "/")
                let first = Int(parts.first ?? "") ?? 99
                let second = Int(parts.dropFirst().first ?? "") ?? 99
                if first <= 12 && second <= 12 {
                    reasons.append("Numeric date order is ambiguous")
                }
                if parts.count < 3 {
                    reasons.append("Year was inferred")
                }
            } else if !proposals.isEmpty, line.range(
                of: #"\b\d{4}\b"#,
                options: .regularExpression
            ) == nil {
                reasons.append("Year was inferred")
            }
            if !proposals.isEmpty,
               line.range(
                   of: timePattern,
                   options: .regularExpression
               ) == nil {
                reasons.append(
                    "No due time was stated; 9:00 AM is only a proposal"
                )
            }
            if line.range(
                of: #"(?i)\b(?:UTC|GMT|EST|EDT|CST|CDT|MST|MDT|PST|PDT)\b|[+-]\d{2}:?\d{2}\b"#,
                options: .regularExpression
            ) != nil {
                reasons.append("Time zone requires confirmation")
            }
            for reason in reasons {
                let entry = "\(reason): \(String(line.prefix(150)))"
                if !results.contains(entry) { results.append(entry) }
            }
            if results.count >= 12 { break }
        }
        return Array(results.prefix(12))
    }

    nonisolated static func creationSelection(
        from proposals: [SyllabusCalendarProposal]
    ) -> SyllabusProposalCreationSelection {
        var observed = Set<String>()
        var unique: [SyllabusCalendarProposal] = []
        var duplicateIDs = Set<UUID>()
        for proposal in proposals {
            let normalizedTitle = proposal.title.lowercased()
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            let key = normalizedTitle + "|"
                + String(Int(proposal.dueAt.timeIntervalSince1970.rounded()))
            if observed.insert(key).inserted {
                unique.append(proposal)
            } else {
                duplicateIDs.insert(proposal.id)
            }
        }
        return SyllabusProposalCreationSelection(
            unique: unique,
            duplicateIDs: duplicateIDs
        )
    }

    nonisolated private static func parsedTime(
        _ value: String
    ) -> (hour: Int, minute: Int)? {
        let cleaned = value.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        let isPM = cleaned.hasSuffix("pm")
        let isAM = cleaned.hasSuffix("am")
        let clockText = cleaned
            .replacingOccurrences(of: "am", with: "")
            .replacingOccurrences(of: "pm", with: "")
        let parts = clockText.split(separator: ":")
        guard let rawHour = Int(parts.first ?? ""),
              let minute = parts.count > 1
                ? Int(parts[1]) : 0,
              (0...59).contains(minute) else { return nil }
        var hour = rawHour
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }
        guard (0...23).contains(hour),
              (!isAM && !isPM) || (1...12).contains(rawHour)
        else { return nil }
        return (hour, minute)
    }

    nonisolated private static func parsedDate(
        _ value: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let hasYear = value.range(
            of: #"\b\d{4}\b"#,
            options: .regularExpression
        ) != nil || value.split(separator: "/").count == 3
        let formats = hasYear
            ? ["MMMM d yyyy", "MMM d yyyy", "MMMM d, yyyy",
               "MMM d, yyyy", "M/d/yyyy", "M/d/yy"]
            : ["MMMM d", "MMM d", "M/d"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                if hasYear { return date }
                var parts = calendar.dateComponents(
                    [.month, .day],
                    from: date
                )
                parts.year = calendar.component(.year, from: now)
                guard var inferred = calendar.date(from: parts) else {
                    continue
                }
                if inferred < calendar.startOfDay(for: now) {
                    inferred = calendar.date(
                        byAdding: .year,
                        value: 1,
                        to: inferred
                    ) ?? inferred
                }
                return inferred
            }
        }
        return nil
    }
}
#endif // circuit-convert

nonisolated enum PartnerActivationFollowUp:
    Equatable,
    Sendable
{
    case speakThenListen(String)
}

nonisolated struct PartnerModePolicy {
    static let activationFollowUp =
        PartnerActivationFollowUp.speakThenListen(
            "I'm here. Let's talk."
        )

    static func command(for transcript: String) -> PartnerModeCommand? {
        let normalizedTranscript = normalize(transcript)

        switch normalizedTranscript {
        case "ace be my partner",
             "be my partner",
             "ace be my thinking partner",
             "be my thinking partner",
             "ace partner mode",
             "partner mode",
             "start partner mode",
             "enter partner mode",
             "ace lets chat",
             "lets chat",
             "ace lets talk",
             "lets talk":
            return .activate
        case "end partner session",
             "end partner mode",
             "exit partner mode",
             "turn off partner mode",
             "turn partner mode off",
             "stop partner mode",
             "disable partner mode",
             "close partner mode",
             "go away",
             "stop partner session",
             "leave",
             "leave partner",
             "stop partner",
             "get me out",
             "im done",
             "return to normal",
             "back to normal",
             "exit",
             "end this conversation",
             "close partner":
            return .end
        case "give me a minute",
             "give me a moment",
             "let me think",
             "wait":
            return .wait
        case "mute partner mode",
             "mute this session",
             "stop listening":
            return .mute
        case "resume listening",
             "resume partner mode",
             "unmute partner mode",
             "i am ready":
            return .resume
        case "look at my screen",
             "look at what is on my screen",
             "look at whats on my screen",
             "use my screen",
             "check my screen":
            return .requestScreenContext
        case "that is wrong",
             "thats wrong",
             "correct that",
             "update that":
            return .correctMemory
        case "undo what you saved",
             "undo that memory",
             "undo the last memory":
            return .undoMemory
        case "forget that",
             "forget what you saved":
            return .forgetMemory
        default:
            return nil
        }
    }

    /// Activation is global; every other Partner control is scoped to the
    /// session the owner explicitly opened. Without this boundary, ordinary
    /// owner requests such as "wait", "leave", or "exit" were classified as
    /// Partner controls while Partner was inactive and then disappeared when
    /// the controller correctly refused to handle them.
    static func routableCommand(
        for transcript: String,
        sessionIsActive: Bool
    ) -> PartnerModeCommand? {
        guard let parsed = command(for: transcript) else { return nil }
        if parsed == .activate { return parsed }
        return sessionIsActive ? parsed : nil
    }

    static func nextPhase(
        currentPhase: PartnerSessionPhase,
        command: PartnerModeCommand
    ) -> PartnerSessionPhase {
        switch command {
        case .activate:
            return currentPhase == .inactive ? .ready : currentPhase
        case .end:
            return .inactive
        case .wait:
            return currentPhase == .inactive ? .inactive : .waiting
        case .mute:
            return currentPhase == .inactive ? .inactive : .muted
        case .resume:
            if currentPhase == .waiting || currentPhase == .muted {
                return .ready
            }
            return currentPhase
        case .requestScreenContext,
             .correctMemory,
             .undoMemory,
             .forgetMemory:
            return currentPhase
        }
    }

    static func mayOpenMicrophone(
        phase: PartnerSessionPhase,
        userActivatedSession: Bool,
        stealthBlocked: Bool,
        microphoneReady: Bool,
        speechRecognitionReady: Bool
    ) -> Bool {
        phase == .ready
            && userActivatedSession
            && !stealthBlocked
            && microphoneReady
            && speechRecognitionReady
    }

    private static func normalize(_ transcript: String) -> String {
        transcript
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(
                of: #"[^a-z0-9']+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

nonisolated enum PartnerSpeechCompletion:
    String,
    Sendable
{
    case completed
    case interrupted
    case failed
    case blocked
    case cancelled
}

nonisolated struct PartnerTurnLoopPolicy {
    // DELETED 2026-08-13: `reasoningFailureSpokenText`, which spoke
    // "I lost that response, but Partner Mode is still active. Please say that
    // again." on any thrown error. It made the owner re-say a question Ace had
    // already heard. A failed Partner turn now retries the provider itself and
    // then speaks `AceReasoningRecoveryPolicy.partnerFailureSpokenText`, which
    // names the real cause and never asks for a repeat. Do not reintroduce a
    // constant here: recovery speech is one policy for every lane, and it is
    // guarded by `AceReasoningRecoveryPolicy.requestsARepeat`.

    static func shouldReopenMicrophone(
        speechCompletion: PartnerSpeechCompletion,
        currentPhase: PartnerSessionPhase,
        userActivatedSession: Bool,
        stealthBlocked: Bool,
        muteRequested: Bool,
        waitRequested: Bool,
        sessionIdentifierMatches: Bool
    ) -> Bool {
        speechCompletion == .completed
            && currentPhase == .speaking
            && userActivatedSession
            && !stealthBlocked
            && !muteRequested
            && !waitRequested
            && sessionIdentifierMatches
    }

}

nonisolated struct PartnerResumePolicy {
    static func foregroundWorkAllowsListening(
        answerIsActive: Bool,
        appActionPlanningIsActive: Bool
    ) -> Bool {
        !answerIsActive && !appActionPlanningIsActive
    }

    static func shouldResume(
        userActivatedSession: Bool,
        phase: PartnerSessionPhase,
        stealthBlocked: Bool,
        notesAreTaking: Bool,
        notesAreStarting: Bool
    ) -> Bool {
        userActivatedSession
            && phase == .ready
            && !stealthBlocked
            && !notesAreTaking
            && !notesAreStarting
    }
}

/// Owns the visible Partner "Think" / "Continue" control contract.
/// A transcript the owner can see is already captured owner input: pressing
/// Think must finalize that exact microphone turn, never cancel and erase it.
/// With no captured words, the same control is a deliberate listening pause.
nonisolated struct PartnerThinkButtonPolicy {
    enum Action: Equatable, Sendable {
        case finalizeCapturedTurn
        case enterWaiting
        case resume
        case noAction
    }

    static func action(
        phase: PartnerSessionPhase,
        temporaryCaption: String
    ) -> Action {
        if phase == .waiting {
            return .resume
        }
        guard phase == .ready || phase == .listening else {
            return .noAction
        }
        let hasCapturedWords = !temporaryCaption
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if phase == .listening, hasCapturedWords {
            return .finalizeCapturedTurn
        }
        return .enterWaiting
    }
}

/// Measures speech above the current room level independently of the visual
/// waveform gain. A steady fan or line-input floor must not own the microphone.
nonisolated struct PartnerSpeechActivity {
    private var levels: [(time: TimeInterval, level: Double)] = []
    private(set) var threshold: Double = 0.055

    mutating func observe(level: Double, at time: TimeInterval) -> Bool {
        guard level.isFinite, time.isFinite else { return false }
        let bounded = min(1, max(0, level))
        levels.append((time, bounded))
        levels.removeAll { time - $0.time > 3 }
        if levels.count > 64 { levels.removeFirst(levels.count - 64) }
        if levels.count >= 6, let first = levels.first,
           time - first.time >= 0.5 {
            let sorted = levels.map(\.level).sorted()
            let floor = sorted[(sorted.count - 1) / 5]
            threshold = max(0.055, min(0.5, floor * 1.7 + 0.015))
        }
        return bounded >= threshold
    }
}

nonisolated struct PartnerAutomaticTurnBoundary {
    enum Action:
        Equatable,
        Sendable
    {
        case keepListening
        case renewSilentListeningWindow
        case finalizeTranscript
    }

    static let minimumSilenceAfterTranscriptSeconds: TimeInterval =
        1.35
    static let maximumTurnSeconds: TimeInterval = 90
    static let speakingAudioPowerThreshold: Double = 0.055
    static let minimumSpeechQuietSeconds: TimeInterval = 0.65
    static let maximumUnchangedTranscriptSeconds: TimeInterval = 6

    static func action(
        transcript: String,
        secondsSinceTranscriptChanged: TimeInterval,
        secondsSinceRecordingStarted: TimeInterval,
        currentAudioPowerLevel: Double,
        secondsSinceSpeechActivity: TimeInterval? = nil
    ) -> Action {
        let hasRecognizedWords = !transcript
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        if secondsSinceRecordingStarted
            >= maximumTurnSeconds {
            return hasRecognizedWords
                ? .finalizeTranscript
                : .renewSilentListeningWindow
        }
        guard hasRecognizedWords else {
            return .keepListening
        }
        // A recognizer that has stopped advancing must not leave a completed
        // owner request behind a 90-second open-mic window, even under noise.
        if secondsSinceTranscriptChanged >= maximumUnchangedTranscriptSeconds {
            return .finalizeTranscript
        }
        let speechIsQuiet = secondsSinceSpeechActivity.map {
            $0 >= minimumSpeechQuietSeconds
        } ?? (currentAudioPowerLevel < speakingAudioPowerThreshold)
        guard secondsSinceTranscriptChanged
                >= minimumSilenceAfterTranscriptSeconds,
              speechIsQuiet else {
            return .keepListening
        }
        return .finalizeTranscript
    }

    static func shouldFinalize(
        transcript: String,
        secondsSinceTranscriptChanged: TimeInterval,
        secondsSinceRecordingStarted: TimeInterval,
        currentAudioPowerLevel: Double
    ) -> Bool {
        action(
            transcript: transcript,
            secondsSinceTranscriptChanged:
                secondsSinceTranscriptChanged,
            secondsSinceRecordingStarted:
                secondsSinceRecordingStarted,
            currentAudioPowerLevel:
                currentAudioPowerLevel
        ) == .finalizeTranscript
    }

    static func transcriptDidChange(
        previous: String,
        current: String
    ) -> Bool {
        previous != current
    }
}
