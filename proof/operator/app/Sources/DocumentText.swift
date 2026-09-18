#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — on-device extraction of a buyer's dropped/imported document into grounding text.
//
// Before this, a dropped PDF was isoLatin1-decoded byte-for-byte (ChatScreen.loadDocument) into
// binary mojibake — and that garbage was fed to the model as "grounding," silently poisoning the
// answer on the buyer's OWN file. PDFs now go through PDFKit's real text layer; everything else
// keeps the plain-text path. All on-device, no network, no third-party service (§5.5), bounded so
// a giant file can't OOM the app on the buyer's machine.
import Foundation
#if canImport(PDFKit) && !CIRCUIT_WINDOWS_SIM
import PDFKit
#endif

enum DocumentText {
    /// Char cap on extracted grounding text. Only ~8 KB of query-selected excerpts ever reaches the model
    /// (ChatScreen.groundedAttachment, budget groundingCharBudget), but we keep a generous in-memory ceiling.
    static let maxChars = 200_000
    /// Hard byte cap on a PDF we'll load whole to parse. PDFKit needs the FULL file (a
    /// byte-truncated prefix won't parse), so we can't reuse the 2 MB streaming prefix used for
    /// text. Big enough for a real document, small enough not to balloon memory on a giant scan.
    static let maxPDFBytes = 25 * 1024 * 1024   // 25 MB

    /// True if the leading bytes carry the PDF magic `%PDF-`. The spec permits a little leading
    /// junk before the signature, so we scan the first 1 KB rather than only offset 0.
    static func looksLikePDF(_ data: Data) -> Bool {
        let magic = Array("%PDF-".utf8)
        let bytes = [UInt8](data.prefix(1024))
        guard bytes.count >= magic.count else { return false }
        for start in 0...(bytes.count - magic.count) where Array(bytes[start ..< start + magic.count]) == magic {
            return true
        }
        return false
    }

    /// Extract grounding text from raw document bytes. PDFs go through PDFKit's text layer;
    /// everything else decodes as UTF-8 then Latin-1 (which never fails). Returns nil when nothing
    /// readable came out (e.g. an image-only PDF with no text layer, or unparseable PDF bytes).
    /// The result is always capped to `maxChars`.
    static func extractText(data: Data, isPDF: Bool? = nil, maxChars: Int = maxChars) -> String? {
        let pdf = isPDF ?? looksLikePDF(data)
        if pdf {
            guard let doc = PDFDocument(data: data) else { return nil }
            var out = ""
            for i in 0 ..< doc.pageCount {
                guard let page = doc.page(at: i), let s = page.string, !s.isEmpty else { continue }
                if !out.isEmpty { out += "\n\n" }
                out += s
                if out.count >= maxChars { break }
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(maxChars))
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return String(text.prefix(maxChars))
    }

    // MARK: Honest attachment outcome (§5.1 — a dropped file never silently no-ops)

    /// Why a dropped/imported document produced no grounding text. Surfaced to the buyer as a real
    /// failure notice instead of a silent swallow — they dropped a file expecting it to attach, so
    /// "nothing happened" is a lie; the true reason is. Computed from the same byte/size/parse
    /// checks `extract(from:)` uses, so the reason always matches the real cause.
    enum AttachFailure: String, Equatable {
        case tooLarge      // a PDF larger than maxPDFBytes — we won't load it whole (OOM guard)
        case noTextLayer   // a PDF that parsed but carried no extractable text (a scan / image-only)
        case unreadable    // couldn't open the file, or .pdf bytes that PDFKit can't parse
        case empty         // opened fine but no readable text came out (e.g. a 0-byte note)
    }

    /// The result of reading a document URL: either real grounding text, or an honest reason it
    /// couldn't produce any. One read path, so `extract(from:)` and the buyer-facing error agree.
    enum Outcome: Equatable {
        case text(String)
        case failed(AttachFailure)
    }

    /// Read a document URL and either return its grounding text or classify why none came out.
    /// PDFs are loaded whole (bounded by `maxPDFBytes`); other documents are read as a bounded
    /// 2 MB prefix so a multi-GB log/CSV can't be mapped entirely into memory for the ~8 KB that
    /// actually feeds grounding.
    static func extractOutcome(from url: URL, maxChars: Int = maxChars) -> Outcome {
        // Peek the header so we can decide PDF-vs-text without loading a whole text file.
        let head: Data = {
            guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? h.close() }
            return (try? h.read(upToCount: 1024)) ?? Data()
        }()
        let isPDF = looksLikePDF(head) || url.pathExtension.lowercased() == "pdf"
        if isPDF {
            // PDFKit needs the full file; guard size first to avoid OOM on a giant scan.
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxPDFBytes {
                return .failed(.tooLarge)
            }
            guard let data = try? Data(contentsOf: url) else { return .failed(.unreadable) }
            if data.count > maxPDFBytes { return .failed(.tooLarge) }
            guard PDFDocument(data: data) != nil else { return .failed(.unreadable) }
            guard let text = extractText(data: data, isPDF: true, maxChars: maxChars), !text.isEmpty else {
                return .failed(.noTextLayer)
            }
            return .text(text)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failed(.unreadable) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2 * 1024 * 1024)) ?? Data()
        guard let text = extractText(data: data, isPDF: false, maxChars: maxChars), !text.isEmpty else {
            return .failed(.empty)
        }
        return .text(text)
    }

    /// Back-compat text accessor: the grounding text, or nil if none could be extracted.
    /// Delegates to `extractOutcome` so there is one read/parse path, not two that can drift.
    static func extract(from url: URL, maxChars: Int = maxChars) -> String? {
        if case .text(let t) = extractOutcome(from: url, maxChars: maxChars) { return t }
        return nil
    }

    /// A buyer-facing one-line reason a dropped document couldn't be attached. Honest and specific
    /// so the buyer knows what to do (re-export with a text layer, shrink the PDF, pick another file)
    /// instead of staring at a file that silently didn't attach.
    static func failureMessage(name: String, reason: AttachFailure) -> String {
        switch reason {
        case .tooLarge:    return "Couldn\u{2019}t attach \u{201C}\(name)\u{201D} — the PDF is larger than \(maxPDFBytes / (1024 * 1024)) MB."
        case .noTextLayer: return "Couldn\u{2019}t read text from \u{201C}\(name)\u{201D} — it looks like a scanned or image-only PDF with no text layer."
        case .unreadable:  return "Couldn\u{2019}t open \u{201C}\(name)\u{201D} — the file is unreadable or not a supported document."
        case .empty:       return "\u{201C}\(name)\u{201D} has no readable text to attach."
        }
    }
}
#endif // circuit-convert
