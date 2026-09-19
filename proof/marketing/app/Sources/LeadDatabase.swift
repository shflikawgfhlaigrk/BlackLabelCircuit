#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Lead Database (leads-as-a-service client).
//
// Searches the complete live 500k+ contactable-business catalog over the hosted API so a
// marketer can pull real, targetable prospects straight into their campaigns. Anonymous =
// masked preview (emails/phones blurred, Apollo-style free tier); a subscription token read
// read from the data-protection Keychain (LeadDBCredential; set in Settings → Lead Database)
// unlocks full contacts +
// one-tap "Add as recipient" into the CRM, where they become targetable contacts for segments,
// email campaigns, and spotlights.
//
// BINDINGS: zero fabrication — every figure here comes from the live API response, never
// invented. NO leads are bundled in the app; the catalog is queried live only. Default =
// masked preview until the buyer adds their own subscription key.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

enum LeadDB {
    static let base = "https://blacklabel-leads-api.michael-070.workers.dev"
    /// The legacy plaintext defaults key. The subscriber access token NO LONGER lives here —
    /// `LeadDBCredential` keeps it in the data-protection Keychain and erases this entry on first
    /// launch after the upgrade. The constant survives only because the retired Black Label Leads
    /// app wrote the same key in ITS OWN defaults domain, which the one-time carry-over reads.
    static let tokenKey = LeadDBCredential.legacyDefaultsKey

    /// A saved token is not a connection. Validate it against the same live, unmasked endpoint the
    /// database screen uses so Settings/Connectors never paints a non-empty but rejected key green.
    static func validateToken(_ rawToken: String) async -> LeadDBTokenValidation {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .init(valid: false, detail: "No subscription key saved.") }
        // Even a first-party endpoint is off this Mac: the key and the search terms are transmitted,
        // so the same recorded consent gate applies. (Sources/ProviderConsent.swift.)
        if let refusal = TransmissionConsentStore.refusal(for: .blackLabelLeads) {
            return .init(valid: false, detail: refusal)
        }
        var components = URLComponents(string: "\(base)/v1/leads")!
        components.queryItems = [
            .init(name: "has_email", value: "1"),
            .init(name: "per_page", value: "1"),
            .init(name: "page", value: "1")
        ]
        guard let url = components.url else { return .init(valid: false, detail: "The validation URL is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            // Through the choke point (Sources/ConsentedEgress.swift). It re-checks the grant
            // itself, so the gate above is the message and this is the wall.
            let (data, response) = try await ConsentedEgress.send(request, to: .blackLabelLeads)
            guard let http = response as? HTTPURLResponse else {
                return .init(valid: false, detail: "The lead service returned an invalid response.")
            }
            guard (200...299).contains(http.statusCode) else {
                return .init(valid: false, detail: http.statusCode == 401 || http.statusCode == 403
                    ? "That subscription key was rejected."
                    : "The lead service returned HTTP \(http.statusCode).")
            }
            guard let decoded = try? JSONDecoder().decode(LeadResponse.self, from: data), !decoded.masked else {
                return .init(valid: false, detail: "The key did not unlock contact details.")
            }
            return .init(valid: true, detail: "Subscription key validated against the live lead database.")
        } catch {
            return .init(valid: false, detail: "Couldn't validate the key: \(error.localizedDescription)")
        }
    }
}

struct LeadDBTokenValidation: Equatable {
    var valid: Bool
    var detail: String
}

/// The catalog wire model (`LeadRecord` / `LeadResponse` / `taxonomyLabel` / `LeadFacets`) lives in
/// Sources/LeadCatalog.swift — a Foundation-only file so it unit-tests without SwiftUI. The mapping
/// into the app's unified `Lead` stays here, where `Lead` + the design system are in scope.
extension LeadRecord {
    func toLead() -> Lead {
        let contactName = (contact_name?.isEmpty == false ? contact_name : nil) ?? name ?? ""
        let place = [city, state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let note = [industry, subcategory, category, subtype, deliv_tier]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
        return Lead(
            name: contactName,
            company: name ?? "",
            email: email ?? "",
            notes: note,
            phone: phone ?? "",
            address: place,
            source: .database,
            sourceCampaign: "Lead Database",
            industry: industry ?? category ?? "")
    }
}

@MainActor
final class LeadDBStore: ObservableObject {
    static let perPage = 100

    @Published var results: [LeadRecord] = []
    @Published var total = 0
    @Published var page = 1
    @Published var masked = true
    @Published var loading = false
    @Published var error = ""
    @Published var industries: [(String, Int)] = []
    @Published var subcategories: [(String, Int)] = []
    @Published var states: [(String, Int)] = []

    @Published var query = ""
    @Published var industry = ""
    @Published var subcategory = ""
    @Published var state = ""

    private var searchGeneration = 0
    /// One credential re-issue per rejection streak — reset by any successful fetch — so a
    /// server that keeps answering 401 can never drive a relink/retry loop.
    private var credentialReissueTried = false

    var pageCount: Int { max(1, Int(ceil(Double(max(0, total)) / Double(Self.perPage)))) }
    var rangeLabel: String {
        guard total > 0, !results.isEmpty else { return "0 loaded" }
        let start = (page - 1) * Self.perPage + 1
        let end = min(total, start + results.count - 1)
        return "Showing \(start.formatted())–\(end.formatted()) of \(total.formatted())"
    }

    private func token() -> String {
        LeadDBCredential.token
    }

    private func request(page requestedPage: Int) -> URLRequest {
        var c = URLComponents(string: "\(LeadDB.base)/v1/leads")!
        var q = [URLQueryItem(name: "has_email", value: "1"),
                 URLQueryItem(name: "per_page", value: String(Self.perPage)),
                 URLQueryItem(name: "page", value: String(requestedPage))]
        if !query.isEmpty { q.append(.init(name: "q", value: query)) }
        if !industry.isEmpty { q.append(.init(name: "industry", value: industry)) }
        if !subcategory.isEmpty { q.append(.init(name: "subcategory", value: subcategory)) }
        if !state.isEmpty { q.append(.init(name: "state", value: state)) }
        c.queryItems = q
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        let t = token()
        if !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func fetch(page requestedPage: Int) async throws -> LeadResponse {
        if let refusal = TransmissionConsentStore.refusal(for: .blackLabelLeads) {
            throw LeadDBRequestError.consentRequired(refusal)
        }
        let (d, response): (Data, URLResponse)
        do { (d, response) = try await ConsentedEgress.send(request(page: requestedPage), to: .blackLabelLeads) }
        catch let refusal as ConsentedEgressError { throw LeadDBRequestError.consentRequired(refusal.errorDescription ?? "Nothing was sent.") }
        guard let http = response as? HTTPURLResponse else { throw LeadDBRequestError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw LeadDBRequestError.http(http.statusCode) }
        return try JSONDecoder().decode(LeadResponse.self, from: d)
    }

    func loadFacets() async {
        var components = URLComponents(string: "\(LeadDB.base)/v1/facets")!
        var query = [URLQueryItem(name: "taxonomy", value: "2")]
        if !industry.isEmpty { query.append(.init(name: "industry", value: industry)) }
        components.queryItems = query
        guard let url = components.url, TransmissionConsentStore.refusal(for: .blackLabelLeads) == nil else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let t = token(); if !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let (d, _) = try? await ConsentedEgress.send(req, to: .blackLabelLeads),
           let f = LeadFacets.decode(d) {
            total = f.total
            industries = f.industries.map { ($0.industry, $0.n) }
            subcategories = f.subcategoryOptions
            states = f.states.compactMap { s in s.state.map { ($0, s.n) } }
        }
    }

    func search(page requestedPage: Int = 1) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        loading = true; error = ""
        do {
            let r = try await fetch(page: max(1, requestedPage))
            guard generation == searchGeneration else { return }
            // Constant-memory window: the complete catalog remains reachable page-by-page, but the
            // UI never retains or republishes hundreds of thousands of LeadRecord values.
            results = r.results
            page = r.page
            total = r.total
            masked = r.masked
            credentialReissueTried = false
        } catch {
            guard generation == searchGeneration else { return }
            if case LeadDBRequestError.consentRequired(let refusal) = error {
                self.error = refusal
            } else if case LeadDBRequestError.http(let status) = error {
                if status == 401 || status == 403 {
                    #if !DIRECT_DISTRIBUTION
                    // Store builds have no pasted-key panel: a rejected credential is recovered by
                    // dropping it and re-issuing from the live App Store entitlement, then retrying
                    // once. Not entitled → the clear alone restores the masked preview tier.
                    if !credentialReissueTried {
                        credentialReissueTried = true
                        await LeadDBSubscriptionStore.shared.reissueCatalogCredential()
                        await search(page: requestedPage)
                        return
                    }
                    self.error = "The access credential was rejected. Use Restore Purchases on the subscribe card to re-issue it."
                    #else
                    self.error = "The saved Lead Database key was rejected. Revalidate it in Connectors."
                    #endif
                } else {
                    self.error = "The lead database returned HTTP \(status). Try again."
                }
            } else {
                self.error = "Couldn't reach the lead database. Check your connection."
            }
        }
        if generation == searchGeneration { loading = false }
    }

    func nextPage() async { guard page < pageCount else { return }; await search(page: page + 1) }
    func previousPage() async { guard page > 1 else { return }; await search(page: page - 1) }
}

private enum LeadDBRequestError: Error {
    case badResponse
    case http(Int)
    case consentRequired(String)
}

struct LeadDatabaseScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var store = LeadDBStore()
    @State private var imported = Set<Int>()
    @State private var crmEmailIndex = Set<String>()
    @State private var importNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            filters
            if store.masked {
                // Store builds (iOS App Store AND Mac App Store): the in-app StoreKit 2 subscribe
                // surface is the ONLY unlock — no pasted key (Guideline 3.1.1; rejected on iOS
                // b23→b25 and macOS build 61). The Developer-ID / direct lane
                // (-D DIRECT_DISTRIBUTION) keeps the key banner pointing at Settings.
                #if !DIRECT_DISTRIBUTION
                LeadDBSubscribeCard(onUnlocked: { await store.loadFacets(); await store.search() })
                #else
                unlockBanner
                #endif
            } else { bulkAddBar }
            pageBar
            if !store.error.isEmpty {
                Text(store.error).font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.danger)
            }
            if !importNote.isEmpty {
                Text(importNote).font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.green)
            }
            list
        }
        .padding(22)
        .task { await store.loadFacets(); await store.search() }
        .onReceive(model.$leads) { leads in
            crmEmailIndex = Set(leads.lazy.map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        }
    }

    /// Rows on the current page that can still be added (unlocked, have an email, not already a
    /// recipient). Computed off the loaded page only — we never fabricate counts for unloaded rows.
    private var addableRows: [LeadRecord] {
        guard !store.masked else { return [] }
        return store.results.filter { r in
            guard let e = r.email, !e.isEmpty else { return false }
            return !imported.contains(r.id) && !alreadyInCRM(r)
        }
    }

    /// Bulk "Add all" bar — adds every addable row on the loaded results in one tap, so a marketer
    /// can pull a whole filtered segment into their campaigns without clicking row-by-row. De-dupe
    /// and email-presence checks are the SAME as the per-row Add, so this can't create duplicates or
    /// add a contactless row. Real catalog data only; nothing invented.
    @ViewBuilder private var bulkAddBar: some View {
        let addable = addableRows
        HStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill").foregroundColor(BLTheme.gold)
            Text(addable.isEmpty
                 ? "All loaded results are already campaign recipients."
                 : "\(addable.count) loaded result\(addable.count == 1 ? "" : "s") can be added as recipients in one tap.")
                .font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.sub)
            Spacer()
            if !addable.isEmpty {
                Button {
                    importRows(addable)
                } label: {
                    Text("Import \(addable.count) loaded").font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(BLTheme.goldGrad, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(BLTheme.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
    }

    private var pageBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill").foregroundColor(BLTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.rangeLabel)
                    .font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.sub)
                Text(store.masked
                     ? "Preview rows are masked until full contacts are unlocked."
                     : "All matching records remain available through bounded 100-row pages; only this page is held in memory.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            GhostButton(label: "Previous", icon: "chevron.left") { Task { await store.previousPage() } }
                .disabled(store.loading || store.page <= 1)
            Text("Page \(store.page.formatted()) of \(store.pageCount.formatted())")
                .font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.sub)
            GhostButton(label: "Next", icon: "chevron.right") { Task { await store.nextPage() } }
                .disabled(store.loading || store.page >= store.pageCount)
            if !store.masked && !addableRows.isEmpty {
                Button {
                    importRows(addableRows)
                } label: {
                    Text("Import this page")
                        .font(BLFonts.mono(12, weight: .bold))
                        .foregroundColor(BLTheme.inkOnGold)
                        .padding(.vertical, 8).padding(.horizontal, 13)
                        .background(BLTheme.goldGrad, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                FoilText("Lead Database", size: 26, weight: .bold)
                Text(store.total > 0 ? "\(store.total.formatted()) matching businesses — verify each email before sending; add them straight to your campaigns"
                                     : "Search the curated lead catalog for campaign-ready prospects")
                    .font(BLFonts.mono(12.5, weight: .medium)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            TextField("Search name or email…", text: $store.query)
                .textFieldStyle(.plain).font(BLFonts.mono(13, weight: .medium)).foregroundColor(BLTheme.text)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                .onSubmit { Task { await store.search() } }
            picker("Industry", selection: $store.industry, options: store.industries) { value in
                store.industry = value
                store.subcategory = ""
                Task { await store.loadFacets(); await store.search() }
            }
            picker("Subcategory", selection: $store.subcategory, options: store.subcategories) { value in
                store.subcategory = value
                Task { await store.search() }
            }
            .disabled(store.industry.isEmpty)
            .opacity(store.industry.isEmpty ? 0.55 : 1)
            picker("State", selection: $store.state, options: store.states) { value in
                store.state = value
                Task { await store.search() }
            }
            Button { Task { await store.search() } } label: {
                Text("Search").font(BLFonts.mono(13, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .padding(.vertical, 9).padding(.horizontal, 16)
                    .background(BLTheme.goldGrad, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(.plain)
        }
    }

    private func picker(_ title: String, selection: Binding<String>, options: [(String, Int)], onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            Button("All \(title)s") { onSelect("") }
            ForEach(options, id: \.0) { opt in
                Button("\(taxonomyLabel(opt.0)) (\(opt.1.formatted()))") { onSelect(opt.0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.wrappedValue.isEmpty ? title : taxonomyLabel(selection.wrappedValue))
                    .font(BLFonts.mono(12.5, weight: .semibold)).foregroundColor(BLTheme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(BLTheme.sub)
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var unlockBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundColor(BLTheme.gold)
            Text("Preview — emails & phones are masked. Add your subscription key in Settings → Lead Database to unlock full contacts and add them as campaign recipients.")
                .font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.sub)
            Spacer()
        }
        .padding(11)
        .background(BLTheme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if store.results.isEmpty && !store.loading && store.error.isEmpty {
                    EmptyState(icon: "building.2.crop.circle",
                               title: "No matching businesses",
                               hint: "Adjust your search or industry/subcategory/state filters to find campaign-ready prospects in the live catalog.")
                        .frame(maxWidth: .infinity)
                }
                ForEach(store.results) { r in row(r) }
            }
        }
    }

    private func row(_ r: LeadRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name ?? "(unnamed)").font(BLFonts.mono(14, weight: .semibold)).foregroundColor(BLTheme.text)
                HStack(spacing: 8) {
                    if let e = r.email { label(e, "envelope.fill") }
                    if let p = r.phone, !p.isEmpty { label(p, "phone.fill") }
                }
                HStack(spacing: 8) {
                    if let i = r.industry, !i.isEmpty { tag(taxonomyLabel(i)) }
                    if let s = r.subcategory, !s.isEmpty { tag(taxonomyLabel(s)) }
                    if let city = r.city, let st = r.state { Text("\(city), \(st)").font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.sub) }
                    if let d = r.deliv_tier { tag(d) }
                }
            }
            Spacer()
            addButton(r)
        }
        .padding(12)
        .background(BLTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func label(_ s: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundColor(BLTheme.sub)
            Text(s).font(BLFonts.mono(11.5, weight: .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
        }
    }
    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
            .padding(.vertical, 3).padding(.horizontal, 7)
            .background(BLTheme.gold.opacity(0.10), in: Capsule())
    }

    /// "Add as recipient" — masked rows show a lock (unlock with a key); unlocked rows import the
    /// business into the buyer's own CRM as a CapturedLead, which makes it a targetable contact for
    /// segments, email campaigns, and spotlights (see Audience.allContacts). De-dupes on email so a
    /// re-import never duplicates a recipient.
    @ViewBuilder private func addButton(_ r: LeadRecord) -> some View {
        if store.masked {
            Image(systemName: "lock.fill").foregroundColor(BLTheme.sub).font(.system(size: 13))
        } else if imported.contains(r.id) || alreadyInCRM(r) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(BLTheme.gold).font(.system(size: 15))
                Text("Added").font(BLFonts.mono(11.5, weight: .semibold)).foregroundColor(BLTheme.sub)
            }
        } else {
            Button {
                addRecipient(r)
                imported.insert(r.id)
            } label: {
                Text("Add as recipient").font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .padding(.vertical, 7).padding(.horizontal, 13)
                    .background(BLTheme.goldGrad, in: Capsule())
            }.buttonStyle(.plain)
        }
    }

    /// Already imported in a prior session? Match on lowercased email (the contact key Audience uses).
    private func alreadyInCRM(_ r: LeadRecord) -> Bool {
        guard let e = r.email?.lowercased(), !e.isEmpty else { return false }
        return crmEmailIndex.contains(e)
    }

    /// Import a catalog business into the CRM as a campaign recipient (a unified Lead). Tags the
    /// source so the buyer can segment on "Lead Database". Only real API fields are stored.
    private func addRecipient(_ r: LeadRecord) {
        guard !alreadyInCRM(r) else { return }
        model.addLead(r.toLead())
        if let email = r.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            crmEmailIndex.insert(email)
        }
    }

    private func importRows(_ rows: [LeadRecord]) {
        var added = 0
        var knownEmails = crmEmailIndex
        model.batch {
            for r in rows {
                guard let email = r.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !email.isEmpty, knownEmails.insert(email).inserted else { continue }
                model.addLead(r.toLead())
                imported.insert(r.id)
                added += 1
            }
        }
        crmEmailIndex = knownEmails
        importNote = "Imported \(added.formatted()) lead\(added == 1 ? "" : "s") into CRM Leads."
    }
}
#endif // circuit-convert
