#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — OFFERS/LOI, DISPOSITIONS (cash buyers + blast), ANALYTICS, and
// GLOBAL SEARCH. All real data, all on the buyer's own pipeline. Nothing fabricated.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Offers & LOI
enum OfferExportAccess {
    static let watermark = "SAMPLE — NOT A REAL OFFER"
    static let previewNotice = "WORKFLOW PREVIEW ONLY — NOT FOR OUTREACH OR DELIVERY"

    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The sample entitlement bypass is granted to one exact generated offer/deal pair, never to
    /// the global Sample Mode flag. Editing the property breaks the proof and restores the paywall.
    static func isExactSyntheticPair(offer: Offer, linkedDeal: Deal?) -> Bool {
        guard let deal = linkedDeal,
              offer.dealID == deal.id,
              let offerFixture = offer.sampleFixtureID, !offerFixture.isEmpty,
              let dealFixture = deal.sampleFixtureID, offerFixture == dealFixture else { return false }
        let offerAddress = normalized(offer.propertyAddress)
        let dealAddress = normalized(deal.address)
        return !offerAddress.isEmpty && offerAddress == dealAddress
    }

    static func hasSampleProvenance(offer: Offer, linkedDeal: Deal?) -> Bool {
        offer.sampleFixtureID != nil || linkedDeal?.sampleFixtureID != nil
    }

    static func allowsExport(offer: Offer, linkedDeal: Deal?, entitled: Bool) -> Bool {
        entitled || isExactSyntheticPair(offer: offer, linkedDeal: linkedDeal)
    }

    static func documentText(offer: Offer, linkedDeal: Deal?, now: Date = Date()) -> String {
        let body = offer.loiText(now: now)
        guard hasSampleProvenance(offer: offer, linkedDeal: linkedDeal) else { return body }
        return "\(watermark)\n\(previewNotice)\n\n\(body)\n\n\(watermark)"
    }

    /// Synthetic fixtures are never eligible for vendor delivery, even on an entitled account.
    static func allowsMailSend(offer: Offer, linkedDeal: Deal?) -> Bool {
        !hasSampleProvenance(offer: offer, linkedDeal: linkedDeal)
    }
}

struct OffersScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Offer?
    @State private var deleting: Offer?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "Offers & LOI", subtitle: "Generate a real Letter of Intent and track every offer") {
                GoldButton(label: "New offer", icon: "plus") { editing = newOffer() }.disabled(model.deals.isEmpty)
            }.blScreenPadding(28)
            if model.deals.isEmpty {
                Spacer(); EmptyState(icon: "doc.text", title: "Add a deal first", hint: "Offers attach to a deal. Create a deal in Deals or the Analyzer, then draft an LOI here."); Spacer()
            } else if model.offers.isEmpty {
                Spacer(); EmptyState(icon: "doc.badge.plus", title: "No offers yet", hint: "Tap New offer to generate a fillable LOI from a deal — copy or export it to send."); Spacer()
            } else {
                ScrollView { LazyVStack(spacing: 11) { ForEach(model.offers) { o in offerRow(o) } }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28) }
            }
        }
        .sheet(item: $editing) { o in OfferEditor(offer: o).environmentObject(model).sheetCloseBar() }
        .confirmationDialog("Delete this offer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let o = deleting { model.deleteOffer(o) }; deleting = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes it — there is no undo.") }
    }
    private func newOffer() -> Offer {
        let d = model.deals.first!
        return Offer(dealID: d.id, sampleFixtureID: d.sampleFixtureID,
                     propertyAddress: d.address, amount: d.mao)
    }
    @ViewBuilder private func offerRow(_ o: Offer) -> some View {
        Button { editing = o } label: {
            HStack(spacing: 14) {
                IconBadge(system: "doc.text.fill", size: 38, active: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(o.propertyAddress.isEmpty ? "Untitled offer" : o.propertyAddress).font(.blSystem(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    HStack(spacing: 8) { StatusPill(text: o.status.label, tint: o.status.tint); Text(REMath.money(o.amount)).font(.blSystem(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.4))
            }
            .padding(16).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
        .contextMenu { Button("Delete", role: .destructive) { deleting = o } }
    }
}

struct OfferEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var offer: Offer
    @State private var showLOI = false
    @State private var showMailSend = false
    @State private var showPaywall = false
    @State private var exportNote = ""
    @State private var confirmDelete = false
    /// The offer as opened — dirty means the local copy differs from what the model holds.
    private let original: Offer
    init(offer: Offer) { self.original = offer; self._offer = State(initialValue: offer) }
    private var isDirty: Bool { offer != (model.offers.first(where: { $0.id == offer.id }) ?? original) }
    private var linkedDeal: Deal? { model.deals.first { $0.id == offer.dealID } }
    private var isSampleOffer: Bool { OfferExportAccess.hasSampleProvenance(offer: offer, linkedDeal: linkedDeal) }
    private var documentText: String { OfferExportAccess.documentText(offer: offer, linkedDeal: linkedDeal) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(system: "doc.text.fill", size: 30)
                Text("Offer / LOI").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                if isSampleOffer { StatusPill(text: "SAMPLE — NOT A REAL OFFER", tint: BLTheme.gold) }
                Spacer()
            }
            Field(title: "Property", text: $offer.propertyAddress, prompt: "Property address")
            HStack(spacing: 12) { Field(title: "Buyer / entity", text: $offer.buyerName, prompt: "Your LLC"); Field(title: "Seller / estate", text: $offer.sellerName, prompt: "Estate of…") }
            HStack(spacing: 12) { NumField(title: "Offer amount", value: $offer.amount, prompt: "180000"); NumField(title: "Earnest money", value: $offer.earnestMoney, prompt: "1000") }
            HStack(spacing: 12) {
                IntField(title: "Closing days", value: $offer.closingDays)
                IntField(title: "Inspection days", value: $offer.inspectionDays)
            }
            Field(title: "Contingencies", text: $offer.contingencies, prompt: "Inspection, title, financing")
            Picker("Status", selection: $offer.status) { ForEach(OfferStatus.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).tint(BLTheme.gold)
            DisclosureGroup(isExpanded: $showLOI) {
                Text(documentText).font(.blSystem(size: 11.5, design: .monospaced)).foregroundColor(BLTheme.text).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            } label: { Text("LOI preview").font(BLFont.body(13, .bold)).foregroundColor(BLTheme.gold) }
            // The five desktop actions exceed every phone width. Prefer the one-line desktop row,
            // then wrap the exact same live controls on compact canvases instead of clipping them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    copyAction; exportAction; mailAction; deleteAction
                    Spacer()
                    cancelAction; saveAction
                }
                FlowLayout(spacing: 8) {
                    copyAction; exportAction; mailAction; deleteAction; cancelAction; saveAction
                }
            }
            .confirmationDialog("Delete this offer?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteOffer(offer); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes it — there is no undo.") }
            if !exportNote.isEmpty {
                Label(exportNote, systemImage: "checkmark.circle.fill")
                    .font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.green)
            }
            if isSampleOffer {
                Label(OfferExportAccess.previewNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(BLFont.body(11, .bold)).foregroundColor(BLTheme.gold)
            }
        }.blScreenPadding(26) }
        .sheetFrame(540, 680)
        .sheetEditsPending(isDirty)
        .sheet(isPresented: $showMailSend) { MailSendSheet(offer: offer).environmentObject(model).sheetCloseBar() }
        .sheet(isPresented: $showPaywall) { TrialPaywallSheet().sheetCloseBar() }
    }
    private var copyAction: some View {
        GhostButton(label: "Copy LOI", icon: "doc.on.doc", tint: BLTheme.gold) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(documentText, forType: .string)
        }
    }
    /// Visible Delete for a saved offer — the list's context menu is a shortcut, not the only path.
    @ViewBuilder private var deleteAction: some View {
        if model.offers.contains(where: { $0.id == offer.id }) {
            GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { confirmDelete = true }
        }
    }
    private var exportAction: some View {
        GhostButton(label: isSampleOffer ? "Export watermarked sample…" : "Export…", icon: "square.and.arrow.up", tint: BLTheme.gold) {
            guard OfferExportAccess.allowsExport(offer: offer, linkedDeal: linkedDeal,
                                                 entitled: REAccess.allowsPaidFeatures) else {
                showPaywall = true; return
            }
            exportLOI()
        }
    }
    private var mailAction: some View {
        GhostButton(label: "Send by mail…", icon: "paperplane.fill", tint: BLTheme.gold) {
            guard OfferExportAccess.allowsMailSend(offer: offer, linkedDeal: linkedDeal) else {
                exportNote = "Sample preview only — vendor delivery is disabled."; return
            }
            guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
            model.upsert(offer); showMailSend = true
        }
    }
    private var cancelAction: some View {
        GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
    }
    private var saveAction: some View {
        GoldButton(label: "Save", icon: "checkmark") { model.upsert(offer); dismiss() }
    }
    private func exportLOI() {
        let prefix = isSampleOffer ? "SAMPLE-NOT-A-REAL-OFFER-" : ""
        exportNote = exportTextFile(suggestedName: "\(prefix)LOI-\(offer.propertyAddress.replacingOccurrences(of: " ", with: "-")).txt",
                                    contents: documentText) ?? ""
    }
}

// MARK: - Buyer-key mail SEND (review-first). Mails the generated LOI/letter through the buyer's OWN
// Lob/PostGrid key. Never a fake "sent": the confirmation only shows a REAL provider letter id.
// MARK: - Mail-send view-model (pure, UI-free) — the vendor-readiness rules the MailSendSheet
// renders, extracted so they're ASSERTED not eyeballed (mirrors RoutePresenter / DealPresenter /
// DispositionsPresenter — beef550, 2b3b0ec, 458716e). The honesty invariants a demo begs to break:
//   • A "sent"/accepted confirmation renders ONLY from a REAL provider letter id — no letter id
//     (no result, or a result with an empty id) NEVER reads "sent"; the send stays not-confirmed.
//   • An unconfigured vendor key yields the honest connect-a-key state (the readiness gate leads
//     with "Add your <vendor> API key"), and Send is disabled — zero fabricated mailpiece.
//   • Send is enabled only when the piece is fully mailable (key + complete to/from + a body).
enum MailSendPresenter {
    enum SendState: Hashable {
        case blocked(blockers: [String], needsVendorKey: Bool)  // not mailable yet; needsVendorKey ⇒ connect-a-key leads
        case ready                                              // fully mailable, nothing sent yet
        case sent(detail: String)                               // ONLY from a real provider letter id
    }
    static func sendState(vendor: MailVendor, hasKey: Bool, piece: MailPiece,
                          result: MailSendResult?) -> SendState {
        if let r = result, !r.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var detail = "Accepted by \(r.vendorLabel) — letter \(r.id)"
            if !r.status.isEmpty { detail += " · \(r.status)" }
            if !r.expectedDelivery.isEmpty { detail += " · est. \(r.expectedDelivery)" }
            return .sent(detail: detail + ". Verify in your provider dashboard.")
        }
        let blockers = MailSend.readiness(vendor: vendor, hasKey: hasKey, piece: piece)
        return blockers.isEmpty ? .ready : .blocked(blockers: blockers, needsVendorKey: !hasKey)
    }
    /// True iff the state renders a "sent"/accepted line — must NEVER be true without a real letter id.
    static func rendersSent(_ s: SendState) -> Bool { if case .sent = s { return true }; return false }
    /// The Send action is enabled only in the fully-ready state.
    static func canSend(_ s: SendState) -> Bool { if case .ready = s { return true }; return false }
}

struct MailSendSheet: View {
    @Environment(\.dismiss) var dismiss
    let offer: Offer
    private let d = UserDefaults.standard
    @State private var vendor: MailVendor = .lob
    @State private var apiKey = ""
    @State private var hasKey = MailVendorKeychain.hasKey()
    @State private var to = MailAddress()
    @State private var from = MailAddress()
    @State private var sending = false
    @State private var result: MailSendResult?
    @State private var errorText = ""
    private var isSampleOffer: Bool { offer.sampleFixtureID != nil }
    private var letterText: String {
        guard isSampleOffer else { return offer.loiText() }
        return "\(OfferExportAccess.watermark)\n\(OfferExportAccess.previewNotice)\n\n\(offer.loiText())\n\n\(OfferExportAccess.watermark)"
    }

    private var piece: MailPiece {
        MailPiece(to: to, from: from, html: MailSend.htmlForLetter(letterText),
                  description: "Seller LOI — \(offer.propertyAddress)")
    }
    private var sendState: MailSendPresenter.SendState {
        if isSampleOffer {
            return .blocked(blockers: [OfferExportAccess.previewNotice], needsVendorKey: false)
        }
        return MailSendPresenter.sendState(vendor: vendor, hasKey: hasKey, piece: piece, result: result)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "paperplane.fill", size: 30); Text("Send letter by mail").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Text("Mails this Letter of Intent through YOUR OWN mail vendor, billed to your account. Review every field — nothing is sent until you press Send, and we only confirm a send your provider actually accepted.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            Picker("Vendor", selection: $vendor) { ForEach(MailVendor.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(vendor.label.uppercased()) API KEY").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                SecureField(hasKey ? "•••••••• (stored in Keychain)" : "Paste your \(vendor.label) API key", text: $apiKey)
                    .textFieldStyle(.plain).font(.blSystem(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                Text(vendor.signupHint).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            addressBlock("RECIPIENT (seller / estate)", $to)
            addressBlock("YOUR RETURN ADDRESS", $from)

            DisclosureGroup { Text(letterText).font(.blSystem(size: 11, design: .monospaced)).foregroundColor(BLTheme.text).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)) }
              label: { Text("Letter preview").font(BLFont.body(13, .bold)).foregroundColor(BLTheme.gold) }

            if case .sent(let detail) = sendState {
                Label(detail, systemImage: "checkmark.seal.fill")
                    .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.green).fixedSize(horizontal: false, vertical: true)
            } else if !errorText.isEmpty {
                Label(errorText, systemImage: "exclamationmark.triangle.fill").font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true)
            } else if case .blocked(let blockers, _) = sendState {
                VStack(alignment: .leading, spacing: 3) { ForEach(blockers, id: \.self) { b in Label(b, systemImage: "circle").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) } }
            }

            HStack {
                Spacer()
                GhostButton(label: MailSendPresenter.rendersSent(sendState) ? "Close" : "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: sending ? "Sending…" : "Send letter", icon: sending ? "hourglass" : "paperplane.fill") { sendLetter() }
                    .disabled(sending || MailSendPresenter.rendersSent(sendState) || !MailSendPresenter.canSend(sendState))
            }
        }.blScreenPadding(24) }.sheetFrame(560, 760)
        .onAppear {
            to = MailAddress.from(name: offer.sellerName, oneLine: offer.propertyAddress)
            from = MailAddress(name: d.string(forKey: "bl.re.mail.from.name") ?? offer.buyerName,
                               line1: d.string(forKey: "bl.re.mail.from.line1") ?? "",
                               line2: d.string(forKey: "bl.re.mail.from.line2") ?? "",
                               city: d.string(forKey: "bl.re.mail.from.city") ?? "",
                               state: d.string(forKey: "bl.re.mail.from.state") ?? "",
                               zip: d.string(forKey: "bl.re.mail.from.zip") ?? "")
        }
    }

    @ViewBuilder private func addressBlock(_ title: String, _ a: Binding<MailAddress>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(0.8)
            Field(title: "Name", text: a.name, prompt: "Full name / entity")
            Field(title: "Street", text: a.line1, prompt: "Street address")
            HStack(spacing: 10) { Field(title: "City", text: a.city, prompt: "City"); Field(title: "State", text: a.state, prompt: "GA"); Field(title: "ZIP", text: a.zip, prompt: "30303") }
        }
    }

    private func sendLetter() {
        errorText = ""
        guard !isSampleOffer else { errorText = OfferExportAccess.previewNotice; return }
        if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty { MailVendorKeychain.set(apiKey.trimmingCharacters(in: .whitespaces)); hasKey = true }
        // Remember the return address for next time (local only).
        d.set(from.name, forKey: "bl.re.mail.from.name"); d.set(from.line1, forKey: "bl.re.mail.from.line1")
        d.set(from.line2, forKey: "bl.re.mail.from.line2"); d.set(from.city, forKey: "bl.re.mail.from.city")
        d.set(from.state, forKey: "bl.re.mail.from.state"); d.set(from.zip, forKey: "bl.re.mail.from.zip")
        guard let key = MailVendorKeychain.get() else { errorText = MailSendError.notConfigured.errorDescription ?? "No key."; return }
        sending = true
        let p = piece
        Task {
            do {
                let r = try await MailSend.send(piece: p, vendor: vendor, apiKey: key)
                await MainActor.run { sending = false; result = r }
            } catch {
                await MainActor.run { sending = false; errorText = (error as? MailSendError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}

// MARK: - Dispositions view-model (pure, UI-free) — the honesty rules the buyer list, the
// buyer-match sheet, and the deal-blast composer render, extracted so they're ASSERTED not
// eyeballed (mirrors RoutePresenter / DealPresenter — beef550, 2b3b0ec):
//   1. A buyer/contact is NEVER fabricated — an unnamed buyer reads "Unnamed buyer" (an honest
//      empty state), and a buyer with no email/phone surfaces NO contact token, never a placeholder.
//   2. The exact address is POF-GATED — an unverified buyer only ever gets a blurred teaser with
//      the house number stripped; a "revealed" disclosure to an unverified buyer is a hard fail.
//   3. The deal-blast send-preview carries only the deal's OWN money (ARV/repairs/asking/profit
//      trace to the Deal math; an all-zero deal shows $0, never a seeded constant) and its
//      recipient list excludes BOTH no-email buyers AND anyone on the Do-Not-Contact/opt-out list.
enum DispositionsPresenter {
    /// Honest display name — an unnamed buyer is labeled, never given a fabricated identity.
    static func buyerName(_ b: CashBuyer) -> String {
        b.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Unnamed buyer" : b.name
    }

    /// The contact tokens actually shown for a buyer — ONLY real, non-empty values. A buyer with
    /// no contact on file yields an EMPTY list (the row shows no contact), never a placeholder
    /// email/phone. This is the "no fabricated contact ever renders" rail.
    static func buyerContactTokens(_ b: CashBuyer) -> [String] {
        [b.email, b.phone].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// How a match row discloses the deal's location to ONE buyer.
    enum AddressDisclosure: Hashable {
        case revealed(String)     // exact address — only ever a POF-verified buyer
        case gatedTeaser(String)  // blurred teaser (house number stripped) — unverified buyer
        var text: String { switch self { case .revealed(let s), .gatedTeaser(let s): return s } }
    }
    /// The disclosure the row actually renders — verified ⇒ exact, unverified ⇒ POF teaser. Both
    /// route through Dispositions.gatedAddress so the shipped string IS the tested one.
    static func matchAddress(_ deal: Deal, for buyer: CashBuyer) -> AddressDisclosure {
        buyer.pofVerified ? .revealed(Dispositions.gatedAddress(deal, for: buyer))
                          : .gatedTeaser(Dispositions.gatedAddress(deal, for: buyer))
    }

    /// The leading house number of an address (only when the first token is purely numeric), or nil.
    static func houseNumber(_ address: String) -> String? {
        let first = String(address.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
        return (!first.isEmpty && first.allSatisfy(\.isNumber)) ? first : nil
    }

    /// HARD HONESTY INVARIANT (POF gate): for an UNVERIFIED buyer the disclosure must never be a
    /// `.revealed`, and any teaser must omit the deal's house number. A leaked exact address or a
    /// teaser carrying the number would make the POF gate a lie. Verified buyers may see everything.
    static func disclosureIsHonest(_ d: AddressDisclosure, deal: Deal, verified: Bool) -> Bool {
        if verified { return true }
        if case .revealed = d { return false }
        guard let no = houseNumber(deal.address) else { return true }
        if case .gatedTeaser(let t) = d { return !t.contains(no) }
        return true
    }

    /// The match score as rendered ("NN%") — traces to the pure Dispositions.match, capped 0…100.
    static func scoreText(_ m: BuyerMatch) -> String { "\(m.score)%" }

    // MARK: Deal-blast send-preview
    struct BlastAudience: Hashable {
        var eligible: [CashBuyer]     // real email, not on the Do-Not-Contact list
        var suppressed: Int           // has an email but on DNC/opt-out — skipped, shown honestly
        var noContact: Int            // no email on file — can't be a recipient (never invented one)
    }
    /// Partition the buyer list for a blast: only buyers with a REAL email who are NOT on the
    /// buyer's own Do-Not-Contact/opt-out list are recipients. Suppressed + no-contact buyers are
    /// COUNTED honestly, never silently promoted into the send.
    static func blastAudience(_ buyers: [CashBuyer], suppression: Suppression) -> BlastAudience {
        var eligible: [CashBuyer] = []; var suppressed = 0; var noContact = 0
        for b in buyers {
            let e = b.email.trimmingCharacters(in: .whitespaces)
            if e.isEmpty { noContact += 1 }
            else if suppression.suppresses(email: e) { suppressed += 1 }
            else { eligible.append(b) }
        }
        return BlastAudience(eligible: eligible, suppressed: suppressed, noContact: noContact)
    }

    /// The blast body preview — every figure traces to the deal's OWN fields; a blank address
    /// becomes an honest "off-market property", never a fabricated street.
    static func blastBody(_ deal: Deal) -> String {
        """
        New deal — \(deal.address.isEmpty ? "off-market property" : deal.address)

        ARV: \(REMath.money(deal.arv))
        Estimated repairs: \(REMath.money(deal.repairsEffective))
        Asking: \(REMath.money(deal.asking))
        \(deal.exit.label) profit potential: \(REMath.money(deal.projectedProfit))

        Cash, quick close. Reply if you want the full numbers.
        """
    }
}

// MARK: - Dispositions (cash-buyer list + deal blast composer)
struct DispositionsScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var jump = SearchJump.shared
    @State private var editing: CashBuyer?
    @State private var deleting: CashBuyer?
    @State private var blast = false
    @State private var matching = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "Dispositions", subtitle: "Your cash-buyer list — \(model.buyers.count) buyers · auto-match a deal, POF-gated address reveal") {
                if !model.buyers.isEmpty && !model.deals.isEmpty { GhostButton(label: "Match buyers", icon: "sparkle.magnifyingglass", tint: BLTheme.gold) { matching = true } }
                if !model.buyers.isEmpty { GhostButton(label: "Blast a deal", icon: "paperplane.fill", tint: BLTheme.gold) { blast = true } }
                GoldButton(label: "Add buyer", icon: "plus") { editing = CashBuyer() }
            }.blScreenPadding(28)
            if model.buyers.isEmpty {
                Spacer(); EmptyState(icon: "person.2.wave.2", title: "No cash buyers yet", hint: "Build your buyers list — name, contact, the markets and criteria they buy. Then blast deals to them."); Spacer()
            } else {
                ScrollView { LazyVStack(spacing: 11) { ForEach(model.buyers) { b in buyerRow(b) } }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28) }
            }
        }
        .sheet(item: $editing) { b in BuyerEditor(buyer: b).environmentObject(model).sheetCloseBar() }
        .sheet(isPresented: $blast) { BlastComposer().environmentObject(model).sheetCloseBar() }
        .sheet(isPresented: $matching) { BuyerMatchSheet().environmentObject(model).sheetCloseBar() }
        .confirmationDialog("Delete this buyer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let b = deleting { model.deleteBuyer(b) }; deleting = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes it — there is no undo.") }
        // Global-search deep link: a buyer hit opens that buyer's editor, not just the list.
        .onAppear(perform: consumeSearchJump)
        .onChangeCompat(of: jump.buyer) { _ in consumeSearchJump() }
    }
    private func consumeSearchJump() {
        guard let id = jump.buyer else { return }
        jump.buyer = nil
        if let b = model.buyers.first(where: { $0.id == id }) { editing = b }
    }
    @ViewBuilder private func buyerRow(_ b: CashBuyer) -> some View {
        Button { editing = b } label: {
            HStack(spacing: 14) {
                IconBadge(system: "person.fill", size: 38, active: b.pofVerified)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(DispositionsPresenter.buyerName(b)).font(.blSystem(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        if b.pofVerified { StatusPill(text: "POF ✓", tint: BLTheme.green) }
                    }
                    HStack(spacing: 8) {
                        if !b.email.isEmpty { Text(b.email).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.gold) }
                        if b.minPrice > 0 || b.maxPrice > 0 { Text("\(REMath.money(b.minPrice))–\(REMath.money(b.maxPrice))").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub) }
                        if !b.markets.isEmpty { Text(b.markets).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.4))
            }
            .padding(16).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain).contextMenu { Button("Delete", role: .destructive) { deleting = b } }
    }
}

struct BuyerEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var buyer: CashBuyer
    @State private var minStr = ""; @State private var maxStr = ""
    @State private var confirmDelete = false
    /// The buyer as opened — dirty means the local copy differs from what the model holds.
    private let original: CashBuyer
    init(buyer: CashBuyer) { self.original = buyer; self._buyer = State(initialValue: buyer) }
    private var isDirty: Bool { buyer != (model.buyers.first(where: { $0.id == buyer.id }) ?? original) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "person.fill", size: 30); Text(buyer.name.isEmpty ? "New buyer" : "Edit buyer").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Field(title: "Name", text: $buyer.name, prompt: "Buyer / company")
            HStack(spacing: 12) { Field(title: "Email", text: $buyer.email, prompt: "Buyer email"); Field(title: "Phone", text: $buyer.phone, prompt: "Buyer phone") }
            Field(title: "Markets / counties they buy", text: $buyer.markets, prompt: "Markets, counties, or ZIPs")
            Field(title: "Criteria notes", text: $buyer.criteria, prompt: "SFR, 3/2, condition prefs…")

            // Structured BUY-BOX (drives auto-match)
            Text("BUY-BOX (drives deal auto-match)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1).padding(.top, 4)
            HStack(spacing: 12) {
                priceField("Min price $", text: $minStr) { buyer.minPrice = Double($0.filter { "0123456789".contains($0) }) ?? 0 }
                priceField("Max price $", text: $maxStr) { buyer.maxPrice = Double($0.filter { "0123456789".contains($0) }) ?? 0 }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("STRATEGIES THEY BUY").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                HStack(spacing: 8) {
                    ForEach(ExitStrategy.allCases) { s in
                        Button { if buyer.strategies.contains(s) { buyer.strategies.remove(s) } else { buyer.strategies.insert(s) } } label: {
                            HStack(spacing: 5) { Image(systemName: s.icon).font(.blSystem(size: 10, weight: .bold)); Text(s.label).font(BLFont.body(11, .semibold)) }
                                .foregroundColor(buyer.strategies.contains(s) ? BLTheme.ink : BLTheme.text)
                                .padding(.vertical, 6).padding(.horizontal, 11)
                                .background(buyer.strategies.contains(s) ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule())
                                .overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                Text("None selected = buys any strategy. Empty markets = buys anywhere.").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
            }

            // Proof of funds — gates the address reveal
            Text("PROOF OF FUNDS (gates address reveal)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1).padding(.top, 4)
            Toggle(isOn: Binding(get: { buyer.pofVerified }, set: { v in buyer.pofVerified = v; buyer.pofVerifiedDate = v ? Date() : nil })) {
                Text("POF verified — this buyer may see exact addresses").font(BLFont.body(12.5, .semibold))
            }.toggleStyle(.switch).tint(BLTheme.gold)
            if buyer.pofVerified { Field(title: "POF label (what you verified)", text: $buyer.pofLabel, prompt: "Bank letter 6/2026") }
            Text("Only flip this on after YOU review their real proof of funds. Unverified buyers see a blurred teaser, never the house number — no fabricated verification.").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // Visible Delete for a saved buyer — the list's context menu is a shortcut,
                // never the only path (matches LeadDetail).
                if model.buyers.contains(where: { $0.id == buyer.id }) {
                    GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { confirmDelete = true }
                }
                Spacer()
                GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Save", icon: "checkmark") { model.upsert(buyer); dismiss() }
            }
            .confirmationDialog("Delete this buyer?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteBuyer(buyer); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes it — there is no undo.") }
        }.blScreenPadding(26) }.sheetFrame(500, 660)
        .sheetEditsPending(isDirty)
        .onAppear { minStr = buyer.minPrice > 0 ? String(Int(buyer.minPrice)) : ""; maxStr = buyer.maxPrice > 0 ? String(Int(buyer.maxPrice)) : "" }
    }
    @ViewBuilder private func priceField(_ title: String, text: Binding<String>, onChange: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("0", text: text).textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                .onChangeCompat(of: text.wrappedValue) { onChange($0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Buy-box auto-match: pick a deal, see ranked buyers + POF-gated address reveal per buyer.
struct BuyerMatchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var dealID: UUID?
    private var deal: Deal? { model.deals.first { $0.id == dealID } ?? model.deals.first }
    private var matches: [BuyerMatch] { deal.map { Dispositions.matches(for: $0, buyers: model.buyers) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "sparkle.magnifyingglass", size: 30); Text("Match buyers to a deal").font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            if model.deals.isEmpty { Text("Add a deal first, then auto-match it to your buyers' buy-boxes.").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub) }
            else if model.buyers.isEmpty { Text("Add cash buyers with a buy-box first to auto-match.").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub) }
            else {
                Picker("Deal", selection: Binding(get: { dealID ?? model.deals.first!.id }, set: { dealID = $0 })) {
                    ForEach(model.deals) { Text($0.address.isEmpty ? "Untitled" : $0.address).tag($0.id) }
                }.pickerStyle(.menu).tint(BLTheme.gold)
                if let d = deal {
                    Text("\(REMath.money(d.asking > 0 ? d.asking : d.mao)) · \(d.exit.label) · \(d.county.isEmpty ? "—" : d.county)").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                    ScrollView { VStack(spacing: 8) {
                        ForEach(matches) { m in matchRow(m, deal: d) }
                    }}.frame(maxHeight: 360)
                }
            }
            HStack { Spacer(); GoldButton(label: "Done", icon: "checkmark") { dismiss() } }
        }.blScreenPadding(26).sheetFrame(560)
    }
    @ViewBuilder private func matchRow(_ m: BuyerMatch, deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(DispositionsPresenter.buyerName(m.buyer)).font(.blSystem(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                if m.buyer.pofVerified { StatusPill(text: "POF ✓", tint: BLTheme.green) } else { StatusPill(text: "Unverified", tint: BL.danger) }
                Spacer()
                Text(DispositionsPresenter.scoreText(m)).font(BLFont.mono(13, .bold)).foregroundColor(m.strong ? BLTheme.green : BLTheme.gold)
            }
            // POF-gated address
            HStack(spacing: 6) {
                Image(systemName: m.canSeeAddress ? "mappin.circle.fill" : "lock.fill").font(.blSystem(size: 10)).foregroundColor(m.canSeeAddress ? BLTheme.green : BL.danger)
                Text(DispositionsPresenter.matchAddress(deal, for: m.buyer).text).font(BLFont.body(11, .medium)).foregroundColor(m.canSeeAddress ? BLTheme.text : BLTheme.sub).lineLimit(1)
            }
            if !m.reasons.isEmpty { Text(m.reasons.joined(separator: " · ")).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.green.opacity(0.85)) }
            if !m.misses.isEmpty { Text(m.misses.joined(separator: " · ")).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub) }
        }.padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(m.strong ? BLTheme.green.opacity(0.3) : BLTheme.stroke, lineWidth: 1))
    }
}

// Compose a deal blast to the buyer list — copy or export. Honest: no built-in mass send.
struct BlastComposer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var dealID: UUID?
    @State private var body_ = ""
    @State private var copied = false
    @State private var bodyEdited = false
    private var deal: Deal? { model.deals.first { $0.id == dealID } ?? model.deals.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "paperplane.fill", size: 30); Text("Blast a deal").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            if model.deals.isEmpty {
                Text("Add a deal first to blast it.").font(BLFont.body(13, .medium)).foregroundColor(BLTheme.sub)
            } else {
                Picker("Deal", selection: Binding(get: { dealID ?? model.deals.first!.id }, set: { dealID = $0; if !bodyEdited { regen() } })) {
                    ForEach(model.deals) { Text($0.address.isEmpty ? "Untitled" : $0.address).tag($0.id) }
                }.pickerStyle(.menu).tint(BLTheme.gold)
                let audience = DispositionsPresenter.blastAudience(model.buyers, suppression: model.suppression)
                let eligible = audience.eligible
                HStack(spacing: 6) {
                    Text("Recipients: \(eligible.count) eligible buyer\(eligible.count == 1 ? "" : "s")").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                    if audience.suppressed > 0 { Text("· \(audience.suppressed) skipped (Do-Not-Contact)").font(BLFont.body(11, .medium)).foregroundColor(BL.danger) }
                    if audience.noContact > 0 { Text("· \(audience.noContact) no email").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                }
                TextEditor(text: $body_).font(.blSystem(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text).scrollContentBackground(.hidden).padding(8).frame(height: 200).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChangeCompat(of: body_) { txt in bodyEdited = (deal.map { DispositionsPresenter.blastBody($0) } != txt) }
                if bodyEdited {
                    HStack { GhostButton(label: "Regenerate for this deal", icon: "arrow.clockwise", tint: BLTheme.gold) { regen() }; Spacer() }
                }
                Text("Built-in mass sending isn't enabled — copy this and the recipient list, then send through your own email/CRM. No fake 'sent' status.").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    GhostButton(label: "Copy message", icon: "doc.on.doc", tint: BLTheme.gold) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(body_, forType: .string); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    GhostButton(label: "Copy recipients", icon: "person.2", tint: BLTheme.gold) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(eligible.map { $0.email }.joined(separator: ", "), forType: .string) }
                    if copied { Label("Copied", systemImage: "checkmark").font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.green) }
                    Spacer()
                    GoldButton(label: "Done", icon: "checkmark") { dismiss() }
                }
            }
        }.blScreenPadding(26).sheetFrame(540).onAppear { regen() }
    }
    private func regen() {
        guard let d = deal else { return }
        body_ = DispositionsPresenter.blastBody(d)
        bodyEdited = false
    }
}

// MARK: - Analytics dashboard (real distributions from saved deals/leads)
struct AnalyticsScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var dbStats: StatsResult?
    @State private var dbCoverage: CoverageResult?
    @State private var dbLoading = false
    @State private var dbError = ""
    let cols = [GridItem(.adaptive(minimum: BLScale.cardMin(240, spacing: 16)), spacing: 16)]
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Analytics", subtitle: "Full database and owned pipeline metrics - computed live, never fabricated")
            databasePanel
            MarketIntelligencePanel()
            if model.deals.isEmpty && model.leads.isEmpty {
                EmptyState(icon: "chart.bar.xaxis", title: "Nothing to analyze yet", hint: "Add deals and leads - your conversion, average ARV, equity and source mix appear here.").padding(.vertical, 30)
            } else {
                LazyVGrid(columns: cols, spacing: 16) {
                    MetricCard(label: "Avg ARV", value: REMath.money(model.avgARV), icon: "house.fill", accent: BLTheme.gold)
                    MetricCard(label: "Avg rehab", value: REMath.money(model.avgRehab), icon: "hammer.fill", accent: .orange)
                    MetricCard(label: "Close rate", value: REMath.pct(model.closeRate), icon: "checkmark.seal.fill", accent: BLTheme.green, hero: true)
                    MetricCard(label: "Equity at MAO", value: REMath.money(model.totalEquityAtMAO), icon: "chart.line.uptrend.xyaxis", accent: .blue)
                }
                Panel(title: "Leads by source", icon: "chart.pie.fill", glow: true) {
                    if model.leadsBySource.isEmpty { Text("No leads yet.").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub) }
                    else { ForEach(model.leadsBySource, id: \.0) { s, n in PipelineRow(label: s.label, tint: BLTheme.gold, count: n, total: max(1, model.leads.count)) } }
                }
                Panel(title: "Leads by county", icon: "map.fill") {
                    if model.leadsByCounty.isEmpty { Text("No county data yet — resolve leads to populate this.").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub) }
                    else { ForEach(model.leadsByCounty.prefix(10), id: \.0) { c, n in PipelineRow(label: c, tint: .blue, count: n, total: max(1, model.leads.count)) } }
                }
                Panel(title: "Pipeline value", icon: "dollarsign.circle.fill") {
                    Stat(label: "Projected pipeline profit", value: REMath.money(model.pipelineProfit), big: true)
                    Stat(label: "Deals tracked", value: "\(model.deals.count)")
                    Stat(label: "Won / closed", value: "\(model.wonCount)")
                }
            }
        }.blScreenPadding(28) }
        .onAppear { loadDatabaseStats() }
    }

    @ViewBuilder private var databasePanel: some View {
        Panel(title: "Full Lead Database", icon: "building.columns.fill", glow: true) {
            if dbLoading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the live database...").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub) }
            }
            LazyVGrid(columns: cols, spacing: 16) {
                MetricCard(label: "Indexed parcels", value: dbStats?.total_properties.map { PIIndexFormat.full($0) } ?? "-", icon: "building.2.fill", accent: BLTheme.gold, hero: true)
                MetricCard(label: "States covered", value: statesCovered > 0 ? "\(statesCovered)" : "-", icon: "map.fill", accent: .blue)
                MetricCard(label: "Counties covered", value: dbStats?.counties.map { PIIndexFormat.full($0) } ?? "-", icon: "mappin.and.ellipse", accent: .teal)
                MetricCard(label: "Owned CRM leads", value: "\(model.leads.count)", icon: "person.3.fill", accent: BLTheme.green)
            }
            if !dbError.isEmpty {
                Label("Live database unreachable - check Settings > Lead Database.", systemImage: "exclamationmark.triangle.fill")
                    .font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                GhostButton(label: "Refresh database", icon: "arrow.clockwise", tint: BLTheme.gold) { loadDatabaseStats() }
                Spacer()
            }
        }
    }

    private var statesCovered: Int {
        dbCoverage?.states_covered ?? dbCoverage?.coverage.count ?? dbStats?.states ?? 0
    }

    private func loadDatabaseStats() {
        guard !dbLoading else { return }
        dbLoading = true
        dbError = ""
        Task {
            let stats = try? await RealEstateAPI.stats()
            let coverage = try? await RealEstateAPI.coverage()
            await MainActor.run {
                dbLoading = false
                dbStats = stats
                dbCoverage = coverage
                if stats == nil && coverage == nil { dbError = "unreachable" }
            }
        }
    }
}

// MARK: - Global search (⌘K) — screens plus deals, leads, buyers, offers

/// A record hit chosen in GlobalSearch. Carried through `SearchJump` so the destination screen
/// opens the matched record's detail sheet instead of dropping the user on the generic list.
enum SearchJumpTarget: Equatable {
    case deal(UUID), lead(UUID), buyer(UUID)
}

/// Deep-link channel from GlobalSearch to the destination screens. The destination consumes and
/// clears its id on appear (or on change, when it is already on screen).
@MainActor
final class SearchJump: ObservableObject {
    static let shared = SearchJump()
    @Published var deal: UUID? = nil
    @Published var lead: UUID? = nil
    @Published var buyer: UUID? = nil
    func request(_ target: SearchJumpTarget) {
        switch target {
        case .deal(let id): deal = id
        case .lead(let id): lead = id
        case .buyer(let id): buyer = id
        }
    }
}

struct GlobalSearch: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var go: (Section) -> Void
    @State private var q = ""
    private var sectionHits: [Section] { q.isEmpty ? [] : Section.visibleSections.filter(sectionMatches) }
    private var dealHits: [Deal] { q.isEmpty ? [] : model.deals.filter { match($0.address, $0.county, $0.notes) } }
    private var leadHits: [Lead] { q.isEmpty ? [] : model.leads.filter { match($0.name, $0.county, $0.propertyAddress, $0.ownerName, $0.phone, $0.email) } }
    private var buyerHits: [CashBuyer] { q.isEmpty ? [] : model.buyers.filter { match($0.name, $0.email, $0.markets, $0.criteria) } }
    private var teamHits: [TeamMember] { q.isEmpty ? [] : model.team.filter { match($0.name, $0.email, $0.role) } }
    private func match(_ fields: String...) -> Bool { let l = q.lowercased(); return fields.contains { $0.lowercased().contains(l) } }
    private func sectionMatches(_ section: Section) -> Bool {
        let l = q.lowercased()
        let aliases: [String]
        switch section {
        case .propertyIndex: aliases = ["property database", "database", "parcel records", "county records", "national index"]
        case .leads: aliases = ["prospects", "lead database", "crm"]
        default: aliases = []
        }
        return ([section.rawValue, section.group] + aliases).contains { $0.lowercased().contains(l) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(BLTheme.gold)
                TextField("Search screens, deals, leads, buyers, offers…", text: $q).textFieldStyle(.plain).font(.blSystem(size: 16, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                // A key-name pill only makes sense where an Esc key exists; on touch the sheet's
                // Close bar is the single dismiss affordance (stacking a second, tiny one under it
                // reads as two inconsistent close controls).
                #if os(macOS)
                Button { dismiss() } label: { Text("Esc").font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.sub).padding(.vertical, 3).padding(.horizontal, 7).background(BLTheme.bg2).clipShape(Capsule()) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                #endif
            }.padding(18)
            Divider().overlay(BLTheme.stroke)
            ScrollView { VStack(alignment: .leading, spacing: 4) {
                if q.isEmpty {
                    Text("Type to search across everything.").font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.sub).padding(18)
                } else if sectionHits.isEmpty && dealHits.isEmpty && leadHits.isEmpty && buyerHits.isEmpty && teamHits.isEmpty {
                    Text("No matches for “\(q)”.").font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.sub).padding(18)
                } else {
                    group("APP SECTIONS", sectionHits.map { ($0.rawValue, $0.group.isEmpty ? "Open section" : $0.group, $0.icon, $0, nil) })
                    group("DEALS", dealHits.map { ($0.address.isEmpty ? "Untitled" : $0.address, "\(REMath.money($0.projectedProfit)) · \($0.status.label)", "house.fill", Section.deals, .deal($0.id)) })
                    group("LEADS", leadHits.map { ($0.name, "\($0.source.label)\($0.county.isEmpty ? "" : " · \($0.county)")", $0.source.icon, Section.pipeline, .lead($0.id)) })
                    group("BUYERS", buyerHits.map { ($0.name.isEmpty ? "Unnamed" : $0.name, $0.markets, "person.fill", Section.dispositions, .buyer($0.id)) })
                    group("TEAM", teamHits.map { ($0.name, "\($0.role) · \(model.leadCount(assignedTo: $0.id)) leads", "person.fill", Section.settings, nil) })
                }
            }.padding(.vertical, 8) }
        }
        .sheetFrame(560, 440)
    }
    @ViewBuilder private func group(_ title: String, _ rows: [(String, String, String, Section, SearchJumpTarget?)]) -> some View {
        if !rows.isEmpty {
            Text(title).font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(1).padding(.horizontal, 18).padding(.top, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                // A record hit opens THAT record at the destination, not just its section.
                Button { if let target = r.4 { SearchJump.shared.request(target) }; go(r.3) } label: {
                    HStack(spacing: 12) {
                        IconBadge(system: r.2, size: 28, active: false)
                        VStack(alignment: .leading, spacing: 1) { Text(r.0).font(.blSystem(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                            if !r.1.isEmpty { Text(r.1).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) } }
                        Spacer(); Image(systemName: "arrow.right").font(.blSystem(size: 11, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.5))
                    }.padding(.vertical, 7).padding(.horizontal, 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

// Bound int field used by the offer editor. Two-way (stays in sync with programmatic writes).
struct IntField: View {
    let title: String; @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool
    private func fmt(_ v: Int) -> String { v == 0 ? "" : String(v) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("", text: $text).textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($focused)
                .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(focused ? BLTheme.gold.opacity(0.6) : BLTheme.stroke, lineWidth: focused ? 1.5 : 1))
                .onChangeCompat(of: text) { v in value = Int(v.filter { $0.isNumber }) ?? 0 }
                .onChangeCompat(of: value) { v in if !focused, fmt(v) != text { text = fmt(v) } }
                .onAppear { text = fmt(value) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Help & Guides (in-product user guide — DOD-3.7 / DOD-11.3)
//
// The buyer-facing guide set (docs/guides/) used to exist only in the repo, which a buyer never
// receives. This screen puts the same material INSIDE the product: getting started, a setup guide
// for every integration, permissions, recovery and uninstall — reachable from the sidebar and the
// iPhone More tab like every other section, with no download and no browser. Content states only
// what this build actually does; capability claims stay out (the dialer section says sending is
// not enabled, the MCP section names the Node.js prerequisite).
struct HelpGuideScreen: View {
    @State private var open: Set<String> = ["start"]

    private struct Topic: Identifiable {
        let id: String
        let title: String
        let icon: String
        let body: String
    }

    private let topics: [Topic] = [
        Topic(id: "start", title: "Getting started (quick start)", icon: "sparkles",
              body: """
              First launch offers three doors: create a local account (email + password, stored only on this device), continue as a guest, or open Sample Mode. Sample Mode loads a small synthetic workspace — every sample record says "Sample" and its exports are watermarked, so nothing synthetic can be mistaken for a county record. Your real workspace lives privately in the app's local store; it is never uploaded to Black Label.

              The natural first steps from empty: open List Builder and build a database-backed list (pick a list type, an area, filters — the count shows before anything is saved), or import your own CSV under My Leads. From a lead, the Deal Analyzer models ARV, rehab, MAO, ROI and cash flow.
              """),
        Topic(id: "lists", title: "How to use List Builder and My Leads", icon: "line.3.horizontal.decrease.circle.fill",
              body: """
              List Builder queries the public-records index live: choose a list type (absentee, estate-style owner, teardown, vacant land…), an area, and filters. The count is computed first so you see supply before saving. Saved lists land in My Leads, where each lead scores on the signal its list actually carried — an estate-style owner scores like probate, a teardown like a teardown. A lead the county published thinly says exactly that instead of pretending a match failed.
              """),
        Topic(id: "value", title: "Valuing a deal (ARV, comps, MAO)", icon: "function",
              body: """
              The ARV panel is source-labeled, always: green sold-comps treatment appears only when real recorded sales with county/index provenance back the number. A county-assessed figure is labeled an estimate, a synthetic Sample Mode set is labeled synthetic, and when no source produced a figure the panel gates honestly — no invented number, ever. MAO is computed from your own MAO percent in Settings.
              """),
        Topic(id: "permissions", title: "Permissions this app asks for", icon: "location.fill",
              body: """
              The app requests exactly one OS permission: Location, and only for Field Mode (logging drive-by canvassing stops and centering the map on you). Location never leaves this device. Everything else in the product works with location off. If you deny it, Field Mode shows exactly what still works and an Open Settings button that jumps straight to the Location Services pane; when you come back with access on, the screen confirms it.
              """),
        Topic(id: "integrations", title: "Setup guide: integrations you can connect", icon: "link",
              body: Self.integrationsBody),
        Topic(id: "recovery", title: "Recovery: where your data lives", icon: "externaldrive.fill",
              body: """
              Deals, leads, offers, drafts and settings live in the app's local database on this device. Lists and pipelines export to CSV from their screens; offers export as text LOIs. Settings → Account offers two levels of deletion: "Delete account" removes just the sign-in credential and keeps your workspace, while "Delete account & local data" erases the workspace, settings, registered county sources and every connected-provider key from the Keychain — permanently.
              """),
        Topic(id: "uninstall", title: "Uninstall", icon: "trash",
              body: Self.uninstallBody),
    ]

    // Platform-forked topics: the guide promises "this matches the build you are running", so a
    // topic must never carry instructions the device cannot follow (drag-to-Trash, Homebrew, or a
    // Claude/MCP panel that exists only in the Mac build).
    private static let integrationsBody: String = {
        let shared = """
        Everything optional, everything yours: a skip-trace provider (e.g. BatchData) for owner phone/email — gated until your key is connected, because free sources never carry those fields; a direct-mail vendor (Lob or PostGrid) to physically send letters; a Google OAuth client ID for Google sign-in; a Lead Database access key for uncapped index searches (without one, searches run on the capped preview tier). Keys are stored in this device's Keychain, never bundled or uploaded.

        Dialer & SMS records provider details and 10DLC paperwork only — sending is not enabled in this build, and the screen says so rather than showing a Ready it cannot back.
        """
        #if os(iOS)
        return shared
        #else
        return shared + """


        Claude / MCP: the read-only public-records MCP server ships inside the app bundle. It runs under Node.js. On this shipped app lane, Node.js is bundled with the app, so it works out of the box; if you are running a non-bundled build, install Node.js (free, nodejs.org or Homebrew) before pasting the config from Settings into Claude. The panel shows whether a Node runtime was found.
        """
        #endif
    }()

    private static let uninstallBody: String = {
        #if os(iOS)
        return """
        Touch and hold the app icon on the Home Screen, tap Remove App, then Delete App. Deleting the app also deletes its local workspace from this device. To clear your saved sign-in and connected-provider keys from the device Keychain first, use Settings → Account → "Delete account & local data" BEFORE deleting the app.
        """
        #else
        return """
        Quit the app and drag it from Applications to the Trash. To remove your data too, use Settings → Account → "Delete account & local data" BEFORE uninstalling — the workspace database and Keychain items belong to you and are not deleted by removing the app bundle.
        """
        #endif
    }()

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Help & Guides",
                          subtitle: "The built-in user guide — getting started, setup guide for every integration, and how to use each screen. Nothing to download; this matches the build you are running.")
            ForEach(topics) { topic in
                Panel(title: topic.title, icon: topic.icon) {
                    DisclosureGroup(isExpanded: Binding(
                        get: { open.contains(topic.id) },
                        set: { expanded in if expanded { open.insert(topic.id) } else { open.remove(topic.id) } }
                    )) {
                        Text(topic.body)
                            .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Text(open.contains(topic.id) ? "Hide" : "Read")
                            .font(BLFont.body(12, .bold)).foregroundColor(BLTheme.gold)
                    }
                    .accessibilityLabel(topic.title)
                }
            }
            Text("Every statement above describes this exact build. If a screen and this guide ever disagree, the screen is the truth — report the mismatch through Settings → Diagnostics.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
        }.blScreenPadding(28) }
    }
}
#endif // circuit-convert
