// Black Label Academy — on-device completion certificates.
//
// When a buyer completes EVERY lesson in a pillar (ProgressDB.lesson_progress.completed), that
// pillar's "Certificate of Completion" unlocks; finishing all lessons in the library unlocks a
// full-library certificate. Certificates render LOCALLY to PDF (ImageRenderer -> CGContext PDF page)
// — no network, nothing leaves the Mac. Every unlock is driven by REAL completion counts from the
// on-disk progress DB, never a fabricated state (§5.1). The honest footer states plainly that this
// is a self-paced completion record, not an accredited credential.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Copy (single source of truth for the honest, non-fabricated wording)

enum CertificateCopy {
    static let issuer = "Black Label Academy"
    /// The one honest disclaimer required on every certificate — it is a completion record, not a
    /// degree/license. Deliberately not softened: Academy sells owner education, not accreditation.
    static let footer = "Self-paced completion record from Black Label Academy — not an accredited credential."
}

// MARK: - Certificate identity

enum CertificateKind: Equatable, Hashable {
    case pillar(Pillar)
    case fullLibrary

    /// Short scope name used in row labels and the certificate body ("Money", "Full Library").
    var scopeTitle: String {
        switch self {
        case .pillar(let p): return p.title
        case .fullLibrary: return "Full Library"
        }
    }

    /// The headline printed on the certificate. Contains the literal "Certificate of Completion"
    /// (the `strings` proof the ship gate greps for).
    var certificateTitle: String {
        "Certificate of Completion — \(scopeTitle)"
    }

    var icon: String {
        switch self {
        case .pillar(let p): return p.icon
        case .fullLibrary: return "graduationcap.fill"
        }
    }
}

// MARK: - Completion status (pure, testable)

struct CertificateStatus: Identifiable, Equatable {
    let kind: CertificateKind
    let completed: Int
    let total: Int

    var id: String {
        switch kind {
        case .pillar(let p): return "pillar:\(p.rawValue)"
        case .fullLibrary: return "full-library"
        }
    }

    /// Unlocked only when the scope is non-empty AND every lesson in it is complete. An empty scope
    /// (total == 0) NEVER unlocks — a certificate can't be earned for a pillar with no lessons.
    var unlocked: Bool { CertificateEngine.isUnlocked(completed: completed, total: total) }

    var progressFraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }
}

/// Pure completion-detection logic. Kept free of SwiftUI/AppModel so it is unit-testable headlessly
/// (see `runCertificateSelfTest`) and can never drift from what the UI shows.
enum CertificateEngine {
    static func isUnlocked(completed: Int, total: Int) -> Bool {
        total > 0 && completed >= total
    }

    /// Build the full status list: one per pillar, then the full-library certificate last.
    static func statuses(pillars: [(kind: CertificateKind, completed: Int, total: Int)],
                         libraryCompleted: Int,
                         libraryTotal: Int) -> [CertificateStatus] {
        var out = pillars.map { CertificateStatus(kind: $0.kind, completed: $0.completed, total: $0.total) }
        out.append(CertificateStatus(kind: .fullLibrary, completed: libraryCompleted, total: libraryTotal))
        return out
    }
}

// MARK: - Live status from the app model (real counts from the loaded, lint-gated library + progress)

extension AppModel {
    /// One status per pillar (all 7) plus the full-library certificate, driven entirely by the real
    /// completion counts in the on-disk progress DB — no hardcoded totals, no fabricated unlock.
    var certificateStatuses: [CertificateStatus] {
        let pillars = Pillar.allCases.map { p in
            (kind: CertificateKind.pillar(p),
             completed: completedCount(for: .pillar(p)),
             total: count(.pillar(p)))
        }
        return CertificateEngine.statuses(pillars: pillars,
                                          libraryCompleted: completedCount,
                                          libraryTotal: totalCount)
    }

    var unlockedCertificateCount: Int { certificateStatuses.filter(\.unlocked).count }
}

// MARK: - Rendered certificate data

struct CertificateData: Equatable {
    let recipientName: String
    let kind: CertificateKind
    let lessonCount: Int
    let dateString: String

    /// Build print data for an (unlocked) status, stamping today's completion date.
    static func make(name: String, status: CertificateStatus, now: Date = Date()) -> CertificateData {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none
        return CertificateData(recipientName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               kind: status.kind,
                               lessonCount: status.total,
                               dateString: df.string(from: now))
    }
}

// MARK: - The printable certificate (SwiftUI view rendered to PDF)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct CertificateDocument: View {
    let data: CertificateData

    private let gold = Color(red: 0.83, green: 0.68, blue: 0.35)
    private let paper = Color(red: 0.05, green: 0.05, blue: 0.06)

    var body: some View {
        ZStack {
            paper
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(gold, lineWidth: 3)
                .padding(24)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(gold.opacity(0.4), lineWidth: 1)
                .padding(32)

            VStack(spacing: 0) {
                Text("BLACK LABEL ACADEMY")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(8)
                    .foregroundColor(gold)
                Spacer().frame(height: 26)

                Text("Certificate of Completion")
                    .font(.system(size: 40, weight: .heavy, design: .serif))
                    .foregroundColor(.white)
                Text(data.kind.scopeTitle.uppercased())
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .tracking(4)
                    .foregroundColor(gold)
                    .padding(.top, 6)

                Spacer().frame(height: 30)
                Text("This certifies that")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.65))

                Text(data.recipientName.isEmpty ? "—" : data.recipientName)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .padding(.top, 8)
                Rectangle().fill(gold.opacity(0.55)).frame(width: 340, height: 1).padding(.top, 6)

                Spacer().frame(height: 22)
                Text("has completed all \(data.lessonCount) lessons in the \(data.kind.scopeTitle) "
                     + (data.kind == .fullLibrary ? "of Black Label Academy." : "pillar of Black Label Academy."))
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: 560)

                Spacer().frame(height: 18)
                Text(data.dateString)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(gold)

                Spacer().frame(height: 26)
                Text(CertificateCopy.footer)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
            .padding(56)
        }
        .frame(width: CertificateRenderer.pageSize.width, height: CertificateRenderer.pageSize.height)
    }
}
#endif // circuit-convert

// MARK: - Local PDF renderer (ImageRenderer -> CGContext PDF page; no network, on-device only)

enum CertificateError: Error { case renderFailed }

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CertificateRenderer {
    /// US Letter, landscape (points).
    static let pageSize = CGSize(width: 792, height: 612)

    /// Render `data` to a single-page PDF at `url`. Fully local: ImageRenderer draws the SwiftUI
    /// certificate into a Core Graphics PDF context. Throws if nothing was written or the file is
    /// empty. @MainActor because ImageRenderer is main-actor isolated.
    @MainActor
    static func renderPDF(_ data: CertificateData, to url: URL) throws {
        let renderer = ImageRenderer(content: CertificateDocument(data: data))
        renderer.proposedSize = ProposedViewSize(pageSize)

        var wrote = false
        var box = CGRect(origin: .zero, size: pageSize)
        renderer.render { _, drawInContext in
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            drawInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            wrote = true
        }
        if !wrote { throw CertificateError.renderFailed }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if bytes <= 0 { throw CertificateError.renderFailed }
    }
}
#endif // circuit-convert

// MARK: - Headless self-test (pure completion logic + a real PDF render), no WindowServer

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Proves (1) the completion-detection logic gates exactly right and (2) a certificate renders to a
/// real non-zero-byte PDF on disk. Invoked via `Black Label Academy --selftest-certificates`; wired
/// into tests/smoke.sh as reproducible proof. Prints a transcript and exits.
func runCertificateSelfTest() -> Never {
    print("== Black Label Academy — certificates self-test ==")
    var ok = true
    func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL: \(msg)"); ok = false } }

    // (1) Pure completion-detection cases.
    check(CertificateEngine.isUnlocked(completed: 5, total: 5), "5/5 must unlock")
    check(!CertificateEngine.isUnlocked(completed: 4, total: 5), "4/5 must stay locked")
    check(!CertificateEngine.isUnlocked(completed: 0, total: 0), "empty scope (0/0) must never unlock")
    check(!CertificateEngine.isUnlocked(completed: 3, total: 0), "no-lesson scope must never unlock")
    check(CertificateEngine.isUnlocked(completed: 6, total: 5), "over-count still counts as complete")

    let statuses = CertificateEngine.statuses(
        pillars: [(.pillar(.money), 44, 44), (.pillar(.ai), 10, 24)],
        libraryCompleted: 278, libraryTotal: 278)
    check(statuses.count == 3, "2 pillars + full library == 3 statuses")
    check(statuses[0].unlocked, "money 44/44 unlocked")
    check(!statuses[1].unlocked, "ai 10/24 locked")
    check(statuses.last?.kind == .fullLibrary, "full-library status is last")
    check(statuses.last?.unlocked == true, "full library 278/278 unlocked")

    let partial = CertificateEngine.statuses(
        pillars: [(.pillar(.money), 43, 44)],
        libraryCompleted: 277, libraryTotal: 278)
    check(!partial[0].unlocked, "money 43/44 locked")
    check(!(partial.last?.unlocked ?? true), "full library 277/278 locked")

    // (2) Render smoke — write a real PDF to a temp dir, assert non-zero bytes + PDF magic.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("bl-academy-cert-\(ProcessInfo.processInfo.processIdentifier).pdf")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sample = CertificateData(recipientName: "Jordan Rivera", kind: .fullLibrary,
                                 lessonCount: 278, dateString: "July 11, 2026")
    do {
        try MainActor.assumeIsolated { try CertificateRenderer.renderPDF(sample, to: tmp) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        print("  rendered \(tmp.lastPathComponent) — \(bytes) bytes")
        check(bytes > 0, "rendered certificate PDF must be non-zero bytes")
        check(FileManager.default.fileExists(atPath: tmp.path), "PDF must exist on disk")
        if let head = try? FileHandle(forReadingFrom: tmp).readData(ofLength: 5) {
            check(head == Data("%PDF-".utf8), "file must be a real PDF (magic header)")
        } else {
            check(false, "could not read back the rendered PDF")
        }
    } catch {
        print("FAIL: certificate render threw \(error)")
        ok = false
    }

    print(ok ? "CERTIFICATES SELFTEST OK — completion gating is real and a certificate renders locally to PDF"
             : "CERTIFICATES SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
#endif // circuit-convert

// MARK: - Buyer-facing certificates sheet (the reader entry point into the engine above)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The sheet a buyer opens from the reader. Shows one row per pillar plus the full-library
/// certificate, each driven by REAL completion counts (`AppModel.certificateStatuses`) — locked until
/// every lesson in the scope is finished. The buyer types the name printed on the certificate (stored
/// locally only, §5.2) and exports an unlocked certificate to a local PDF. Nothing leaves the device.
struct CertificatesSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    /// User-facing confirmation of the last export (filename / saved path), never fabricated.
    @State private var exportNote: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unlockedCount: Int { model.certificateStatuses.filter(\.unlocked).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rosette").foregroundColor(BLTheme.goldLite).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Certificates").font(.system(size: 17, weight: .bold)).foregroundColor(BLTheme.text)
                    Text("\(unlockedCount) of \(model.certificateStatuses.count) unlocked")
                        .font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(BLTheme.sub).font(.system(size: 18))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider().overlay(BLTheme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME ON CERTIFICATE").font(.system(size: 10, weight: .bold))
                            .tracking(1.5).foregroundColor(BLTheme.sub)
                        TextField("Your name", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(BLTheme.text)
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                            .onChangeCompat(of: name) { _ in model.setLearnerName(trimmedName) }
                    }
                    .padding(.bottom, 4)

                    ForEach(model.certificateStatuses) { status in
                        CertificateRow(status: status, canExport: !trimmedName.isEmpty) {
                            export(status)
                        }
                    }

                    if let note = exportNote {
                        Text(note).font(.system(size: 11.5)).foregroundColor(BLTheme.green)
                            .padding(.top, 2)
                    }
                    Text(CertificateCopy.footer)
                        .font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
                        .padding(.top, 6)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(BLTheme.bg)
        .preferredColorScheme(.dark)
        .onAppear { name = model.learnerName }
    }

    /// Render an unlocked certificate to a local PDF. Persists the typed name first, then writes the
    /// file — on macOS via a save panel (buyer picks the location, then it is revealed in Finder); on
    /// iOS to the app's Documents directory. Purely local; no network path exists.
    @MainActor private func export(_ status: CertificateStatus) {
        guard status.unlocked, !trimmedName.isEmpty else { return }
        model.setLearnerName(trimmedName)
        let data = CertificateData.make(name: trimmedName, status: status)
        let filename = "BlackLabelAcademy-\(status.kind.scopeTitle.replacingOccurrences(of: " ", with: ""))-Certificate.pdf"
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CertificateRenderer.renderPDF(data, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            exportNote = "Saved \(url.lastPathComponent)"
        } catch { exportNote = "Export failed — could not write the PDF." }
        #else
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(filename)
        do {
            try CertificateRenderer.renderPDF(data, to: url)
            exportNote = "Saved to Files → \(filename)"
        } catch { exportNote = "Export failed — could not write the PDF." }
        #endif
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One certificate row: scope icon + title, the real completed/total count and progress bar, and an
/// Export button that is enabled only when the scope is unlocked AND a name has been entered.
struct CertificateRow: View {
    let status: CertificateStatus
    let canExport: Bool
    let export: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.kind.icon)
                .foregroundColor(status.unlocked ? BLTheme.goldLite : BLTheme.sub)
                .font(.system(size: 18)).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.kind.scopeTitle).font(.system(size: 14, weight: .semibold)).foregroundColor(BLTheme.text)
                Text("\(status.completed)/\(status.total) lessons complete")
                    .font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                ProgressView(value: status.progressFraction)
                    .tint(status.unlocked ? BLTheme.green : BLTheme.goldDim)
                    .frame(maxWidth: 220)
            }
            Spacer(minLength: 8)
            if status.unlocked {
                Button(action: export) {
                    HStack(spacing: 5) { Image(systemName: "arrow.down.doc"); Text("Export PDF") }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(canExport ? BLTheme.bg : BLTheme.sub)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(canExport ? BLTheme.goldLite : BLTheme.bg3, in: Capsule())
                }
                .buttonStyle(.plain).disabled(!canExport)
            } else {
                HStack(spacing: 4) { Image(systemName: "lock.fill"); Text("Locked") }
                    .font(.system(size: 11, weight: .medium)).foregroundColor(BLTheme.sub)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(BLTheme.bg3, in: Capsule())
            }
        }
        .padding(12)
        .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(status.unlocked ? BLTheme.goldDim.opacity(0.55) : BLTheme.stroke, lineWidth: 1))
    }
}
#endif // circuit-convert
