#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — REVIEWER / BUYER DEMO DATA (synthetic, clearly-labeled, gated).
//
// WHY THIS EXISTS
// An App Store reviewer (and any prospective buyer) must be able to exercise the FULL app with
// ZERO external accounts. Real mode starts EMPTY on the buyer's own data (ship-no-data rule).
// Demo mode loads the synthetic dataset below INTO MEMORY ONLY so every screen looks populated.
//
// SHIP-NO-DATA IS PRESERVED, by construction:
//   • This is generated CODE, not a bundled data file — no leads/contacts/DB dump ships.
//   • It is loaded ONLY when Session.demoMode is on (the "Explore with sample data" guest path).
//   • AppModel.loadDemo() writes it to the in-memory @Published arrays and SUPPRESSES persistence,
//     so nothing demo ever touches the Postgres workspace. Quit demo → it's gone. Real accounts stay empty.
//   • Every record is unmistakably SAMPLE data: each visible name carries a "(Sample)" tag, phones
//     use the reserved 555-01xx fictional range, and emails use the reserved .example / .test TLDs
//     (RFC 2606 / RFC 6761 — guaranteed to never resolve to a real mailbox). Nothing traces to a
//     real person or parcel.
//   • These are NOT presented as real metrics — the UI shows a persistent "SAMPLE DATA" banner in
//     demo mode (see MainView), so a reviewer/buyer never mistakes it for live data.
//
// NAMING POLICY (reviewer-facing): names read like real prospects/clients a real estate investor
// would actually work — believable estates, owners, builders and cash-buyer firms with on-brand
// names and real-looking addresses — each suffixed "(Sample)" so it's honest, not a generated
// "Demo Foo" placeholder and never a stock filler like Acme/Northwind/Contoso.
//
// A hard env override (BLRE_NO_DEMO=1) can compile-in-but-disable the entry point for a paranoid
// shipping build; demo is otherwise always available as the guest path the reviewer needs.
import Foundation

enum DemoData {

    /// Master switch. Demo is available unless the environment hard-disables it. We keep this as a
    /// runtime check (not #if) so the SAME binary the reviewer runs is the one that ships.
    static var isAvailable: Bool { ProcessInfo.processInfo.environment["BLRE_NO_DEMO"] != "1" }

    /// A visible, unambiguous label the UI repeats wherever demo data appears.
    static let banner = "SAMPLE DATA — synthetic demo. Not real leads. Sign in to use your own data."

    // Stable demo team so round-robin / assignment screens are populated and lead.assignedTo resolves.
    static let team: [TeamMember] = [
        TeamMember(name: "Avery Stone (Sample)", email: "avery@blacklabel.example", role: "Acquisitions"),
        TeamMember(name: "Jordan Cole (Sample)",  email: "jordan@blacklabel.example", role: "Dispositions"),
    ]

    // ---- LEADS -----------------------------------------------------------------------------------
    // A realistic spread across sources, stages, counties, values, with phones/emails/mailing so the
    // List Builder filters, Work Queue scoring, Pipeline kanban, Skip Trace and Map all have signal.
    static func leads(team: [TeamMember]) -> [Lead] {
        let rr = team.first?.id          // Avery
        let rr2 = team.count > 1 ? team[1].id : nil   // Jordan
        let now = Date()
        func days(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now }

        var out: [Lead] = []

        func L(_ name: String, _ county: String, _ src: LeadSource, _ srcDetail: String,
               phone: String = "", email: String = "", situs: String = "", mailing: String = "",
               owner: String = "", assessed: Int = 0, land: Int = 0, parcel: String = "",
               conf: String = "", status: LeadStatus = .new, notes: String = "",
               lat: Double? = nil, lng: Double? = nil, assignee: UUID? = nil,
               age: Int = 7, tasks: [LeadTask] = []) -> Lead {
            var l = Lead(name: name, county: county, source: src, sourceDetail: srcDetail)
            l.phone = phone; l.email = email; l.propertyAddress = situs; l.mailingAddress = mailing
            l.ownerName = owner; l.assessedValue = assessed; l.landValue = land; l.parcel = parcel
            l.ownershipConfidence = conf; l.status = status; l.notes = notes
            l.lat = lat; l.lng = lng; l.assignedTo = assignee; l.created = days(age); l.tasks = tasks
            // A small, honest activity trail so the timeline view is populated.
            l.activity.append(ActivityEvent(kind: .created, detail: "Added from \(src.label) · \(county)", at: days(age)))
            if status != .new {
                l.activity.append(ActivityEvent(kind: .statusChange, detail: "New → \(status.label)", at: days(max(0, age - 2))))
            }
            out.append(l)
            return l
        }

        // Probate (the flagship source) — warm, motivated, resolved parcels.
        _ = L("Estate of Harold W. Pennington (Sample)", "Hall County", .probate, "Probate notice",
              phone: "(770) 555-0100", email: "executor@penningtonestate.example",
              situs: "418 Magnolia Ridge Ln, Gainesville", mailing: "44 Oak Hollow Ct, Gainesville",
              owner: "Pennington Family Trust (Sample)", assessed: 184_500, parcel: "SAMPLE-001-A",
              conf: "high", status: .contacted, notes: "Heir wants a fast as-is close; cleanout included.",
              lat: 34.2979, lng: -83.8241, assignee: rr, age: 21,
              tasks: [LeadTask(text: "Call executor back Tuesday", due: now.addingTimeInterval(86400), done: false)])
        _ = L("Estate of Marguerite Laughlin (Sample)", "Hall County", .probate, "Probate notice",
              phone: "(770) 555-0101", situs: "212 Birchwood St, Gainesville",
              mailing: "212 Birchwood St, Gainesville", owner: "M. Laughlin Estate (Sample)",
              assessed: 142_000, parcel: "SAMPLE-002-B", conf: "medium", status: .appointment,
              notes: "Appointment set; needs probate court date confirmation.",
              lat: 34.3105, lng: -83.8390, assignee: rr2, age: 14)
        _ = L("Estate of Theodore Brandt (Sample)", "Forsyth County", .probate, "Probate notice",
              phone: "(770) 555-0102", email: "tbrandt.heirs@brandtfamily.example",
              situs: "9 Willow Bend Way, Cumming", mailing: "1500 Pine Crest Blvd, Atlanta",
              owner: "Brandt Heirs (Sample)", assessed: 96_800, parcel: "SAMPLE-003-C", conf: "high",
              status: .negotiating, notes: "Absentee heirs; verbal at $72k. Spread looks strong.",
              lat: 34.2640, lng: -83.7720, assignee: rr, age: 30)

        // Teardown / lot-flip (the Lot-Flip Scout play) — land-heavy, low improvement.
        _ = L("6232 Stephens Mill Rd — teardown lot (Sample)", "Hall County", .teardown, "Lot-Flip Scout",
              situs: "6232 Stephens Mill Rd, Gainesville", owner: "Stephens Mill Holdings LLC (Sample)",
              assessed: 88_000, land: 76_000, parcel: "SAMPLE-LOT-87", conf: "high", status: .new,
              notes: "Improvement/land ratio flags a teardown. Scout score 87 (Prime).",
              lat: 34.3520, lng: -83.9011, assignee: rr, age: 4)
        _ = L("18 Ridgeline Pkwy — infill lot (Sample)", "Hall County", .teardown, "Lot-Flip Scout",
              situs: "18 Ridgeline Pkwy, Gainesville", owner: "Ridgeline Land Partners (Sample)",
              assessed: 110_000, land: 95_000, parcel: "SAMPLE-LOT-91", conf: "medium", status: .new,
              notes: "Builder infill candidate; verify zoning for split.",
              lat: 34.3601, lng: -83.8890, age: 6)

        // Absentee owner — mailing != situs.
        _ = L("Priya Anand (Sample)", "Forsyth County", .absentee, "Absentee owner",
              phone: "(770) 555-0110", email: "priya.anand@mailinator.example",
              situs: "77 Cedar Crest Dr, Cumming", mailing: "9001 Coastal Hwy, Wilmington",
              owner: "Priya Anand (Sample)", assessed: 156_000, parcel: "SAMPLE-004-D", conf: "medium",
              status: .contacted, notes: "Out-of-state landlord; tired of management.",
              lat: 34.2710, lng: -83.7990, assignee: rr2, age: 11)

        // Tax delinquent.
        _ = L("Wendell Krauss (Sample)", "Hall County", .taxDelinquent, "Tax delinquent list",
              phone: "(770) 555-0111", situs: "305 Elm Street, Gainesville",
              mailing: "305 Elm Street, Gainesville", owner: "W. Krauss (Sample)",
              assessed: 73_500, parcel: "SAMPLE-005-E", conf: "low", status: .new,
              notes: "2 years delinquent; high motivation signal.",
              lat: 34.2999, lng: -83.8155, age: 3)

        // Pre-foreclosure.
        _ = L("Sofia Marlowe (Sample)", "Forsyth County", .preForeclosure, "Pre-foreclosure",
              phone: "(770) 555-0112", email: "sofia.marlowe@mailinator.example",
              situs: "1422 Aspen Court, Cumming", mailing: "1422 Aspen Court, Cumming",
              owner: "S. Marlowe (Sample)", assessed: 199_000, parcel: "SAMPLE-006-F", conf: "medium",
              status: .negotiating, notes: "NOD filed; wants to avoid auction. Time-sensitive.",
              lat: 34.2588, lng: -83.7841, assignee: rr, age: 9)

        // New construction / builder.
        _ = L("Cedar Grove Builders (Sample)", "Hall County", .builder, "New construction permit",
              phone: "(770) 555-0113", email: "land@cedargrovebuilders.example",
              owner: "Cedar Grove Builders LLC (Sample)", status: .contacted,
              notes: "Actively buying infill lots in Hall County. Good dispo buyer too.",
              assignee: rr2, age: 18)

        // Won deal (so Pipeline 'Won' lane + analytics have signal).
        _ = L("Estate of Calvin Reyes (Sample)", "Hall County", .probate, "Probate notice",
              phone: "(770) 555-0114", situs: "58 Maple Avenue, Gainesville",
              mailing: "58 Maple Avenue, Gainesville", owner: "Reyes Estate (Sample)",
              assessed: 168_000, parcel: "SAMPLE-007-G", conf: "high", status: .won,
              notes: "Under contract at $118k; assigned to Cedar Grove Builders.",
              lat: 34.3040, lng: -83.8302, assignee: rr, age: 45)

        // A dead lead so the 'Dead' filter isn't empty.
        _ = L("Bert Halloway (Sample)", "Forsyth County", .absentee, "Absentee owner",
              phone: "(770) 555-0115", situs: "11 Spruce Lane, Cumming",
              owner: "B. Halloway (Sample)", assessed: 64_000, status: .dead,
              notes: "Listed with an agent — not a fit. Kept for records.",
              lat: 34.2530, lng: -83.7905, age: 60)

        return out
    }

    // ---- DEALS -----------------------------------------------------------------------------------
    // Every demo deal carries sample coordinates (offset ~400m from its source lead so the deal's green marker
    // reads separately from the lead pin at the demo cluster zoom (not buried underneath)) — the map must place each demo record instantly, with zero
    // geocoder network calls at demo time. The addresses are synthetic and never resolve on OSM.
    static func deals(now: Date = Date()) -> [Deal] {
        func days(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now }
        var ds: [Deal] = []

        var flip = Deal()
        flip.sampleFixtureID = "sample-deal-flip"
        flip.address = "418 Magnolia Ridge Ln, Gainesville"; flip.county = "Hall County"
        flip.arv = 245_000; flip.arvSource = "County-assessed + 3-mi comps (sample)"; flip.repairs = 38_000
        flip.asking = 132_000; flip.status = .underContract; flip.exit = .flip; flip.sqft = 1_640
        flip.rehabLevel = .moderate; flip.holdingMonths = 5; flip.monthlyCarry = 850
        flip.notes = "Sample flip — probate, motivated heir. Sample numbers."; flip.created = days(20)
        flip.lat = 34.3017; flip.lng = -83.8229
        ds.append(flip)

        var rental = Deal()
        rental.sampleFixtureID = "sample-deal-rental"
        rental.address = "77 Cedar Crest Dr, Cumming"; rental.county = "Forsyth County"
        rental.arv = 198_000; rental.arvSource = "County-assessed (parcel) — sample"; rental.repairs = 22_000
        rental.asking = 121_000; rental.status = .analyzing; rental.exit = .rental; rental.sqft = 1_320
        rental.rehabLevel = .light; rental.monthlyRent = 1_750; rental.monthlyOpEx = 520
        rental.downPct = 25; rental.apr = 7.25; rental.notes = "Sample BRRRR / hold — absentee landlord."
        rental.created = days(12); rental.lat = 34.2748; rental.lng = -83.7978
        ds.append(rental)

        var wholesale = Deal()
        wholesale.sampleFixtureID = "sample-deal-wholesale"
        wholesale.address = "9 Willow Bend Way, Cumming"; wholesale.county = "Forsyth County"
        wholesale.arv = 165_000; wholesale.arvSource = "Area value avg (sample)"; wholesale.repairs = 45_000
        wholesale.asking = 72_000; wholesale.status = .offer; wholesale.exit = .wholesale
        wholesale.assignmentFee = 12_000; wholesale.notes = "Sample wholesale — assign to a cash buyer."
        wholesale.created = days(6); wholesale.lat = 34.2678; wholesale.lng = -83.7708
        ds.append(wholesale)

        var won = Deal()
        won.sampleFixtureID = "sample-deal-won"
        won.address = "58 Maple Avenue, Gainesville"; won.county = "Hall County"
        won.arv = 215_000; won.arvSource = "County-assessed + comps (sample)"; won.repairs = 30_000
        won.asking = 118_000; won.status = .won; won.exit = .flip; won.sqft = 1_500
        won.rehabLevel = .moderate; won.notes = "Sample closed deal — under contract, assigned."
        won.created = days(40); won.lat = 34.3078; won.lng = -83.8290
        ds.append(won)

        return ds
    }

    // ---- COMPLETED ANALYSIS --------------------------------------------------------------------
    // The standalone Analyzer used to ignore the populated Sample Mode model and open on a blank
    // Deal(). This subject + comp set makes the actual analyzer/MAO UI capture-ready without a live
    // county request. Every row says Sample, uses synthetic addresses, and carries `.sample`
    // provenance so it can never be mistaken for a county-record pull.
    static func analysisDeal(from deals: [Deal]) -> Deal {
        deals.first ?? Deal()
    }

    static func analysisComps(for deal: Deal) -> CompsResult {
        let subjectSqft = deal.sqft > 0 ? deal.sqft : 1_640
        let targetARV = deal.arv > 0 ? Int(deal.arv.rounded()) : 245_000
        let medianPerSqft = Double(targetARV) / subjectSqft
        let sizes: [Double] = [1_520, 1_610, 1_690, 1_780]
        let comps = sizes.enumerated().map { index, sqft in
            SaleComp(address: "\(120 + index * 37) Sample Comparable Way (Sample)",
                     salePrice: Int((sqft * medianPerSqft).rounded()),
                     saleYear: 2026, saleMonth: max(1, 7 - index), sqft: sqft,
                     distanceMiles: 0.6 + Double(index) * 0.5, assessedValue: nil)
        }
        return CompsResult(available: true, basis: .sampleEstimate, arv: targetARV,
                           perSqft: medianPerSqft, comps: comps, radiusMiles: 3,
                           note: "Synthetic sample comparable set for Sample Mode — illustrates the completed ARV workflow only; these are not county records or real sales.",
                           source: .sample)
    }

    // ---- SAMPLE DEPOT --------------------------------------------------------------------------
    // Sample records already carry synthetic coordinates, and this is the matching synthetic
    // DEPOT. It is a labeled invention ("(Sample)"), so no public index carries it — the sample
    // route would otherwise have no start point at all.
    static let routeDepotAddress = "100 Sample Depot Way, Gainesville (Sample)"
    static let routeDepotCoordinate = (34.3004, -83.8352)

    /// A geocoder that resolves EXACTLY the one labeled sample depot offline and defers every
    /// other address to the caller's real geocoder. Scoped this narrowly on purpose: Sample Mode
    /// substitutes a start point, never a route — the mileage and visit order still come from the
    /// same RoutePlanner a buyer's live run uses, and a real address the buyer types is never
    /// intercepted.
    static func routeGeocoder(otherwise: @escaping (String) async -> (Double, Double)?)
        -> (String) async -> (Double, Double)? {
        { address in address == routeDepotAddress ? routeDepotCoordinate : await otherwise(address) }
    }

    // ---- CASH BUYERS (dispositions) --------------------------------------------------------------
    static func buyers() -> [CashBuyer] {
        var a = CashBuyer(); a.name = "Cedar Grove Builders (Sample)"; a.email = "buy@cedargrovebuilders.example"
        a.phone = "(770) 555-0120"; a.markets = "Hall County, Forsyth County"; a.counties = ["Hall County", "Forsyth County"]
        a.criteria = "Infill lots + light flips. As-is, fast close."; a.minPrice = 60_000; a.maxPrice = 260_000
        a.strategies = [.flip, .wholesale]; a.pofVerified = true; a.pofLabel = "Bank letter (sample)"
        a.pofVerifiedDate = Date()

        var b = CashBuyer(); b.name = "Harborview Capital (Sample)"; b.email = "deals@harborviewcapital.example"
        b.phone = "(770) 555-0121"; b.markets = "Forsyth County"; b.counties = ["Forsyth County"]
        b.criteria = "Buy-and-hold rentals, 1%+ rule."; b.minPrice = 80_000; b.maxPrice = 220_000
        b.strategies = [.rental]; b.pofVerified = false; b.pofLabel = ""

        var c = CashBuyer(); c.name = "Summit Ridge Acquisitions (Sample)"; c.email = "acq@summitridgeacq.example"
        c.phone = "(770) 555-0122"; c.markets = "Hall County, Forsyth County"; c.counties = ["Hall County", "Forsyth County"]
        c.criteria = "Anything with spread. Wholesale-friendly."; c.minPrice = 40_000; c.maxPrice = 300_000
        c.strategies = []; c.pofVerified = true; c.pofLabel = "Proof of funds on file (sample)"; c.pofVerifiedDate = Date()
        return [a, b, c]
    }

    // ---- OFFERS / LOI ----------------------------------------------------------------------------
    static func offers(for deals: [Deal]) -> [Offer] {
        let inNegotiation: Deal? = deals.first(where: { $0.exit == ExitStrategy.flip && $0.status == DealStatus.underContract })
        guard let primary: Deal = inNegotiation ?? deals.first else { return [] }
        let wonDeal: Deal = deals.first(where: { $0.status == DealStatus.won }) ?? primary

        var o = Offer(dealID: primary.id)
        o.sampleFixtureID = primary.sampleFixtureID
        o.propertyAddress = primary.address
        o.buyerName = "Blackstone Oak Acquisitions (Sample)"
        o.sellerName = "Pennington Family Trust (Sample)"
        o.amount = 128_000
        o.earnestMoney = 2_500
        o.closingDays = 21
        o.inspectionDays = 7
        o.status = .draft

        var o2 = Offer(dealID: wonDeal.id)
        o2.sampleFixtureID = wonDeal.sampleFixtureID
        o2.propertyAddress = "58 Maple Avenue, Gainesville"
        o2.buyerName = "Blackstone Oak Acquisitions (Sample)"
        o2.sellerName = "Reyes Estate (Sample)"
        o2.amount = 118_000
        o2.earnestMoney = 5_000
        o2.closingDays = 30
        o2.status = .draft

        return [o, o2]
    }

    // ---- SMART LISTS (List Builder) --------------------------------------------------------------
    static func smartLists(from leads: [Lead]) -> [SmartList] {
        var probate = SmartList(); probate.name = "Probate — high confidence (Sample)"
        var pf = LeadFilter(); pf.sources = [.probate]; pf.ownershipConfidence = ["high"]; probate.filter = pf

        var absentee = SmartList(); absentee.name = "Absentee + mail-ready (Sample)"
        var af = LeadFilter(); af.absenteeOnly = true; af.hasMailingAddress = true; absentee.filter = af

        var hot = SmartList(); hot.name = "Negotiating now (Sample)"
        var hf = LeadFilter(); hf.statuses = [.negotiating, .appointment]; hot.filter = hf

        // Stamp current members so the list shows a real count immediately.
        var lists = [probate, absentee, hot]
        for i in lists.indices {
            lists[i].memberIDs = Set(leads.filter { lists[i].filter.matches($0) }.map { $0.id })
            lists[i].lastSynced = Date()
        }
        return lists
    }

    // ---- DIRECT-MAIL SEQUENCE + ENROLLMENTS ------------------------------------------------------
    static func mailSequence() -> MailSequence {
        var s = MailSequence(name: "Probate 4-touch (Sample)")
        s.touches = [
            MailTouch(dayOffset: 0,  kind: .postcard,    template: "Hi {{name}}, I help families with {{property}} in {{county}}. As-is cash, no cleanout. Reply STOP to opt out."),
            MailTouch(dayOffset: 14, kind: .yellowLetter, template: "Hi {{name}}, following up on {{property}}. I can close on your timeline. — Blackstone Oak Acquisitions"),
            MailTouch(dayOffset: 30, kind: .typedLetter,  template: "Dear {{name}}, a fair, no-obligation cash offer for {{property}} still stands. Blackstone Oak Acquisitions LLC."),
            MailTouch(dayOffset: 45, kind: .postcard,     template: "Last note, {{name}} — if selling {{property}} would help, call anytime. Reply STOP to opt out."),
        ]
        return s
    }
    static func enrollments(sequence: MailSequence, leads: [Lead]) -> [MailEnrollment] {
        // Enroll the probate leads so the Direct Mail "due pieces" queue is populated.
        leads.filter { $0.source == .probate && $0.status != .dead }.prefix(3).map {
            var e = MailEnrollment(leadID: $0.id, sequenceID: sequence.id)
            e.enrolledOn = Calendar.current.date(byAdding: .day, value: -20, to: Date()) ?? Date()
            return e
        }
    }

    // ---- MARKETING SPEND + EXPENSES (Deal Accounting) --------------------------------------------
    static func spend() -> [MarketingSpend] {
        func days(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date() }
        return [
            { var s = MarketingSpend(); s.channel = .directMail; s.campaign = "Probate postcards (Sample)"; s.amount = 640; s.date = days(28); s.note = "Sample spend"; return s }(),
            { var s = MarketingSpend(); s.channel = .directMail; s.campaign = "Absentee yellow letters (Sample)"; s.amount = 410; s.date = days(14); return s }(),
            { var s = MarketingSpend(); s.channel = .coldCall; s.campaign = "Skip-trace + dial (Sample)"; s.amount = 260; s.date = days(7); return s }(),
        ]
    }
    static func expenses(for deals: [Deal]) -> [DealExpense] {
        guard let d = deals.first else { return [] }
        var e1 = DealExpense(dealID: d.id); e1.label = "Inspection (Sample)"; e1.amount = 425
        var e2 = DealExpense(dealID: d.id); e2.label = "Title search (Sample)"; e2.amount = 350
        return [e1, e2]
    }
}
#endif // circuit-convert
