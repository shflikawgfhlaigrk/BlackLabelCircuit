// Black Label Real Estate — PARCEL / OWNER / VALUE resolver (free, keyless, honest).
//
// Faithful Swift port of the proven Utah engine (utah/product/property.py). It resolves a
// real estate target from FREE PUBLIC county ArcGIS parcel layers — no API key, no paid
// aggregator, no fabrication:
//   • owner name  → the parcel they own (situs address + parcel id + assessed value)
//   • the owner's MAILING address (the skip-trace / direct-mail contact, often != situs)
//   • free public-records DEBT signals (homestead code, deed ref, est. annual tax — the
//     mortgage BALANCE stays null because no free source publishes it; never faked)
//   • the 3-MILE AVERAGE county-assessed value around a point (server-side stats, with a
//     client-side bbox-sample fallback for layers that 400 on outStatistics)
//
// HONESTY (the whole reason this is sellable): every county that has no open layer, or an
// owner that isn't found, GATES (available=false) — it never invents an address or a value.
// Coverage grows by adding counties to `countyRegistry`. ArcGIS WHERE is concatenated, so
// owner tokens are sanitized to bare A–Z0–9 (no injection into the county query).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - County registry (open ArcGIS parcel FeatureServers with an owner field)
// Live-verified in the Utah engine 2026-06-07/09/10. Each layer is a free, keyless, public
// county/regional-commission GIS endpoint. Adding a county here extends real coverage.
struct CountyParcelSource: Hashable, Codable {
    let url: String
    let ownerField: String
    // Situs/property address field. OPTIONAL because a subset of counties expose an OWNER-search /
    // PID-only parcel layer that publishes NO situs address at all (Cleveland NC's Tax/Tax "Parcel
    // Area" carries GIS_Owner1 + GIS_PID + GIS_DeedBook_Page but no address, and its only address
    // layer has no parcel id to attribute-join). Such a county still enters the registry and resolves
    // owner → parcel id + deed by name; `address` stays nil (honest, never a fabricated situs) and the
    // resolver carries a named "no address published / no address search" note.
    let addrField: String?
    let parcelField: String
    let valueField: String?      // county appraised / fair-market value (nil → density only)
    // Teardown/lot-flip scout needs the assessor's land vs improvement split. Only a subset of
    // counties publish it; nil on both → the county is honestly gated for the scout (no faking).
    var landField: String? = nil
    var improvementField: String? = nil
    // Sold-comps / ARV: a subset of counties publish the RECORDED SALE off the deed (price + date +
    // living area). Where present, the comps engine derives ARV from real arm's-length sales near the
    // subject instead of an assessed-value proxy. nil → the county honestly gates comps (no faking).
    var salePriceField: String? = nil
    // Optional server-safe predicate for layers that publish numeric sale prices as strings.
    // Parsed prices are still filtered client-side; this only avoids invalid ArcGIS SQL.
    var salePricePredicate: String? = nil
    var sqftField: String? = nil
    // Sale recency: either an epoch-millis date field (saleDateField) OR split integer year/month
    // fields (saleYearField / saleMonthField), whichever the county exposes.
    var saleDateField: String? = nil       // esriFieldTypeDate (epoch ms)
    var saleYearField: String? = nil       // integer year
    var saleMonthField: String? = nil      // integer month (optional companion to year)
    // A STRING recorded-sale date some counties publish instead of an epoch-ms date or a split year —
    // either a packed "YYYYMMDD" (Buncombe DeedDate) or a delimited "yyyy-MM-dd" (Cumberland DEED_DATE).
    // Parsed positionally to (year, month) in CompsEngine.stringSaleYearMonth; a value that won't parse
    // drops the sale (never a fabricated date). This lets a county whose only recency signal is a string
    // sale-date drive REAL sold comps instead of being gated.
    var saleDateStringField: String? = nil
    /// True only when this county exposes BOTH a land and an improvement value field.
    var supportsTeardownScout: Bool { landField != nil && improvementField != nil }
    /// True when this county publishes recorded sale prices AND a usable recency signal (epoch-ms date,
    /// split year, or a parseable string date) — the basis for real sold comps.
    var supportsComps: Bool { salePriceField != nil && (saleDateField != nil || saleYearField != nil || saleDateStringField != nil) }
}

enum ParcelRegistry {
    /// Lower-cased county name → its open parcel layer. Verified, free, keyless. Each entry is a
    /// LIVE-verified open ArcGIS endpoint (field names confirmed against the server's schema +
    /// a real filtered query before wiring — never guessed).
    static let builtIn: [String: CountyParcelSource] = [
        "harris": .init(
            url: "https://services1.arcgis.com/Ug5xGQbHsD8zuZzM/arcgis/rest/services/Parcels4_2026_HUB/FeatureServer/0/query",
            ownerField: "Owner", addrField: "PhisicalAddress", parcelField: "PARCEL_NO", valueField: "Value"),
        "houston": .init(
            url: "https://services1.arcgis.com/Ug5xGQbHsD8zuZzM/arcgis/rest/services/HoustonCoParcels_withOwner/FeatureServer/0/query",
            ownerField: "LASTNAME", addrField: "ADDRESS", parcelField: "PARCEL_NO", valueField: "CURR_VAL"),
        "bulloch": .init(
            url: "https://stabull.org/server/rest/services/Bulloch_Parcels/MapServer/0/query",
            ownerField: "LASTNAME", addrField: "FULL_ADDRE", parcelField: "PARCEL_NO", valueField: nil),
        "effingham": .init(
            url: "https://services.arcgis.com/9scQWTgPOi3GxJRr/arcgis/rest/services/Parcels2024/FeatureServer/0/query",
            ownerField: "LASTNAME", addrField: "StreetAdd", parcelField: "PARCEL_NO", valueField: nil),
        "hall": .init(
            url: "https://hallgis.hallcounty.org/arcgis/rest/services/GeneralTab/MapServer/1/query",
            ownerField: "OWNER", addrField: "SITE_LOCATION", parcelField: "PIN", valueField: "CUR_VALUE",
            landField: "LAND_VALUE", improvementField: "IMPROVEMENT_VALUE"),   // assessor split — live-verified 2026-06-18
        // ── Teardown-ready additions (publish BOTH land + improvement) — all live-verified 2026-06-18 ──
        "wake": .init(   // Raleigh NC — LAND_VAL + BLDG_VAL, live: 1401 DIXIE TRL land $952k / bldg $229k
            url: "https://maps.wake.gov/arcgis/rest/services/Property/Parcels/MapServer/0/query",
            ownerField: "OWNER", addrField: "SITE_ADDRESS", parcelField: "PIN_NUM", valueField: "TOTAL_VALUE_ASSD",
            landField: "LAND_VAL", improvementField: "BLDG_VAL",
            // Sold comps: TOTSALPRICE + SALE_DATE (epoch ms) + HEATEDAREA — live-verified 2026-06-23
            // (420 HAYWOOD ST sold $563k 2025-01-13, 1485 sqft).
            salePriceField: "TOTSALPRICE", sqftField: "HEATEDAREA", saleDateField: "SALE_DATE"),
        "harnett": .init(   // Harnett NC — ParcelLandValue + ParcelBuildingValue, live: 4035 DARROCH RD land $645k
            url: "https://gis.harnett.org/arcgis/rest/services/Tax/Parcels/MapServer/0/query",
            ownerField: "Owner1", addrField: "PhysicalAddress", parcelField: "PIN", valueField: "TotalMarketValue",
            landField: "ParcelLandValue", improvementField: "ParcelBuildingValue",
            // Sold comps: SalePrice + SaleYear/SaleMonth (integers) + TotalAcutalAreaHeated [sic, per
            // the county's own schema] — live-verified 2026-06-23.
            salePriceField: "SalePrice", sqftField: "TotalAcutalAreaHeated",
            saleYearField: "SaleYear", saleMonthField: "SaleMonth"),
        "davidson": .init(   // Davidson NC — ParcelLandValue + ParcelBuildingValue, live: 5442 GUMTREE RD land $265k
            //
            // ROUND 20 (2026-07-15) RE-KEY: PIN → PARCEL_ID, the round-16 gate lifted on proof.
            // Round 16 measured Davidson's PIN as non-unique WITH DIFFERING ROWS (115 colliding values /
            // 131 excess) and gated the county at runtime — correct, but a gate that fires is a FEATURE
            // OFF: 109 parcels' real recorded deeds went honest-empty. PARCEL_ID is the UNIT-level
            // identity, Durham's REID / Buncombe's pinnum pattern exactly.
            //
            // Live-enumerated on THIS layer (2026-07-15) by the round-18 method — `having COUNT(OBJECTID)
            // > 1` groupBy, UNCAPPED, retry-with-backoff, reconciled against returnCountOnly:
            //   · 98,879 rows total. OID SANITY (round-15 rule — the service publishes objectIdField=null,
            //     so OBJECTID may NOT be assumed to be it): count(OBJECTID) = 98,879 == total ⇒ non-null on
            //     every row, so it is a valid row counter and a group's COUNT cannot be masked by a null.
            //   · PARCEL_ID: 1 null + 1 empty ⇒ 98,877 usable; only 21 colliding values / 22 excess rows.
            //     EVERY ONE of the 21 was enumerated and compared on the exact fields parse() renders
            //     (Name1|DeedBook|DeedPage|DeedDate|InstrumentType): all 21 are BYTE-IDENTICAL siblings
            //     (1 distinct rendered deed each), so parse()'s exact-match collapse reduces each to ONE
            //     real event and NONE reaches the ambiguous-join gate. Reconciles: 98,877 − 22 = 98,855.
            //     (Its coverage BEATS PIN's, which carries 19 nulls + 150 empties.)
            //   · PARCEL_ID is genuinely unit-level, not a re-spelling of PIN: the worst PIN
            //     '6891-01-08-0544' returns 13 rows carrying 13 DISTINCT PARCEL_IDs ('01008K0050001',
            //     '…0001A', '…0001B', '…0002A', … — per-unit suffixes) and 13 DISTINCT deed events
            //     (JOHN KAVANAGH COMPANY 1781/1857 · BUREY WARREN 2740/1723 · MENDAS SARA 2712/1271 · …).
            //     b40 drew those 13 conveyances as ONE unit's title history; round 16 blanked it.
            //   · The honest join RENDERS what round 16 could only gate: PARCEL_ID='01008K0050001'
            //     returns EXACTLY ONE row — JOHN KAVANAGH COMPANY, deed 1781/1857, 04/24/2007 (WD).
            // Guards that mattered: `AccountNumber` looks key-ish and is a TRAP (2,000 colliding values —
            // exactly the layer's maxRecordCount, i.e. its own collision list is truncated); Wilson's
            // `ParcelNumber2`/`RoutingNumber`/`CurrentOwnerID` report ZERO collisions only because they
            // are 100% empty/null. A "0 collisions" reading is meaningless without the null/empty guards.
            url: "https://webgis.co.davidson.nc.us/arcgis/rest/services/OpenGov/OpenGov/MapServer/6/query",
            ownerField: "Name1", addrField: "PropertyAddress", parcelField: "PARCEL_ID", valueField: "TotalMarketValue",
            landField: "ParcelLandValue", improvementField: "ParcelBuildingValue",
            // Sold comps: SalePrice1 + SaleYear1/SaleMonth1 (most-recent recorded sale) — live-verified 2026-06-23.
            salePriceField: "SalePrice1", saleYearField: "SaleYear1", saleMonthField: "SaleMonth1"),
        "onslow": .init(   // Jacksonville NC — FINALFULLLANDVALUE + FINALFULLBUILDINGVALUE (teardown split);
            // the Tax_Data reval layer also carries the recorded conveyance (SALEBOOK/SALEPAGE + an Oracle
            // "DD-MON-YY" SALEDATE + SALEPRICE), which the Onslow TitleRecorderRegistry source joins on.
            // Sold comps: SALEPRICE + SALEDATE via saleDateStringField (CompsEngine.stringSaleYearMonth
            // parses the DD-MON-YY form with the same stable century pivot). Host TLS cert renewed 2026-07-14
            // (notAfter Sep 13 2026).
            //
            // ROUND 21 — RE-KEYED PIN → PARID. Live 2026-07-15: 83 PIN values are held by more than one
            // row and 50 of those DIFFER on the rendered fields (PIN 432400503769 = 7 rows / 7 distinct
            // deeds: MARIACA $240,000 · LEUBNER $235,000 …), so round 16's runtime gate was rendering
            // their real deeds as nothing. PARID is PROVEN-UNIQUE on this layer: 40 colliding values,
            // ALL 40 byte-identical sibling prints, ZERO differing — and 48 of the 50 fabricating PIN
            // groups carry distinct PARIDs, so their chains now render. OID sanity first (objectIdField
            // is null): count(OBJECTID_1) = 94,032 == returnCountOnly total → a valid row counter.
            // The 260 rows with PARID NULL carry NO deed at all (one rendered print, every field null),
            // so a null key costs coverage that never existed — it cannot fabricate. ALTID is also
            // proven-unique (39 colliding / 0 differing) but is null on 1,799 rows vs PARID's 260, so
            // PARID wins on coverage. FEATURE_KEY REFUSED: 3 differing groups.
            url: "https://gismaps.onslowcountync.gov/arcgis/rest/services/WEB_PUBLICATIONS/Tax_Data/MapServer/0/query",
            ownerField: "OWNER1", addrField: "PHYSICALADDRESS", parcelField: "PARID", valueField: "TAXMARKETVALUE",
            landField: "FINALFULLLANDVALUE", improvementField: "FINALFULLBUILDINGVALUE",
            salePriceField: "SALEPRICE", sqftField: "HEATEDSQUAREFEET", saleDateStringField: "SALEDATE"),
        "guilford": .init(   // Greensboro NC — Total_Land_Value + Total_Building_Value (teardown split);
            // live: 100 A S ELM ST land $2,909,800 / bldg $19,261,300 (SIT-IN MOVEMENT INC), polygon 10-pt
            // ring, outSR=4326 reprojects to (-79.917, 36.020). No recorded-sale field → comps honestly
            // gated (supportsComps=false). Live-verified 2026-07-13.
            url: "https://gcgis.guilfordcountync.gov/arcgis/rest/services/GISDV/Parcels/MapServer/0/query",
            ownerField: "Owner", addrField: "LOCATION_ADDR", parcelField: "PIN", valueField: "Total_Assessed",
            landField: "Total_Land_Value", improvementField: "Total_Building_Value"),
        "durham": .init(   // Durham NC — land+bldg assessed AND recorded package sale, so teardown AND sold
            // comps are both real here. live: 204 PINOT CT sold $680,000 2026-06-16, 1841 sqft; assessed
            // land/bldg live on the same feature; PKG_SALE_DATE is epoch-ms; outSR=4326 → (-78.917, 36.010).
            // Live-verified 2026-07-13.
            //
            // ROUND 17 (2026-07-15) parcelField: PIN → REID. PIN is NOT a parcel identity in Durham — it is
            // a BUILDING/map key that condo units share. Live-enumerated on THIS layer (2026-07-15):
            //   REID → 133,231 distinct over 133,231 rows, max 1 row per REID, 0 nulls  ⇒ BIJECTIVE
            //   PIN  → max 321 rows for one value (PIN 0823507508), 0 nulls            ⇒ NOT an identity
            // Resolving a lead to a PIN therefore hands the title-chain join a key that names up to 321
            // parcels, which is exactly how b40 drew a 20-conveyance chain for one unit (§5.1). REID is
            // Durham's own Real Estate ID and is what the recorder layer keys on, so the two registries
            // now agree on ONE proven-unique value form.
            url: "https://webgis2.durhamnc.gov/server/rest/services/ProjectServices/Parcel_Reference_ID_Lookup/FeatureServer/2/query",
            ownerField: "PROPERTY_OWNER", addrField: "LOCATION_ADDR", parcelField: "REID", valueField: "TOTAL_PROP_VALUE",
            landField: "TOTAL_LAND_VALUE_ASSESSED", improvementField: "TOTAL_BLDG_VALUE_ASSESSED",
            salePriceField: "PKG_SALE_PRICE", sqftField: "HEATED_AREA", saleDateField: "PKG_SALE_DATE"),
        "mecklenburg": .init(   // Charlotte NC — CAMA ownership+values layer: land + building assessed AND
            // the recorded package sale (amt_price + dte_dateofsale epoch-ms), so teardown AND sold comps
            // are both real here. `pid` is the SAME value form the TitleRecorderRegistry Mecklenburg
            // recorder (TaxParcelSales.parcelid) joins on, so a resolved lead binds the title chain
            // first-try. live: GOINES SHANNON G pid 03707970, 722 CROSS TRAIL DR $306,305; pid 00101102
            // → amt_price $157,500 (2015-09-11), land $278,100. Live-verified 2026-07-14.
            url: "https://meckgis.mecklenburgcountync.gov/server/rest/services/TaxParcel_Camaownershipvalues/MapServer/0/query",
            ownerField: "full_owner_name", addrField: "situsaddress1", parcelField: "pid", valueField: "amt_totalvalue",
            landField: "amt_landvalue", improvementField: "amt_netbldgvalue",
            salePriceField: "amt_price", saleDateField: "dte_dateofsale"),
        "orange": .init(   // Chapel Hill / Hillsborough NC — LANDVALUE + BLDGVALUE (teardown split); the
            // parcel layer also carries the recorded deed (combined DEEDREF book/page + DATESOLD), which
            // the Orange TitleRecorderRegistry source joins on PIN first-try. STAMPVALUE is excise-tax
            // stamps, never a derived sale price → sold comps honestly gated (supportsComps=false).
            // outSR=4326 geometry live. Live-verified 2026-07-14: PIN 0801034359 (ACG BIRCHWOOD LLC),
            // land $1,552,500 / bldg $4,100, deed 6784/2278.
            url: "https://gis.orangecountync.gov/arcgis/rest/services/WebParcelService/MapServer/0/query",
            ownerField: "OWNER1", addrField: "ADDRESS1", parcelField: "PIN", valueField: "VALUATION",
            landField: "LANDVALUE", improvementField: "BLDGVALUE"),
        "buncombe": .init(   // Asheville NC — authoritative open-data Property layer. The county retired
            // property_bc_dis/MapServer/1 (live 404 on 2026-07-30). Its replacement publishes 135,075
            // parcels at opendata/FeatureServer/1 with the same valuation/deed vocabulary but renamed
            // identity fields: the former unit-level `pinnum` is now the 15-digit `PIN`, and `Owner` is
            // capitalized. Kept in lockstep with TitleRecorderRegistry so parcel-to-deed joins bind first try.
            // SalePrice is an ArcGIS STRING in this layer, so use a string-safe nonzero server predicate;
            // parseSales still enforces numeric minimums, dates, and outlier rules client-side.
            url: "https://gis.buncombecounty.org/arcgis/rest/services/opendata/FeatureServer/1/query",
            ownerField: "Owner", addrField: "Address", parcelField: "PIN", valueField: "AppraisedValue",
            landField: "LandValue", improvementField: "BuildingValue",
            salePriceField: "SalePrice",
            salePricePredicate: "SalePrice IS NOT NULL AND SalePrice <> '0' AND SalePrice <> ''",
            saleDateStringField: "DeedDate"),
        "gaston": .init(   // Gastonia NC (round 4 — recorder seam) — FMV_LAND + FMV_IMPRV (teardown split)
            // AND a recorded deed (DEED_BOOK/DEED_PAGE/DEEDTYPE) with a real recorded SALESAMT + esri-date
            // SALEDATE (epoch ms), so teardown AND sold comps are both real here. `AKPAR` is the SAME value
            // form the Gaston TitleRecorderRegistry source (same parcel layer) joins on → the title chain
            // binds first-try. outSR=4326 geometry live.
            //
            // ROUND 22 (2026-07-15) RE-KEY: PIN → AKPAR. Round 16 proved PIN fabricates (11 colliding
            // values, 6 of them DIFFERING) and gated the county at runtime; round 17 refused the only
            // re-key it considered (PID) and left PIN wired. Both readings were incomplete:
            //
            //   · ROUND 17's STATED REASON FOR GASTON IS REFUTED. It recorded that "Gaston's PIN
            //     collisions are multipart geometry of one parcel — identical owner/book/page/date/
            //     amount — so they collapse to one event and render the real deed today." That holds for
            //     only 5 of the 11 groups. The other SIX are two DIFFERENT parcels sharing one PIN, each
            //     with its own recorded deed, and they gate (live-enumerated 2026-07-15 on the exact
            //     fields parse() renders — DEED_BOOK|DEED_PAGE|SALEDATE|CURR_NAME1|SALESAMT). The
            //     landmine group carries NC DEPT OF TRANSPORTATION (3696/0894, $312,000) AND GREENWOOD
            //     MANAGEMENT LLC (5533/1481) — two owners, two deeds, one PIN. All 11 groups and the
            //     exact PINs are tabulated in docs/COUNTY-KEY-AUDIT.md (round 22) and captured live as
            //     Tests/fixtures/recorder/gaston_pin_multiparcel.json. (The PINs are not spelled out here:
            //     testProductionUIHasNoFakePlaceholderTokens substring-bans the classic fake-phone exchange
            //     in Sources, and these real county PINs happen to contain those digits. The guard is right
            //     and stays untouched — the evidence lives in the doc, the fixtures and the tests, none of
            //     which it scans.)
            //   · AKPAR IS THE HONEST KEY: 115,066 rows, count(AKPAR) = 115,066 ⇒ 0 nulls, AKPAR='' → 0.
            //     Only THREE values collide at all (152345 ×16, 208358 ×16, 195035 ×4 — all three
            //     enumerated, none truncated: maxRecordCount is 2,000), and every one is byte-identical
            //     prints of ONE parcel ⇒ 1 distinct rendered deed each, so the exact-match collapse in
            //     parse() reduces each to ONE real event and NONE reaches the ambiguous-join gate.
            //     Reconciles: 115,066 − 33 = 115,033 distinct AKPAR.
            //   · THE RE-KEY RESCUES ALL SIX. Each of the 6 fabricating PIN groups carries 2 DISTINCT
            //     AKPARs, and each AKPAR returns EXACTLY ONE row (6/6 proven live) — so the honest join
            //     renders the real deed the round-16 gate could only blank.
            //
            // Why round 17 read AKPAR's twin (PID) as bad: it found "PID 152345 spans 2 distinct PINs"
            // and stopped there. Spanning two values of ANOTHER key is not the same as DIFFERING — those
            // two PINs are one account carrying ONE recorded deed (SEILER HEATHER W, 4804/1893), which is
            // exactly why the collapse handles it. This is standing rule 5 read in the other direction.
            //
            // AKPAR over its twin PID: `AKPAR<>PID` returns 0 rows and their collisions are identical, but
            // PID is NULL on 2 rows where AKPAR is populated. (Those 2 rows carry NO deed at all — every
            // rendered field null — so this is a coverage gap that cannot fabricate, the onslow/PARID
            // shape. AKPAR is chosen because it is strictly null-free, not because it rescues a deed.)
            // NOTE `AKPAR<>PID` = 0 does NOT by itself prove the columns identical — SQL excludes the
            // NULL-PID rows from a `<>` comparison entirely; those 2 rows were read directly.
            url: "https://cogserver.gastonianc.gov/serverweb/rest/services/Parcels/GastonCountyParcels/MapServer/0/query",
            ownerField: "CURR_NAME1", addrField: "PHYSSTRADD", parcelField: "AKPAR", valueField: "FMV_TOTAL",
            landField: "FMV_LAND", improvementField: "FMV_IMPRV",
            salePriceField: "SALESAMT", sqftField: "SQFT", saleDateField: "SALEDATE"),
        "cumberland": .init(   // Fayetteville NC (round 4 — recorder seam) — TOTAL_LAND_VALUE_ASSESSED +
            // TOTAL_BLDG_VALUE_ASSESSED (teardown split); the tax parcel layer also carries the recorded
            // deed (DEED_BOOK/DEED_PAGE + DEED_DATE) which the Cumberland TitleRecorderRegistry source joins
            // on `PIN` first-try, plus a recorded PKG_SALE_PRICE. DEED_DATE is a "yyyy-MM-dd" STRING; as of
            // round 5 (2026-07-14) that string date drives REAL sold comps via saleDateStringField — teardown
            // AND sold comps are now both real here. outSR=4326 geometry live. Live-verified 2026-07-14:
            // PIN 0466-96-7734 (SECRETARY OF VETERANS AFFAIRS, 302 CORNHILL RD), deed 12567/0160, DEED_DATE
            // 2026-07-02, recorded sale $340,500.
            url: "https://gis.co.cumberland.nc.us/server/rest/services/Tax/Parcels/MapServer/0/query",
            ownerField: "OWNER", addrField: "LOCATION_ADDR", parcelField: "PIN", valueField: "TOTAL_PROP_VALUE",
            landField: "TOTAL_LAND_VALUE_ASSESSED", improvementField: "TOTAL_BLDG_VALUE_ASSESSED",
            salePriceField: "PKG_SALE_PRICE", saleDateStringField: "DEED_DATE"),
        "rowan": .init(   // Salisbury NC (round 5 — recorder seam) — LANDFMV + IMP_FMV (teardown split) AND a
            // recorded deed (DEEDBOOK/DEEDPAGE) with a real esri-date DATESOLD (epoch ms) + SALE_AMT, so
            // teardown AND sold comps are both real here. outSR=4326 geometry live.
            //
            // ROUND 21 — RE-KEYED PIN → PARCEL_ID. Rowan's dashed `PIN` ("5624-05-29-4295") is a
            // BUILDING-level id: live 2026-07-15, 67 PIN values are held by more than one row and 44 of
            // those carry rows that DIFFER on the exact fields the chain renders — i.e. separate parcels
            // with their own owner/deed/price (PIN 5668-01-45-1761 alone = 27 rows / 24 distinct deeds:
            // CLINE $0 · CAUBLE $237,000 · DUPREE $272,000 · RINK WILL …). Round 16's runtime gate stops
            // those from FABRICATING a 27-deed chain, but at the cost of rendering the real deed as
            // NOTHING. PARCEL_ID is the unit-level id: 83 colliding values of which only 2 differ, and
            // 40 of the 44 fabricating PIN groups carry DISTINCT PARCEL_IDs → their real deeds now
            // render. The 2 residual PARCEL_ID collisions ('067 198', '355 151' — two owners apiece) and
            // the 4 unrescued PIN groups stay caught by the per-parcel runtime gate, so the re-key can
            // only ever un-gate a provable answer, never invent one. PARCEL_ID is NOT proven-unique and
            // is not claimed to be; it is proven STRICTLY BETTER, with the gate still behind it.
            // OID sanity first (round-15 rule; the service publishes objectIdField=null): count(OBJECTID)
            // = 83,511 == returnCountOnly total, min 1 / max 83,511 → a valid row counter.
            // PARENT_PIN/UNIT were tested as the condo-shape re-key and REFUSED: PARENT_PIN is a single
            // SPACE on 64,790 of 83,511 rows (77.6%) and UNIT is NULL on 83,483 (99.97%) — the Wilson
            // trap, where a column reports few collisions only because it is absent.
            url: "https://gis.rowancountync.gov/arcgis/rest/services/Public/RowanTaxParcels/MapServer/0/query",
            ownerField: "OWNNAME", addrField: "PROP_ADDRESS", parcelField: "PARCEL_ID", valueField: "TOT_VAL",
            landField: "LANDFMV", improvementField: "IMP_FMV",
            salePriceField: "SALE_AMT", saleDateField: "DATESOLD"),
        "iredell": .init(   // Statesville NC (round 5 — recorder seam) — Land_Value + Bldg_Value (teardown
            // split) AND a recorded deed (DWBook/DWPage) with a real recorded Sales_Price + integer Sale_Yr,
            // so teardown AND sold comps are both real here. TRAP: the layer's `DeedDate` is a data-refresh
            // timestamp (e.g. 20260706 on a 2020 sale), NOT the sale date — recency is driven by the reliable
            // integer Sale_Yr, never DeedDate. `PIN` ("4659165906.000") is the value the Iredell recorder
            // (same TaxSQL parcel layer) joins on → binds first-try. Actual_Heated_Area gives real $/sqft
            // comps. Live-verified 2026-07-14: PIN 4659165906.000 (CAUDLE JUSTIN), deed 3043/1783, Sale_Yr
            // 2024, recorded sale $232,500, 1323 sqft.
            url: "https://maps.iredellcountync.gov/server/rest/services/Data/TaxSQL_Parcels/MapServer/0/query",
            ownerField: "Name", addrField: "STREET", parcelField: "PIN", valueField: "Total_Value",
            landField: "Land_Value", improvementField: "Bldg_Value",
            salePriceField: "Sales_Price", sqftField: "Actual_Heated_Area", saleYearField: "Sale_Yr"),
        "randolph": .init(   // Asheboro NC (round 6 — recorder seam) — LAND_VALUE + BLDG_VALUE (teardown split)
            // AND a recorded deed (DOCUMENT_BOOK/DOCUMENT_PAGE, combined DEED_BK_PG) with owner ACCT_NAME.
            // The layer publishes NO recorded sale PRICE and NO conveyance DATE (its DATESTAMP/REFRESHDATE
            // are data-refresh stamps, TAXABLE_FROM is a tax-status date — never a sale), so sold comps are
            // honestly GATED (supportsComps=false, like Guilford/Orange). `PIN` (10-digit) is the value the
            // Randolph TitleRecorderRegistry source (same ParcelBasemap layer) joins on → the title chain binds
            // first-try. Live-verified 2026-07-14: PIN 6687457058 (SMITH, WILLIAM FRANKLIN III), deed 002062/01984,
            // land $71,500 / bldg $311,020.
            url: "https://gis.randolphcountync.gov/arcgis/rest/services/ParcelBasemap/MapServer/5/query",
            ownerField: "ACCT_NAME", addrField: "LOCADDRESS", parcelField: "PIN", valueField: "TOT_REAL_VALUE",
            landField: "LAND_VALUE", improvementField: "BLDG_VALUE"),
        "alamance": .init(   // Graham/Burlington NC — authoritative populated parcel layer.
            // A transient zero-count response during b49 investigation recovered on re-probe: this county-owned
            // layer now publishes 79,606 rows again and is richer than TaxViewCurrent because it includes the
            // county's combined physical situs CAKPSAD and full OWNAM1 co-owner string. We keep the restored
            // authoritative layer but correct its valuation/date mapping: current FMV is JMTCTM = AKLCFM +
            // AKICFM, and AMDTSL is packed YYYYMMDD (for example 20251209), never epoch milliseconds.
            // Live-verified 2026-08-02: AKPAR_ 171622 → exactly one row, 705 AVALON DR, JMTCTM $542,134,
            // AMSLAM $475,000, AMDTSL 20251209, deed 4798/0276.
            url: "https://apps.alamance-nc.com/arcgis/rest/services/Tax/AlamanceParcels/MapServer/0/query",
            ownerField: "OWNAM1", addrField: "CAKPSAD", parcelField: "AKPAR_", valueField: "JMTCTM",
            landField: "AKLCFM", improvementField: "AKICFM",
            salePriceField: "AMSLAM", saleDateStringField: "AMDTSL"),
        "pitt": .init(   // Greenville NC (round 6 — recorder seam) — CurLandValue + CurBuildValue (teardown
            // split) AND a recorded deed (DeedBook/DeedPage, combined DeedBkPg) with a real recorded SalesPrice
            // + an esri-date DocumentDate (epoch ms, whose value matches the county's own SalesMonthYear — a
            // REAL conveyance date, not a refresh stamp) + HeatedSqFt for $/sqft comps, so teardown AND sold
            // comps are both real here. `PARCELNUMBER` is the value the Pitt recorder (same CadastralPitt layer)
            // joins on → binds first-try. Live-verified 2026-07-14: PARCELNUMBER 90616 (SMITH REMEDEAS,
            // 3501 3 SEDGE DR), deed 004790/00393, DocumentDate 2026-06-01 (SalesMonthYear 06/2026), recorded
            // sale $229,000, land $20,000 / bldg $207,004, 1491 sqft.
            url: "https://gis.pittcountync.gov/gis/rest/services/PittOpenData/CadastralPitt/MapServer/0/query",
            ownerField: "OwnerName", addrField: "PhysicalAddress", parcelField: "PARCELNUMBER", valueField: "CurTaxValue",
            landField: "CurLandValue", improvementField: "CurBuildValue",
            salePriceField: "SalesPrice", sqftField: "HeatedSqFt", saleDateField: "DocumentDate"),
        "bryan": .init(
            url: "https://bryangis.bryan-county.org/arcgis/rest/services/Parcels/MapServer/0/query",
            ownerField: "LASTNAME", addrField: "STREET_NAM", parcelField: "PIN", valueField: nil),
        "forsyth": .init(
            url: "https://geo.forsythco.com/gis/rest/services/EnerGov/EnerGovParcelAddressMapService/MapServer/1/query",
            ownerField: "OWNERNME1", addrField: "SITEADDRESS", parcelField: "PARCELID", valueField: nil),
        "craven": .init(   // New Bern NC — JustParcels/0: owner PANAME, addr FULLADD, value totval, land totlnd /
            // bldg totbld; recorded sale SALE_PRICE + esri-date SALE_DATE (== the county's PREC* recording
            // stamp to the day — a real conveyance date). PID is the value the Craven recorder joins on →
            // binds first-try. Live-verified 2026-07-14: PID '8-205-4 -021' (CARTLAND MARY C, 205 DOBBS
            // SPAIGHT RD), value $275,450, land $40,000 / bldg $235,450, recorded sale $356,500 2026-06-10.
            url: "https://gis.cravencountync.gov/arcgis/rest/services/JustParcels/MapServer/0/query",
            ownerField: "PANAME", addrField: "FULLADD", parcelField: "PID", valueField: "totval",
            landField: "totlnd", improvementField: "totbld",
            salePriceField: "SALE_PRICE", saleDateField: "SALE_DATE"),
        "moore": .init(   // Carthage/Pinehurst NC — Tax/Tax_Parcel/0: owner NAME, addr ADDRESS, value TOTAL_VAL,
            // land LANDVALUE / bldg BUILD_VAL. PARCEL-RESOLUTION LESSON: PIN is NOT unique (one PIN spans 47
            // PARID parcels), so the parcel id is PARID (unique) — the value the Moore recorder joins on →
            // binds first-try. No clean recorded sale PRICE (STAMP_VAL is excise stamps, never a price) → comps
            // honestly gated. Live-verified 2026-07-14: PARID 00041503172 (WELCH LINDA M, 2884 SUSAN AVE),
            // value $310,300, land $40,000 / bldg $270,300.
            url: "https://gis.moorecountync.gov/server/rest/services/Tax/Tax_Parcel/MapServer/0/query",
            ownerField: "NAME", addrField: "ADDRESS", parcelField: "PARID", valueField: "TOTAL_VAL",
            landField: "LANDVALUE", improvementField: "BUILD_VAL"),
        "wilson": .init(   // Wilson NC — Tax/Taxparcels FeatureServer/0: owner Name1, addr PhysicalStreetAddress,
            // value TotalFMVCurrent, land LandFMVCur / improvement ImproveFMVCur (teardown scout). This SAME
            // layer also carries the recorded deed (DeedBook/DeedPage + a real recorded SalesAmount), wired for
            // the title recorder. DATE-DISCIPLINE TRAP (round 10): the layer's conveyance date is CORRUPT —
            // DateSold (packed YYYYMMDD) and its companion esri-date SaleDate carry impossible future years for
            // real recent sales (live-verified: PIN 3668-52-8580.000 is a 2025 WARRANTY DEED for $285,500 whose
            // DateSold reads 24001202 → year 2400; DeedYear is only a year and is a +1 tax-year offset), so comps
            // are honestly GATED (no salePriceField/date — a recorded price with no trustworthy date is not a
            // comp, §5.1). PIN is the value the Wilson recorder joins on → binds first-try. Live-verified
            // 2026-07-14: PIN 3668-52-8580.000 (PURSER CLAUDIA, 7678 BARTEE BRIDGE RD), value $236,900, land
            // $19,700 / improvement $217,200.
            url: "https://gis.wilson-co.com/arcgis/rest/services/Tax/Taxparcels/FeatureServer/0/query",
            ownerField: "Name1", addrField: "PhysicalStreetAddress", parcelField: "PIN", valueField: "TotalFMVCurrent",
            landField: "LandFMVCur", improvementField: "ImproveFMVCur"),
        "cleveland": .init(   // Shelby NC (round 12) — the FIRST pid-only / owner-search registry entry. The
            // Tax/Tax "Parcel Area" layer (gis.clevelandcounty.com) publishes GIS_Owner1 + GIS_PID +
            // GIS_DeedBook_Page but NO situs address and NO assessed value — and the county's only address
            // layer (Planning/AddressPoints_AGOL) carries FullAddress with NO parcel id, so there is no
            // attribute-join key between address and parcel. Rather than gate the whole county, it enters
            // the registry with addrField=nil: an owner-name search resolves owner → parcel id (GIS_PID) +
            // deed ref, auto-populating lead.parcel, and `address` stays nil (honest, never a fabricated
            // situs). GIS_PID is the SAME value form the Cleveland recorder's Vacant_ImprovedLot_Sales roll
            // joins on Parcel_Number → a resolved Cleveland lead binds its recorded sales chain / comps
            // first-try. No land/improvement fields → teardown scout honestly gated; no recorded sale price
            // on this layer → parcel-level comps gated (comps come from the multi-row sales roll). Live-
            // verified 2026-07-14: GIS_PID 26168 (SHELBY HOSPITALITY PARTNERS LLC, deed 1950-2795).
            url: "https://gis.clevelandcounty.com/arcgis/rest/services/Tax/Tax/MapServer/1/query",
            ownerField: "GIS_Owner1", addrField: nil, parcelField: "GIS_PID", valueField: nil),
        "wilkes": .init(   // Wilkesboro NC (round 13) — LandRecords/Parcels: OWNER1 + PROPLOCAT + PIN, with
            // the COSTLANDVA/COSTBLDGVA assessed split (teardown scout) AND a recorded SALEPRICE + epoch-ms
            // SALEDATE + TRUETLA living area → BOTH teardown scout AND sold comps are real here. PROPLOCAT is
            // the county's own property-location field (a street address where set, else a recorded legal
            // description — carried verbatim, never a fabricated situs). NOTE the county publishes a $999,999
            // NON-DISCLOSURE sentinel on some deeds; the comps engine's 0.25×–4× median outlier trim discards
            // it, so a sentinel never inflates ARV. NOT a pid-only county (it DOES publish a situs address), so
            // it is a normal registry entry — see the round-13 addrField-nil NEGATIVE test. Live-verified
            // 2026-07-14: 52,487 owner rows / 24,994 priced; PIN 2899-54-7089 (HAYES, KRISTY & JONATHAN,
            // 12716 US HWY 421) sold $297,500 (2025-02-20), land $28,070 / bldg $313,320, 1,560 sqft.
            url: "https://gis.wilkescounty.net/arcgis/rest/services/LandRecords/Parcels/MapServer/0/query",
            ownerField: "OWNER1", addrField: "PROPLOCAT", parcelField: "PIN", valueField: "COSTTOTVA",
            landField: "COSTLANDVA", improvementField: "COSTBLDGVA",
            salePriceField: "SALEPRICE", sqftField: "TRUETLA", saleDateField: "SALEDATE"),
        "ashe": .init(   // Jefferson NC (round 13) — Parcels: Name1 + ParcelPropertyAddress + ParcelNumber,
            // with ParcelLandValue + ParcelBuildingValue (teardown split) AND a recorded SalePrice + integer
            // SaleYear → BOTH teardown scout AND sold comps are real (SaleYear is the split-integer recency
            // signal, no epoch date on this layer). ParcelPropertyAddress is null on some parcels → the
            // resolver leaves `address` nil there (never a fabricated situs). NOT a pid-only county (it DOES
            // publish a situs address) — a normal registry entry. Live-verified 2026-07-14: ParcelNumber
            // 19306012 (KIMAK MATTHEW & DEBRA J, 251 PISGAH HEIGHTS DR) sold $321,000 (2023), land $36,100 /
            // bldg $197,000, total market $233,900.
            url: "https://gis.ashecountygov.com/arcgis/rest/services/Parcels/MapServer/0/query",
            ownerField: "Name1", addrField: "ParcelPropertyAddress", parcelField: "ParcelNumber",
            valueField: "TotalMarketValue", landField: "ParcelLandValue", improvementField: "ParcelBuildingValue",
            salePriceField: "SalePrice", saleYearField: "SaleYear"),

        // ────────────────────────────────────────────────────────────────────────────────────────
        // ROUND 15 (2026-07-14). Two PROMOTIONS (Haywood/Surry, already recorder-wired in round 14)
        // and four NEW counties. Every entry below cleared the Moore non-unique-join trap by EXHAUSTIVE
        // enumeration over the county's FULL roll (never a single-parcel spot-check), and every
        // addrField was proven to be a real SITUS — not the owner's mailing address — by measuring
        // divergence for absentee owners across a live sample. Where a county failed either test, the
        // affected FEATURE is gated (nil field) rather than the county being wired on a lying field.
        // ────────────────────────────────────────────────────────────────────────────────────────
        "haywood": .init(   // Waynesville NC (round 15 PROMOTION) — the round-14 recorder county, now a
            // full registry entry: it publishes BOTH the assessor's land/improvement split AND a real
            // recorded Sale_Price + epoch-ms Sale_Date + Heated_Area, so it drives the teardown scout
            // AND REAL sold-comp ARV (not an assessed-value proxy).
            //
            // NON-UNIQUE-JOIN TRAP — round 14 recorded a bijection here that DOES NOT EXIST, and the
            // proof was circular: it compared `distinct ALPHA` (45,342) against `distinct OBJECTID`
            // (45,342) and concluded ALPHA→OBJECTID was a bijection. But this layer's `objectIdField`
            // is NULL and it carries TWO oid-ish columns: a plain `OBJECTID` that is itself a
            // PARCEL-level field (co-varying with ALPHA, hence the identical 45,342), and `OBJECTID_1`,
            // the actual row identity. Against the REAL oid the counts do NOT match: OBJECTID_1 has
            // 46,603 distinct values == 46,603 total rows, vs only 45,342 distinct ALPHA — i.e. 1,261
            // excess rows. Round 14's own note ("14 rows all carrying OBJECTID 26114109") was the tell:
            // an oid that repeats across 14 rows is not an oid. Re-verified round 15 by ENUMERATION,
            // which is what the bijection shortcut was standing in for: ALPHA collides on 935 values,
            // and for ALL 935 the rows are byte-identical on every displayed field (owner, situs,
            // land/bldg/assessed, sale price/date, heated area, deed ref) — 0 differing. So the excess
            // rows are exact re-prints that parse()'s identity collapse folds to one, and the round-14
            // CONCLUSION stands even though its proof did not. Had any collision differed, Haywood
            // would have been gated here rather than joined on a lying key.
            //
            // Prop_Addr is a REAL situs, not a mailing copy (the Surry trap below): across a 253-row
            // live sample it diverges from the owner's Addr_1/CSZ on 133 rows — e.g. D'AGOSTINO,
            // DORINDA mails to LAND O LAKES, FL 34639 while the SITUS is 132 WHITEWATER DR MAGGIE
            // VALLEY NC. Live-verified 2026-07-14: ALPHA 8607-70-7647 (SMITH, RANDY W, 2523 DELLWOOD
            // RD) land $82,300 / bldg $180,700 / assessed $263,000, sold $299,000 (2002-04-16), 1,840
            // sqft heated, deed 519/211.
            url: "https://maps.haywoodcountync.gov/arcgis/rest/services/Land_Records/Qualified_Sales/MapServer/2/query",
            ownerField: "Owner_1", addrField: "Prop_Addr", parcelField: "ALPHA", valueField: "Assd_Value",
            landField: "Land_Value", improvementField: "Bldg_Value",
            salePriceField: "Sale_Price", sqftField: "Heated_Area", saleDateField: "Sale_Date"),
        "surry": .init(   // Dobson NC (round 15 PROMOTION) — the round-14 recorder county. Publishes
            // ParcelLandValue + ParcelBuildingValue → teardown scout is real. No recorded sale price on
            // this layer → comps honestly gated.
            //
            // addrField is nil ON PURPOSE (the pid-only Cleveland pattern). Surry publishes NO single
            // situs field: the property address exists only split across HouseNumber/StreetDirection/
            // StreetName/StreetType, while `Address1` is the OWNER'S MAILING address. Address1 merely
            // COINCIDES with the situs for owner-occupants, which is exactly the sampling artifact that
            // makes it dangerous — the first four rows of any sample agree. Measured over the full roll
            // (32,364 rows carrying a real HouseNumber): Address1 differs from the parcel's own composed
            // situs on 15,126 rows (46.7%), and the HOUSE NUMBER ITSELF is wrong on 10,146 (33.3%) —
            // e.g. Parcel 503200701777 mails to '268 HYLTON ST' but the property is '2960 RIVERSIDE DR'.
            // Wiring Address1 as addrField would therefore present the owner's mailing address as the
            // property address on one parcel in three — a fabricated situs (5.1). So the county enters
            // pid-only: owner-name search → parcel + land/bldg split, `address` stays nil (honest).
            // Live-verified 2026-07-14: Parcel 408100456640 (SMITH MARSHALL RAY LIFE ESTATE) land
            // $20,400 / bldg $89,090 / total assessed $113,390.
            url: "https://gis.co.surry.nc.us/arcgis/rest/services/Parcels/MapServer/0/query",
            ownerField: "Name1", addrField: nil, parcelField: "Parcel", valueField: "TotalAssessedValue",
            landField: "ParcelLandValue", improvementField: "ParcelBuildingValue"),
        "yadkin": .init(   // Yadkinville NC (round 15, NEW) — the round's richest new county: the
            // tax_view_fc warehouse layer carries owner + situs + the land/improvement split AND a
            // recorded SALES_AMT + FINISHED_AREA + epoch-ms DEED_DATE, so BOTH the teardown scout and
            // REAL sold-comp ARV are live. 18,340 rows carry a land+bldg split; 7,341 carry a real
            // sale price + finished area + deed date.
            //
            // NON-UNIQUE-JOIN TRAP — the obvious key LIES and a second key saves the county: `PIN` is
            // NOT unique (28,169 distinct over 28,341 rows; all 139 collisions DISAGREE on owner,
            // address, land/bldg value, sale amount and deed — a PIN join would fabricate). `PARCEL_NO`
            // however is a PROVEN bijection: 28,303 rows / 28,303 distinct PARCEL_NO / 0 collisions,
            // enumerated exhaustively over the full roll. So the county is joined on PARCEL_NO.
            //
            // valueField is nil because Yadkin publishes NO total-value column at all (only
            // LAND_FMV_CURRENT / LAND_LUV_CURRENT / LAND_ASV_CURRENT / BLDG_FMV_CURRENT). Summing land
            // + building to synthesize a "total" would be a derived number the county never published,
            // so it stays nil (honest) — the land/improvement split still drives the teardown scout.
            // STREET_ADDRESS is a real situs: it diverges from the owner's ADDRESS1 mailing on 319 of a
            // 500-row live sample (64%). FINISHED_AREA is a STRING ('1456') — CompsEngine.dbl parses it.
            // Live-verified 2026-07-14: PARCEL_NO 112794 (BLAKE FARMS OF NC LLC, 5940 SHILOH CHURCH RD)
            // land $305,720 / bldg $140,220, sold $517,500 (2012-07-05), 1,152 sqft, deed 1054/0199.
            url: "https://gis.yadkincountync.gov/arcgis/rest/services/BASIC_LOOKUP2/MapServer/2/query",
            ownerField: "NAME1", addrField: "STREET_ADDRESS", parcelField: "PARCEL_NO", valueField: nil,
            landField: "LAND_FMV_CURRENT", improvementField: "BLDG_FMV_CURRENT",
            salePriceField: "SALES_AMT", sqftField: "FINISHED_AREA", saleDateField: "DEED_DATE"),
        "caldwell": .init(   // Lenoir NC (round 15, NEW) — the OpenGov/TaxParcels layer (the same
            // OpenGov shape Davidson uses) publishes LandValue + BuildingValue → teardown scout is real.
            // No recorded sale price column → comps honestly gated.
            //
            // NON-UNIQUE-JOIN TRAP — cleared by exhaustive enumeration, not a bijection: PID collides on
            // 49 values over 52,756 rows (52,700 distinct), and for ALL 49 the rows are byte-identical
            // on every displayed field (owner, situs, market/land/building value, deed book/page) — 0
            // differing. They are multipart re-prints, so the exact-identity collapse yields one record
            // per PID and no multiplicity is fabricated.
            //
            // FullPropAddress is a real situs (diverges from the MailAddr1 mailing on 405 of a 494-row
            // live sample, 82%). Note it carries a literal '0' sentinel on unaddressed/vacant parcels;
            // ParcelLookup.pick already discards a bare "0", so those render as no-address rather than
            // an invented one. Live-verified 2026-07-14: PID '04 9W159  8' (SMITH JENI B, 2193 PLAYMORE
            // BEACH RD) land $160,900 / bldg $117,400 / market $279,600.
            url: "https://gis.caldwellcountync.org/arcgis/rest/services/OpenGov/OpenGov/MapServer/1/query",
            ownerField: "AcctName1", addrField: "FullPropAddress", parcelField: "PID", valueField: "MarketValue",
            landField: "LandValue", improvementField: "BuildingValue"),
        "transylvania": .init(   // Brevard NC (round 15, NEW) — wired for owner + value + the TEARDOWN
            // split ONLY. Comps are GATED here on purpose even though the layer visibly carries
            // SALE_PRICE, SALE_DATE and HEATED_SQ_, because those specific columns cannot be joined
            // honestly on this layer's key. This is the round's clearest case of gating a FEATURE
            // rather than refusing a county — or wiring it on a field that lies.
            //
            // NON-UNIQUE-JOIN TRAP — PIN is NOT unique: 29,183 distinct over 31,754 rows, 1,254
            // colliding PINs of which 1,226 DISAGREE on displayed fields. The collisions are the
            // county's building CARDs (one row per building card on a parcel). `CARD = 1` is NOT a
            // rescue either — 17 PINs carry more than one card-1 row and 84 carry none, so it is not a
            // bijection. What settles it is a PER-FIELD enumeration across all 1,254 collisions:
            //     OWNER_NAME / LEGAL_ADDR / LAND_VALUE / BUILDING_V / ASSESSED_V / XFOB_VALUE
            //         → disagree on 0 PINs  (every card of a parcel repeats the PARCEL-level value)
            //     HEATED_SQ_ → disagrees on 1,206 · SALE_DATE / SALE_PRICE / DEED_BK / PAGE → 1,169
            // So owner, value and the land/improvement split are SAFE on a PIN join (whichever card the
            // server returns carries the same value), while a comps join would take an ARBITRARY card's
            // heated area against the parcel's sale price and fabricate $/sqft → a fabricated ARV. E.g.
            // PIN 7590-88-3295-000 has 9 cards whose HEATED_SQ_ runs 0 → 3,435 sqft under one sale.
            // Hence salePriceField/sqftField/saleDateField stay nil: supportsComps == false. (The
            // recorder is refused for the same reason — see the Transylvania NEGATIVE pin.)
            //
            // addrField is nil (the Cleveland pid-only pattern): Transylvania publishes no situs street
            // address. `LEGAL_ADDR` is a LEGAL DESCRIPTION ('LOT 2 Whitewater Cove', 'COMMON
            // AREA-WHITEWATER COVE'), not a deliverable address, and the ADDRESS_1/2/3 block is the
            // OWNER'S mailing address — where ADDRESS_1 is often an owner-NAME continuation ('Bruce
            // Dorothy C Trustees') and ADDRESS_3 the mailing street. Live-verified 2026-07-14: PIN
            // 8501-58-5181-000 (Smith Katherine Anne Trustee) land $301,710 / bldg $1,772,600 /
            // assessed $2,135,000.
            url: "https://gis.transylvaniacounty.org/server/rest/services/Parcels/MapServer/2/query",
            ownerField: "OWNER_NAME", addrField: nil, parcelField: "PIN", valueField: "ASSESSED_V",
            landField: "LAND_VALUE", improvementField: "BUILDING_V"),
        "burke": .init(   // Morganton NC (round 15, NEW) — owner + situs + total value. The layer
            // publishes NO land/improvement split → teardown scout honestly gated; NO recorded sale
            // price → comps honestly gated. It does carry DEED_DATE/DEED_BOOK/DEED_PAGE, which the
            // Burke TitleRecorderRegistry source uses for the recorded chain.
            //
            // NON-UNIQUE-JOIN TRAP — the KEY CHOICE is the whole ballgame here: `PIN` collides on 174
            // values of which 172 DISAGREE on owner/address/value/deed (a PIN join would fabricate),
            // while `REID` — the county's real-estate account id — collides on only 91 values and ALL
            // 91 are byte-identical on every displayed field (0 differing). PIN+PIN_EXT is likewise
            // clean (90/90 identical) but REID is the county's own account key, so the county is joined
            // on REID and the identity collapse folds its multipart re-prints to one record.
            //
            // LOCATION_ADDR is a real situs (diverges from OWNER_MAIL_1 on 285 of a 500-row live
            // sample, 57%); like Caldwell it carries a '0 <STREET>' form on unaddressed parcels, shown
            // verbatim rather than invented. Live-verified 2026-07-14: REID 62 (SMITH, SHERRY LYNN
            // PARLIER, 2640 BYRD RD) total value $35,892.
            url: "https://gis.burkenc.org/arcgis/rest/services/Parcels_VIEWER_MapImage_v3/MapServer/1/query",
            ownerField: "PROPERTY_OWNER", addrField: "LOCATION_ADDR", parcelField: "REID",
            valueField: "TOTAL_PROP_VALUE"),

        // ────────────────────────────────────────────────────────────────────────────────────────
        // ROUND 16 (2026-07-15). Jackson — round 15 pinned this county NEGATIVE for the WRONG REASON
        // ("the ArcGIS backend is down: HTTP 200 carrying 'Could not access any server machines'").
        // The backend was never down: round 15 probed `jacksonnc.org/jcgis/`, the county's CMS host,
        // which 301s to www and answers EVERY path with the CMS homepage HTML. The county's own
        // opendata DCAT catalog names the real GIS host — `gis.jacksonnc.org` — which serves ArcGIS
        // 10.81 on a VALID cert (ssl_verify_result=0). Lesson recorded: a county's DCAT names the
        // HOST, not just the path; re-read it before pinning liveness.
        // ────────────────────────────────────────────────────────────────────────────────────────
        "jackson": .init(   // Sylva NC (round 16, NEW) — the richest county wired since Haywood: owner
            // + real situs + the land/improvement split (teardown) + a real recorded SalePrice and
            // corroborated SaleDate (REAL sold-comp ARV) + a combined book/page deed ref.
            //
            // NON-UNIQUE-JOIN TRAP — cleared, and this is the FIRST county where the count-identity
            // shortcut is legitimately AVAILABLE: `objectIdField` is non-null (OBJECTID) and it passes
            // the round-15 oid sanity check — 41,424 distinct OBJECTID == 41,424 total rows, so it is
            // genuinely the row identity (unlike Haywood, whose objectIdField is null and whose plain
            // OBJECTID is a parcel-level copy). PIN still is NOT a bijection (41,345 distinct over
            // 41,424 rows), so the shortcut was NOT leaned on: all 27 colliding PINs were ENUMERATED
            // and every one is byte-identical on the displayed fields (0 differing) → the parser's
            // identity collapse yields one record. No key lies here.
            //
            // valueField is TaxableValue — the county's OWN published total, NOT a synthesized sum:
            // it equals TotLandValue+TotBldgValue exactly on 6/6 live rows, so it is published, not
            // derived (the Yadkin rule — never invent a total the county doesn't publish).
            // PropAddr is a REAL situs: its house number diverges from MailingAddress1 on 443 of a
            // 500-row live sample (89%) — the Surry mailing-address trap does not apply.
            // Live-verified 2026-07-15: PIN 7553-72-2318 (CHAMBLISS, SCOTT A, 46 SKYVIEW TRL UNIT 504)
            // land $250,000 / bldg $897,892, sold $1,100,000, deed 2423/1464.
            url: "https://gis.jacksonnc.org/jcgis/rest/services/Tax_Admin/Parcels_Cached/FeatureServer/2/query",
            ownerField: "CurrentOwner1", addrField: "PropAddr", parcelField: "PIN",
            valueField: "TaxableValue", landField: "TotLandValue", improvementField: "TotBldgValue",
            salePriceField: "SalePrice", saleDateField: "SaleDate")
    ]

    /// The live registry = built-in counties + any the BUYER registered at runtime (Settings →
    /// Markets & Counties). User entries override a built-in of the same name (so a buyer can
    /// re-point a county to their own layer). Coverage is user-expandable, not developer-gated.
    static var counties: [String: CountyParcelSource] {
        builtIn.merging(CustomCountyStore.load()) { _, user in user }
    }
    static var coveredCounties: [String] { counties.keys.map { $0.capitalized }.sorted() }
    static func source(for county: String) -> CountyParcelSource? {
        counties[county.trimmingCharacters(in: .whitespaces).lowercased()]
    }
    static func covers(_ county: String) -> Bool { source(for: county) != nil }
    static func isBuiltIn(_ county: String) -> Bool {
        builtIn[county.trimmingCharacters(in: .whitespaces).lowercased()] != nil
    }
}

// MARK: - Buyer-registered counties (runtime-expandable coverage, persisted, no fabrication)
// A buyer points the product at ANY open ArcGIS parcel layer by naming its fields. Stored locally
// (own data, never uploaded). A custom county with both land+improvement fields immediately makes
// the teardown scout usable in that market — coverage stops being developer-gated.
enum CustomCountyStore {
    static let key = "blre.customCounties"
    /// lower-cased county name → source. Empty land/improvement strings are normalized to nil so a
    /// half-filled entry honestly gates the teardown scout instead of querying a non-existent field.
    static func load() -> [String: CountyParcelSource] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: CountyParcelSource].self, from: d) else { return [:] }
        return m
    }
    static func save(_ m: [String: CountyParcelSource]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
    /// Upsert a buyer county. Field names are trimmed; blank optionals → nil (honest gating).
    /// Returns nil + a reason if the required fields are missing (never silently stores junk).
    @discardableResult
    static func upsert(name: String, url: String, ownerField: String, addrField: String,
                       parcelField: String, valueField: String?, landField: String?, improvementField: String?) -> String? {
        let nm = name.trimmingCharacters(in: .whitespaces).lowercased()
        let u = url.trimmingCharacters(in: .whitespaces)
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
        }
        guard !nm.isEmpty else { return "County name is required." }
        guard u.lowercased().hasPrefix("http"), u.lowercased().contains("/query") else {
            return "URL must be a full ArcGIS layer query endpoint ending in /query."
        }
        guard let of = clean(ownerField), let af = clean(addrField), let pf = clean(parcelField) else {
            return "Owner, address and parcel field names are all required."
        }
        var m = load()
        m[nm] = CountyParcelSource(url: u, ownerField: of, addrField: af, parcelField: pf,
                                   valueField: clean(valueField),
                                   landField: clean(landField), improvementField: clean(improvementField))
        save(m); return nil
    }
    static func remove(_ name: String) {
        var m = load(); m[name.trimmingCharacters(in: .whitespaces).lowercased()] = nil; save(m)
    }
    /// Buyer-registered county names, sorted (for the Settings list).
    static var names: [String] { load().keys.map { $0.capitalized }.sorted() }
}

// MARK: - Result models (everything optional + honestly gated — never fabricated)
struct OwnerMailing: Hashable, Codable {
    var street = ""; var city = ""; var state = ""; var zip = ""
    var full: String {
        let line2 = [city, state, zip].filter { !$0.isEmpty }.joined(separator: " ")
        return line2.isEmpty ? street : "\(street), \(line2)"
    }
    var isEmpty: Bool { street.isEmpty }
}

struct DebtSignals: Hashable, Codable {
    var mortgageBalance: Int? = nil          // always nil — no free source; honest, never faked
    var balanceSource = "none_free"
    var homesteadExemption: String? = nil
    var deedRef: String? = nil
    var estAnnualTax: Int? = nil
}

enum OwnershipConfidence: String, Codable, Hashable { case high, medium, low, none }

/// ONE real candidate parcel of an ambiguous owner match (round 20). Every field is the county's /
/// index's OWN published value, carried verbatim off a row we ALREADY fetched — nothing is
/// synthesized, re-queried or inferred. A nil field is a field the source doesn't publish (a
/// pid-only county has no situs), never a filler.
///
/// This exists because refusing with a BARE record threw away knowledge we already held: rounds
/// 18–19 proved the resolver must not PICK among Gary Dean's four parcels, but all four are real,
/// county-published and knowable — so showing them and letting the buyer choose is strictly more
/// honest than showing nothing. The resolver still never picks: choosing is the buyer's act.
struct ParcelCandidate: Hashable {
    var owner: String?
    var address: String?
    var parcel: String?
    var assessedValue: Int?
}

struct ParcelRecord: Hashable {
    var available: Bool                       // false = honestly gated, no open source / not found
    var gated: Bool
    var county: String
    var source: String                        // "arcgis" | "none" | "bad_name"
    var address: String?
    var parcel: String?
    var owner: String?
    var assessedValue: Int?                    // county appraised value (nil = not published)
    var lat: Double?
    var lng: Double?
    var ownershipConfidence: OwnershipConfidence = .none
    var ownerMail = OwnerMailing()
    var debt = DebtSignals()
    /// The REAL candidates when `source == ambiguousSource` — the buyer's chooser (round 20).
    /// EMPTY on every resolved record: a candidate list is the shape of a refusal, not of an answer.
    var candidates: [ParcelCandidate] = []
    var note: String = ""                      // honest reason when gated
}

struct AreaValue: Hashable {
    var available: Bool
    var avgValue: Int?
    var parcels: Int
    var radiusMeters: Int
    var method: String                         // "server_stats" | "bbox_sample" | "density_only"
    var note: String = ""
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Resolver
enum ParcelLookup {
    static let threeMilesM = 4828              // 3 mi in metres

    /// Owner-name token reduced to bare A–Z0–9 — the WHERE is concatenated, so a hostile
    /// case name must never inject quotes/semicolons/wildcards into the county query.
    static func likeToken(_ s: String) -> String {
        s.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// The usable owner-name tokens of `name`: sanitized to bare A–Z0–9, de-duplicated, order preserved.
    /// Single characters are dropped — a middle INITIAL is not a discriminator on a `LIKE '%X%'` (every
    /// owner string containing the letter would match), so keeping it would narrow to noise.
    static func ownerTokens(_ name: String) -> [String] {
        var seen = Set<String>()
        return name.uppercased().replacingOccurrences(of: ",", with: " ").split(separator: " ")
            .map { likeToken(String($0)) }.filter { $0.count > 1 && seen.insert($0).inserted }
    }

    /// The ArcGIS owner-search predicate: EVERY usable token ANDed, not just the first and last.
    /// Returns nil when the name carries no usable token (the caller keeps the honest bad-name gate).
    ///
    /// ROUND-19: this keyed on `toks.first` + `toks.last` only, so every MIDDLE token was silently
    /// dropped from the query — and the middle token is routinely the only discriminator between
    /// relatives sharing a surname and a last name. Live 2026-07-15, Cleveland `GIS_Owner1` for
    /// resolve("Hamrick James Dean") built `LIKE '%HAMRICK%' AND LIKE '%DEAN%'` and matched SEVEN
    /// parcels — GARY DEAN (×4), SHERRILL DEAN HEIRS, JOE DEAN and the searched JAMES DEAN. Six of the
    /// seven are DIFFERENT MEN; "JAMES" alone separates them. ANDing every token takes that same live
    /// search to exactly ONE row (returnCountOnly: 7 → 1, PID 53055), which is the difference between
    /// the round-18 ambiguous gate having to REFUSE the search and the buyer getting their answer.
    ///
    /// Narrowing is always safe under §5.1: the searched owner's string contains all of its own tokens,
    /// so it can never be filtered out — only non-matches are. The round-18 ambiguous gate still stands
    /// behind this for whatever multiplicity survives (true same-name collisions).
    static func ownerWhereClause(name: String, ownerField: String) -> String? {
        let toks = ownerTokens(name)
        guard !toks.isEmpty else { return nil }
        return toks.map { "UPPER(\(ownerField)) LIKE '%\($0)%'" }.joined(separator: " AND ")
    }

    /// Exact subject-parcel predicate. Parcel IDs are identifiers, not owner-search keywords, so the
    /// buyer's value is preserved byte-for-byte after trimming; SQL apostrophes are escaped instead of
    /// silently deleting identity characters. The field comes from the audited county registry.
    static func parcelWhereClause(parcelID rawParcelID: String, parcelField: String) -> String? {
        let parcelID = rawParcelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parcelID.isEmpty,
              !parcelField.isEmpty,
              parcelField.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return "\(parcelField) = '\(parcelID.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Does `owner` contain EVERY token of the searched `name` at a WORD BOUNDARY?
    ///
    /// ROUND-19: the public-records index matches a CONTIGUOUS SUBSTRING of the whole name, so
    /// `owner_name=SMITH JOHN` matches "KLEIN·SMITH JOHN A & STACEE F" — a different family entirely
    /// (live 2026-07-15: total 1799, and that row is `.first`). The index already honours every token
    /// (SMITH JOHN → 1799 vs SMITH JOHN A → 90), so unlike the ArcGIS path there is no dropped token to
    /// wire; the defect is the missing word boundary. Tokens are compared against the owner's own
    /// tokenization, which makes "SMITH" match "SMITH JOHN & KRISTA" and "ROSE/SMITH JOHN" (a real
    /// co-owner) but never "KLEINSMITH".
    static func ownerTokensMatchAtWordBoundary(owner: String?, name: String) -> Bool {
        guard let owner, !owner.isEmpty else { return false }
        let ownerToks = Set(owner.uppercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .map(String.init).joined()
            .split(separator: " ").map(String.init))
        let wanted = ownerTokens(name)
        guard !wanted.isEmpty else { return false }
        return wanted.allSatisfy { ownerToks.contains($0) }
    }

    /// County value field → a positive integer dollars, or nil (0/blank/garbage → nil, never a faked $0).
    static func toMoney(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        let s = "\(v)".replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Double(s) else { return nil }
        let n = Int(d)
        return n > 0 ? n : nil
    }

    private static func pick(_ attrs: [String: Any], _ hints: [String]) -> String {
        for (k, v) in attrs {
            let up = k.uppercased()
            if hints.contains(where: { up.contains($0) }) {
                let s = "\(v)".trimmingCharacters(in: .whitespaces)
                if !s.isEmpty && s.lowercased() != "<null>" && s != "0" { return s }
            }
        }
        return ""
    }

    private static let mailStreetHints = ["MAILADD", "MAIL_ADD", "MAILADR", "OWNERADD", "OWNER_ADD", "OWNADDR", "MAILINGADD", "MAIL_STREET", "MAILADDR"]
    private static let mailCityHints = ["MAILCITY", "MAIL_CITY", "OWNERCITY", "OWNER_CITY", "MAILINGCITY"]
    private static let mailStateHints = ["MAILSTATE", "MAIL_STATE", "OWNERSTATE", "OWNER_STATE", "MAILST"]
    private static let mailZipHints = ["MAILZIP", "MAIL_ZIP", "OWNERZIP", "OWNER_ZIP", "MAILINGZIP", "MAILZIPCODE"]
    private static let homesteadHints = ["HOMESTEAD", "EXEMPT", "HMSTD", "EXEMPTION"]
    private static let deedHints = ["DEED", "DEEDBOOK", "BOOKPAGE", "DEED_REF", "INSTRUMENT"]
    private static let taxHints = ["TAXAMOUNT", "TAX_AMT", "ANNUALTAX", "TOTALTAX", "TAX_DUE", "GROSSTAX"]

    static func ownerMailing(_ attrs: [String: Any]) -> OwnerMailing {
        var street = pick(attrs, mailStreetHints)
        if street.isEmpty {
            let lines = ["ADDRESS1", "ADDRESS2", "ADDRESS3"].compactMap { k -> String? in
                let s = "\(attrs[k] ?? "")".trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            if !lines.isEmpty { street = lines.count == 1 ? lines[0] : lines.joined(separator: " ") }
        }
        guard !street.isEmpty else { return OwnerMailing() }
        let city = pick(attrs, mailCityHints).isEmpty ? "\(attrs["CITY"] ?? "")".trimmingCharacters(in: .whitespaces) : pick(attrs, mailCityHints)
        let state = pick(attrs, mailStateHints).isEmpty ? "\(attrs["STATE"] ?? "")".trimmingCharacters(in: .whitespaces) : pick(attrs, mailStateHints)
        let zip = pick(attrs, mailZipHints).isEmpty ? "\(attrs["ZIP"] ?? "")".trimmingCharacters(in: .whitespaces) : pick(attrs, mailZipHints)
        return OwnerMailing(street: street, city: city, state: state, zip: zip)
    }

    static func debtSignals(_ attrs: [String: Any]) -> DebtSignals {
        let tax = pick(attrs, taxHints)
        return DebtSignals(homesteadExemption: pick(attrs, homesteadHints).nilIfEmpty,
                           deedRef: pick(attrs, deedHints).nilIfEmpty,
                           estAnnualTax: tax.isEmpty ? nil : toMoney(tax))
    }

    /// Owner-name match confidence — does the estate own the subject parcel? Grounded in the
    /// recorded owner string (surname + given token overlap). Never fabricated.
    static func ownership(decedent: String, owner: String?) -> OwnershipConfidence {
        guard let owner = owner, !owner.isEmpty else { return .none }
        let dec = Set(decedent.uppercased().replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init).filter { $0.count > 1 })
        let own = Set(owner.uppercased().replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init).filter { $0.count > 1 })
        guard !dec.isEmpty else { return .low }
        let hits = dec.intersection(own).count
        if hits >= 2 { return .high }
        if hits == 1 { return .medium }
        return .low
    }

    // MARK: ArcGIS query (injectable for offline tests)
    typealias Fetch = (_ url: String, _ params: [String: String]) async -> [String: Any]?

    // MARK: Public-records index fallback (nationwide owner/parcel over OUR harvested index)
    // When a county has no open ArcGIS layer (or the layer has no match), resolve owner+mailing+parcel
    // from the public-records API (RealEstateAPI → ~/BlackLabelRealEstateAPI, ~1.099M rows / 8 states).
    // Injectable like `Fetch` so offline tests stub it; the live defaults call the real client and only
    // ever send PUBLIC params (owner name / county / state) — never a buyer's PII or leads.
    typealias APIResolve = (_ ownerName: String, _ county: String?) async -> PropertyPage
    static let liveAPIResolve: APIResolve = { owner, county in
        await RealEstateAPI.search(ownerName: owner, county: county, perPage: 25)
    }
    typealias OwnerFetch = (_ name: String, _ state: String?) async -> PropertyPage
    static let liveOwnerFetch: OwnerFetch = { name, state in
        await RealEstateAPI.owner(name: name, state: state)
    }

    /// An ArcGIS REST response is an *error envelope* (HTTP 200 with `{"error":{...}}`) rather than
    /// a feature set. Layers that advertise `supportsPagination=false` reject `resultRecordCount`
    /// this way — the body parses fine but carries no `features`. Shared by every fetch path so the
    /// pagination-retry logic (and the countrywide harvester) treats it as a recoverable miss, not
    /// a real "no parcels" answer.
    static func isArcGISError(_ json: [String: Any]) -> Bool { json["error"] != nil }

    /// Tolerant ArcGIS JSON parse. First a strict `JSONSerialization`. ONLY when that fails, repair
    /// invalid backslash escapes (some county layers emit a lone backslash in an owner string, e.g.
    /// "EFFCNTY\dfrazier", which is illegal JSON and makes the WHOLE response unparseable under
    /// `outFields=*`) and retry the parse exactly once. The repair NEVER runs on an already-valid
    /// body, so well-formed responses are returned byte-faithful and untouched.
    static func parseJSON(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        // A backslash is only legal in JSON when it begins a recognized escape: \ / " b f n r t u.
        // Any other backslash is a literal the producer failed to escape → double it so it parses
        // as a literal backslash. (\uXXXX hex digits pass through as ordinary chars after the pair.)
        let validEscape: Set<Character> = ["\\", "/", "\"", "b", "f", "n", "r", "t", "u"]
        var repaired = ""
        repaired.reserveCapacity(raw.count + 16)
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, validEscape.contains(n) {
                    repaired.append(c); repaired.append(n); i += 2; continue   // keep valid escape pair
                }
                repaired.append("\\\\"); i += 1; continue                       // escape the lone backslash
            }
            repaired.append(c); i += 1
        }
        guard let rd = repaired.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: rd) as? [String: Any]
    }

    static func liveFetch(_ url: String, _ params: [String: String]) async -> [String: Any]? {
        var comps = URLComponents(string: url)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = comps.url else { return nil }
        var req = URLRequest(url: u)
        req.setValue("BlackLabelRealEstate/1.0 (macOS parcel)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 22
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = parseJSON(data) else { return nil }
        return json
    }

    /// Resolve a target by OWNER NAME + COUNTY. The live county ArcGIS layer is tried FIRST for
    /// registry counties (it's richer — geometry, debt signals, recorded-sale fields). When the
    /// county has no open layer, OR the layer publishes no match, fall back to the public-records
    /// index (RealEstateAPI) so owner+mailing+parcel still resolve across the 8 API states instead
    /// of gating. The honest gate is preserved ONLY when BOTH the registry and the index have
    /// nothing. Nothing is ever fabricated.
    static func resolve(name: String, county: String, fetch: Fetch = liveFetch,
                        apiResolve: APIResolve = liveAPIResolve) async -> ParcelRecord {
        let cty = county.trimmingCharacters(in: .whitespaces).lowercased()
        // 1) Registry county → live ArcGIS first (richest source).
        if let reg = ParcelRegistry.source(for: cty) {
            let arc = await resolveArcGIS(name: name, county: county, cty: cty, reg: reg, fetch: fetch)
            if arc.available, arc.owner != nil || arc.address != nil || arc.parcel != nil {
                return arc                                   // ArcGIS resolved a real parcel → done (richer)
            }
            // ROUND-18: an AMBIGUOUS owner match is terminal. It has no owner/address/parcel, so it
            // would otherwise fall through to the index widen below — and `resolveViaAPI` takes
            // `results.first`, which is the SAME arbitrary-pick defect the gate above exists to stop.
            // "The county told us several parcels" is knowledge, not absence: never launder it into a
            // confident single answer from another source.
            if arc.source == ambiguousSource { return arc }
            // A clean "no parcel matched that owner in this county" (available, ArcGIS, but empty) →
            // widen to the public-records index: the owner may hold parcels the county layer didn't
            // surface. A transient server-error / bad-name keeps the honest ArcGIS message (retry the
            // richer source) — we never silently swap sources on a network blip.
            if arc.available, arc.source == "arcgis",
               let apiRec = await resolveViaAPI(name: name, queryCounty: cty, displayCounty: county, apiResolve: apiResolve) {
                return apiRec
            }
            return arc
        }
        // 2) No registry entry → fall back to the public-records index instead of an immediate gate.
        if let apiRec = await resolveViaAPI(name: name, queryCounty: cty, displayCounty: county, apiResolve: apiResolve) {
            return apiRec
        }
        // 3) Neither a county ArcGIS layer nor the index had anything → honest gate, never faked.
        return ParcelRecord(available: false, gated: true, county: cty, source: "none",
                            address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                            note: "No open parcel source for \(county.capitalized) County, and the public-records index returned no match — gated, not faked.")
    }

    /// Verify one buyer-selected subject parcel against the county assessor's exact parcel field.
    /// This path never widens to owner search and never selects the first row: byte-identical multipart
    /// siblings collapse, while distinct returned identities or a truncated page fail closed.
    static func resolveParcel(parcelID rawParcelID: String, county: String,
                              fetch: Fetch = liveFetch) async -> ParcelRecord {
        let cty = county.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parcelID = rawParcelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parcelID.isEmpty else {
            return ParcelRecord(available: false, gated: true, county: cty, source: "bad_parcel",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "Enter the subject parcel ID before assessor verification.")
        }
        guard let reg = ParcelRegistry.source(for: cty) else {
            return ParcelRecord(available: false, gated: true, county: cty, source: "none",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "No exact county assessor source is configured for \(county.capitalized) County.")
        }
        guard let whereClause = parcelWhereClause(parcelID: parcelID, parcelField: reg.parcelField) else {
            return ParcelRecord(available: false, gated: true, county: cty, source: "bad_parcel",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "The subject parcel ID could not form a safe exact county query.")
        }

        var params = ["where": whereClause, "outFields": "*", "f": "json", "returnGeometry": "true",
                      "outSR": "4326", "resultRecordCount": "\(exactParcelCandidateCap + 1)"]
        var capRequested = true
        var json = await fetch(reg.url, params)
        if json == nil || isArcGISError(json!) {
            params.removeValue(forKey: "resultRecordCount")
            capRequested = false
            json = await fetch(reg.url, params)
        }
        guard let json, !isArcGISError(json) else {
            return ParcelRecord(available: false, gated: false, county: cty, source: "arcgis_exact",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "The county assessor did not return a successful response. Retry verification.")
        }
        let features = json["features"] as? [[String: Any]] ?? []
        var distinct: [String: ParcelRecord] = [:]
        var order: [String] = []
        for feature in features {
            guard let attrs = feature["attributes"] as? [String: Any] else { continue }
            let record = arcgisRecord(feature, attrs: attrs, reg: reg, cty: cty,
                                      county: county, name: nil, source: "arcgis_exact")
            guard record.parcel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(parcelID) == .orderedSame else { continue }
            let identity = displayedIdentity(record)
            if distinct[identity] == nil { distinct[identity] = record; order.append(identity) }
        }
        guard let firstID = order.first, var record = distinct[firstID] else {
            return ParcelRecord(available: true, gated: true, county: cty, source: "arcgis_exact",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "The county assessor returned no exact match for parcel \(parcelID). Identity remains unresolved.")
        }
        let candidates = order.compactMap { distinct[$0] }.map(candidate(from:))
        let hitCap = capRequested && features.count > exactParcelCandidateCap
        let serverTruncated = (json["exceededTransferLimit"] as? Bool) == true
        if order.count > 1 || hitCap || serverTruncated {
            return ParcelRecord(available: true, gated: true, county: cty, source: "arcgis_exact_ambiguous",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                candidates: candidates,
                                note: "The exact parcel query returned multiple distinct assessor identities or a cut-off page. No subject identity was selected.")
        }
        record.note = "Exact match on the county assessor's \(reg.parcelField) field."
        return record
    }

    static let exactParcelCandidateCap = 5

    /// The live county-ArcGIS resolve path (registry counties only). Returns an honest gate/no-match
    /// ParcelRecord; the orchestrator decides whether to widen to the public-records index.
    private static func resolveArcGIS(name: String, county: String, cty: String,
                                      reg: CountyParcelSource, fetch: Fetch) async -> ParcelRecord {
        guard let where_ = ownerWhereClause(name: name, ownerField: reg.ownerField) else {
            return ParcelRecord(available: false, gated: true, county: cty, source: "bad_name",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "Owner name has no usable letters — gated, not faked.")
        }
        // ROUND-20 TRUNCATION GATE, part 1 — ask for ONE MORE than we will accept.
        // Round 19 capped this at exactly 5. That made a full page INVISIBLE: 5 rows that collapse to
        // one identity (the multipart-ring case) are indistinguishable from 5-of-N where a 6th DISTINCT
        // parcel sits just past the cap — and the resolver rendered the collapsed single answer with
        // confidence. Asking for cap+1 makes truncation self-evident: receiving cap+1 rows PROVES the
        // county held at least cap+1 matches, so uniqueness is UNPROVEN and the answer must be refused.
        var params = ["where": where_, "outFields": "*", "f": "json", "returnGeometry": "true",
                      "resultRecordCount": "\(ownerCandidateCap + 1)"]
        var capRequested = true
        var json = await fetch(reg.url, params)
        // Pagination-tolerant retry: layers with supportsPagination=false answer resultRecordCount
        // with an HTTP-200 error envelope (no features). Drop the cap and try ONCE more — the general
        // fix for those MapServers (e.g. Bryan), not a per-county band-aid.
        if json == nil || isArcGISError(json!) {
            params.removeValue(forKey: "resultRecordCount")
            capRequested = false
            json = await fetch(reg.url, params)
        }
        guard let json, !isArcGISError(json) else {
            return ParcelRecord(available: false, gated: false, county: cty, source: "arcgis",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "County GIS server didn't respond — try again. Nothing was invented.")
        }
        let feats = json["features"] as? [[String: Any]] ?? []
        // ── ROUND-18 AMBIGUOUS-MATCH GATE (mirrors the round-16 TitleChain shape rule) ────────────
        // This query is an OWNER-NAME `LIKE` predicate, so MANY parcels legitimately match it — and
        // taking `feats.first` rendered an ARBITRARY one of them as THE answer. ArcGIS defines no row
        // order without `orderByFields`, so which parcel a buyer saw was the server's whim: its owner,
        // situs address and assessed value could all belong to a different property (§5.1).
        //
        // This is NOT hypothetical and NOT a non-unique-parcelField problem — the round-17 packet
        // called it that, and pinned Durham as "immune as a side effect" of its bijective REID. Live
        // enumeration (2026-07-15) REFUTES that: resolveArcGIS never queries the parcelField at all,
        // it only READS it, so key bijectivity cannot bound the candidate set. Owner "SMITH JOHN":
        //   · Durham   (REID, PROVEN-bijective) → 33 parcels. feats.first = 2135 SUNSET AVE $369,298,
        //     but candidate 4 is 1010 BURCH AVE $912,829 — 2.5× the value, a different property.
        //   · Buncombe (pin, non-unique)        → 35 parcels. feats.first = 502 SUGAR MAPLE LN
        //     $873,900; the set spans $85,800 … $1,229,400 (14×).
        // Both sets also contain rows that are not the searched owner at all — LIKE '%JOHN%' matches
        // "JOHNSON, ARCHIE C III" (Durham) and "ENDE JOHN FRANCIS" (Buncombe). EVERY registry county
        // is affected, which is why the gate is here in the resolver and keyed on nothing county-specific.
        //
        // The rule: collapse candidates whose ENTIRE DISPLAYED identity is byte-identical (a layer can
        // return one parcel once per multipart geometry ring), then refuse if MORE THAN ONE distinct
        // parcel survives. The identity is computed from the built ParcelRecord — the very value that
        // gets rendered — so what we compare can never drift from what we display.
        var distinct: [String: ParcelRecord] = [:]
        var order: [String] = []
        for f in feats {
            guard let attrs = f["attributes"] as? [String: Any] else { continue }
            let rec = arcgisRecord(f, attrs: attrs, reg: reg, cty: cty, county: county, name: name)
            let id = displayedIdentity(rec)
            if distinct[id] == nil { distinct[id] = rec; order.append(id) }
        }
        guard let firstID = order.first, let rec = distinct[firstID] else {
            return ParcelRecord(available: true, gated: false, county: cty, source: "arcgis",
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                note: "No parcel matched that owner in \(county.capitalized) County — gated, not faked.")
        }
        // The candidates are REAL rows we already hold — the buyer's chooser (round 20). Built from the
        // same `distinct` records the identity collapse produced, so what we OFFER can never drift from
        // what we would DISPLAY.
        let cands = order.compactMap { distinct[$0] }.map(candidate(from:))
        if order.count > 1 {
            // `source` is deliberately NOT "arcgis": the orchestrator widens an empty ArcGIS answer to
            // the public-records index, and that path takes `results.first` — widening here would
            // re-introduce the identical arbitrary-pick defect through the other door. Ambiguity is
            // TERMINAL and honest. The count is deliberately not quoted: `resultRecordCount` caps the
            // page, so the candidate set is a floor, not the true total (Durham really has 33).
            return ParcelRecord(available: true, gated: true, county: cty, source: ambiguousSource,
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                candidates: cands, note: ambiguousMatchNote(county: county))
        }
        // ROUND-20 TRUNCATION GATE, part 2 — a FULL page cannot prove uniqueness.
        // Reaching here means every fetched row collapsed to ONE identity. That is the multipart-ring
        // case the collapse exists to serve — but ONLY on a page we can prove is complete. A full page
        // (cap+1 rows back from a cap+1 request) proves the opposite: the county had at least one more
        // row than we accepted, and the round-18 evidence says the very next row can be a DIFFERENT
        // parcel (Durham's 33, Buncombe's 35). `exceededTransferLimit` is the server's OWN truncation
        // flag and is honoured on both paths — it is the only truncation signal available on the
        // uncapped retry, where the layer still cuts the page off at its private maxRecordCount.
        // Fail CLOSED: "exactly cap+1 matches" and "cap+1 of thousands" are indistinguishable from
        // here, so both refuse. A count we cannot demonstrate is not a count we may render (§5.1).
        let hitCap = capRequested && feats.count > ownerCandidateCap
        let serverTruncated = (json["exceededTransferLimit"] as? Bool) == true
        if hitCap || serverTruncated {
            return ParcelRecord(available: true, gated: true, county: cty, source: ambiguousSource,
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                candidates: cands, note: truncatedMatchNote(county: county))
        }
        return rec
    }

    /// The owner-search page size we will ACCEPT. The request asks for `ownerCandidateCap + 1` so that a
    /// full page is self-evidently truncated — see the round-20 gate in `resolveArcGIS`.
    static let ownerCandidateCap = 5

    /// Reduce a built record to the candidate the buyer chooses from. Deliberately derived FROM the
    /// ParcelRecord (not from raw attributes) so a candidate can only ever show fields we would render.
    static func candidate(from r: ParcelRecord) -> ParcelCandidate {
        ParcelCandidate(owner: r.owner, address: r.address, parcel: r.parcel, assessedValue: r.assessedValue)
    }

    /// Shown when the page came back FULL, so uniqueness is unproven (round 20). Deliberately distinct
    /// from `ambiguousMatchNote`: there we KNOW several parcels matched; here we know only that we
    /// cannot see the whole answer. Claiming "matches more than one parcel" would assert a fact we
    /// have not established (§5.1) — the honest statement is that the answer is cut off.
    static func truncatedMatchNote(county: String) -> String {
        "\(county.capitalized) County returned a full page of matches for that owner name, so there may be more parcels than this search can see — which single parcel is this one can't be proven from a cut-off answer, and picking one would be a guess. Nothing was invented. Add a middle name or initial, or search by the county's parcel id."
    }

    /// `source` for an owner search that matched several distinct parcels. A named constant because
    /// `resolve` must be able to tell this apart from a plain empty ArcGIS answer (which it widens).
    static let ambiguousSource = "arcgis_ambiguous"

    static func ambiguousMatchNote(county: String) -> String {
        "That owner name matches more than one parcel in \(county.capitalized) County, so no single parcel's owner, address or assessed value can be shown as this one's — picking one would be a guess. Nothing was invented. Add a middle name or initial, or search by the county's parcel id."
    }

    /// Everything a buyer SEES for one parcel, as one comparable string. Geometry is excluded on
    /// purpose: a multipart parcel publishes one row per ring with a different centroid but identical
    /// facts, and every ring's centroid is a real point ON that parcel — so collapsing them keeps the
    /// honest situs while `note` is excluded because it is our prose, not the county's data.
    static func displayedIdentity(_ r: ParcelRecord) -> String {
        // Built up statement-by-statement, not as one array literal: the 12-element literal mixing
        // `??` defaults with `String.init` overloads exceeds the CI release-Xcode type-checker's
        // time budget ("unable to type-check this expression in reasonable time") and killed every
        // iOS archive since 07-15. Same fields, same order, same separator — identical output.
        var parts: [String] = []
        parts.append(r.parcel ?? "")
        parts.append(r.owner ?? "")
        parts.append(r.address ?? "")
        parts.append(r.assessedValue.map { String($0) } ?? "")
        parts.append(r.ownerMail.street)
        parts.append(r.ownerMail.city)
        parts.append(r.ownerMail.state)
        parts.append(r.ownerMail.zip)
        parts.append(r.debt.homesteadExemption ?? "")
        parts.append(r.debt.deedRef ?? "")
        parts.append(r.debt.estAnnualTax.map { String($0) } ?? "")
        parts.append(r.ownershipConfidence.rawValue)
        return parts.joined(separator: "|")
    }

    /// Build the displayed record for ONE ArcGIS feature. Pure — no network, no ordering assumptions.
    private static func arcgisRecord(_ f: [String: Any], attrs: [String: Any], reg: CountyParcelSource,
                                     cty: String, county: String, name: String?,
                                     source: String = "arcgis") -> ParcelRecord {
        let geom = f["geometry"] as? [String: Any] ?? [:]
        let parcel = "\(attrs[reg.parcelField] ?? attrs["PARCELID"] ?? attrs["PARID"] ?? "")".nilIfEmpty
        let owner = "\(attrs[reg.ownerField] ?? "")".trimmingCharacters(in: .whitespaces).nilIfEmpty
        let value = reg.valueField.flatMap { toMoney(attrs[$0]) }
        // A pid-only / owner-search county (addrField == nil) publishes no situs address; `address`
        // stays nil (never a fabricated situs) and the record carries a named note so an address-based
        // search can't be mistaken for a fabricated match — resolution is owner-name → parcel id + deed.
        let address = reg.addrField.flatMap { "\(attrs[$0] ?? "")".trimmingCharacters(in: .whitespaces).nilIfEmpty }
        let note = reg.addrField == nil
            ? "\(county.capitalized) County's parcel layer publishes no situs address (owner/PID-search only) — matched by owner name to the parcel id + deed; no address search, no fabricated address."
            : ""
        return ParcelRecord(available: true, gated: false, county: cty, source: source,
                            address: address,
                            parcel: parcel, owner: owner, assessedValue: value,
                            lat: geom["y"] as? Double, lng: geom["x"] as? Double,
                            ownershipConfidence: name.map { ownership(decedent: $0, owner: owner) } ?? .none,
                            ownerMail: ownerMailing(attrs), debt: debtSignals(attrs),
                            note: note)
    }

    // MARK: - Public-records index fallback (nationwide owner/parcel resolution)

    /// Resolve owner+mailing+parcel from the public-records index when the county ArcGIS layer can't.
    /// Sends PUBLIC params only (owner name + county, then widened to all states). Returns nil when the
    /// index has nothing — the caller then keeps the honest gate. The "no usable owner letters" check
    /// keeps a junk name network-free (mirrors the ArcGIS bad-name gate).
    private static func resolveViaAPI(name: String, queryCounty: String, displayCounty: String,
                                      apiResolve: APIResolve) async -> ParcelRecord? {
        let usable = name.uppercased().replacingOccurrences(of: ",", with: " ").split(separator: " ")
            .map { likeToken(String($0)) }.filter { $0.count > 1 }
        guard !usable.isEmpty else { return nil }
        let q = name.trimmingCharacters(in: .whitespaces)
        var page = await apiResolve(q, queryCounty.isEmpty ? nil : queryCounty)
        if page.results.isEmpty { page = await apiResolve(q, nil) }   // widen: owner across all 8 API states
        // ROUND-18: the SIBLING of the ArcGIS arbitrary-pick gate above. `results.first` had exactly the
        // same defect, on the path that serves EVERY county with no open ArcGIS layer. Live 2026-07-15:
        // /v1/search?owner_name=SMITH+JOHN returns total=1799, and .first is 'KLEINSMITH JOHN A & STACEE F'
        // ($622,600, AK) — not the searched owner at all ("KLEIN·SMITH" contains the token), and the rows
        // come back state-ordered, so the arbitrary pick is alphabetically biased rather than merely random.
        // The `apiResolve(q, nil)` widen above makes this WORSE by design: it drops the county and searches
        // all 8 states. Same rule, same reason: collapse byte-identical duplicates, refuse beyond one.
        // ROUND-19: drop the rows the index matched only as a CONTIGUOUS SUBSTRING across a word
        // boundary ("KLEINSMITH JOHN" for owner "SMITH JOHN"). Strictly narrowing — the searched owner
        // contains all of its own tokens, so this can only remove non-matches (§5.1).
        let matched = page.results.filter { ownerTokensMatchAtWordBoundary(owner: $0.owner_name, name: name) }
        var distinct: [String: ParcelRecord] = [:]
        var order: [String] = []
        for r in matched {
            let rec = parcelRecord(from: r, requestedCounty: displayCounty, decedentName: name)
            let id = displayedIdentity(rec)
            if distinct[id] == nil { distinct[id] = rec; order.append(id) }
        }
        guard let firstID = order.first, let rec = distinct[firstID] else { return nil }
        // ROUND-20: the chooser's SIBLING surface. Round 18's lesson was that a fix applied to
        // resolveArcGIS alone leaves this path — which serves EVERY county with no open ArcGIS layer —
        // carrying the identical defect through the other door. So the candidates are wired here too,
        // off the same already-fetched, word-boundary-filtered index rows.
        let cands = order.compactMap { distinct[$0] }.map(candidate(from:))
        if order.count > 1 {
            return ParcelRecord(available: true, gated: true, county: displayCounty.lowercased(),
                                source: ambiguousSource,
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                candidates: cands, note: ambiguousMatchNote(county: displayCounty))
        }
        // TRUNCATION GATE. The filter above runs client-side over ONE page (perPage 25) while `total`
        // counts what the INDEX matched — live "SMITH JOHN" is total=1799 against 25 fetched. Collapsing
        // a truncated page to a single survivor and rendering it would re-introduce the very arbitrary
        // pick this function exists to stop: the 1,774 rows we never fetched may hold other genuine
        // word-boundary matches, so uniqueness is UNPROVEN, not proven. Only a page that provably
        // carries every matched row can resolve. A `total` the index omits is treated as truncated —
        // fail closed, never assume completeness we cannot demonstrate.
        guard let total = page.total, total <= page.results.count else {
            return ParcelRecord(available: true, gated: true, county: displayCounty.lowercased(),
                                source: ambiguousSource,
                                address: nil, parcel: nil, owner: nil, assessedValue: nil, lat: nil, lng: nil,
                                candidates: cands, note: truncatedMatchNote(county: displayCounty))
        }
        return rec
    }

    /// Map one public-records index row (PropertyRecord) onto the existing ParcelRecord shape used by
    /// the rest of the app. Every field stays as-published — a missing owner/value/coord stays nil
    /// (never a faked $0 or a guessed point). Debt signals stay nil (the index carries no free
    /// homestead/deed/tax field) and `source` is "api" so callers can tell it apart from ArcGIS.
    /// `address` is the situs STREET only (matching the ArcGIS path) so the situs↔mailing absentee
    /// comparison stays street-to-street.
    static func parcelRecord(from r: PropertyRecord, requestedCounty: String, decedentName: String) -> ParcelRecord {
        let owner = r.owner_name
        let county = (r.county ?? requestedCounty).trimmingCharacters(in: .whitespaces).lowercased()
        let mail = OwnerMailing(street: r.mailing_address ?? "", city: r.mailing_city ?? "",
                                state: r.mailing_state ?? "", zip: r.mailing_zip ?? "")
        return ParcelRecord(
            available: true, gated: false, county: county, source: "api",
            address: r.situs_address, parcel: r.parcel_id, owner: owner,
            assessedValue: r.assessed_value, lat: r.lat, lng: r.lng,
            ownershipConfidence: ownership(decedent: decedentName, owner: owner),
            ownerMail: mail, debt: DebtSignals(),
            note: "Resolved from the public-records index — public fields only (owner, mailing, parcel, assessed value). No phone/skip-trace; assessed value is not a sold comp.")
    }

    /// The owner's FULL parcel portfolio from the public-records index (for skip-trace / lead detail).
    /// Public params only (owner name + optional state) — no PII is ever sent. Each index row is mapped
    /// to a ParcelRecord; returns [] when the index has nothing (never faked). Injectable for tests.
    static func ownerPortfolio(name: String, state: String? = nil,
                               fetch: OwnerFetch = liveOwnerFetch) async -> [ParcelRecord] {
        let nm = name.trimmingCharacters(in: .whitespaces)
        guard nm.count > 1 else { return [] }
        let page = await fetch(nm, state?.trimmingCharacters(in: .whitespaces))
        return page.results.map { parcelRecord(from: $0, requestedCounty: $0.county ?? "", decedentName: nm) }
    }

    /// 3-mile AVERAGE county-assessed value around a point — server-side stats with a
    /// client-side bbox-sample fallback. Honest: county-assessed values, NOT sold comps.
    static func areaValueAvg(county: String, lat: Double, lng: Double,
                             radiusM: Int = threeMilesM, fetch: Fetch = liveFetch) async -> AreaValue {
        guard let reg = ParcelRegistry.source(for: county), let vf = reg.valueField else {
            // Registered-but-value-less → honest parcel COUNT (density), not a price.
            if let reg = ParcelRegistry.source(for: county) {
                let n = await parcelCount(reg: reg, lat: lat, lng: lng, radiusM: radiusM, fetch: fetch)
                return AreaValue(available: n != nil, avgValue: nil, parcels: n ?? 0, radiusMeters: radiusM,
                                 method: "density_only", note: "This county publishes parcels but no value field — showing parcel density, not a price.")
            }
            return AreaValue(available: false, avgValue: nil, parcels: 0, radiusMeters: radiusM, method: "none",
                             note: "No open value layer for \(county.capitalized) County — gated, not faked.")
        }
        // 1) server-side outStatistics avg + count within the radius
        let stat = "[{\"statisticType\":\"avg\",\"onStatisticField\":\"\(vf)\",\"outStatisticFieldName\":\"avg_value\"},{\"statisticType\":\"count\",\"onStatisticField\":\"\(vf)\",\"outStatisticFieldName\":\"n_parcels\"}]"
        let geom = "{\"x\":\(lng),\"y\":\(lat),\"spatialReference\":{\"wkid\":4326}}"
        let sp = ["where": "1=1", "geometry": geom, "geometryType": "esriGeometryPoint", "inSR": "4326",
                  "spatialRel": "esriSpatialRelIntersects", "distance": "\(radiusM)", "units": "esriSRUnit_Meter",
                  "outStatistics": stat, "returnGeometry": "false", "f": "json"]
        if let json = await fetch(reg.url, sp),
           let feats = json["features"] as? [[String: Any]], let a = feats.first?["attributes"] as? [String: Any],
           let avg = toMoney(a["avg_value"]) {
            return AreaValue(available: true, avgValue: avg, parcels: Int(toMoney(a["n_parcels"]) ?? 0),
                             radiusMeters: radiusM, method: "server_stats")
        }
        // 2) bbox-sample fallback (Hall/Harris layers 400 on outStatistics) — average client-side
        let dlat = Double(radiusM) / 111_320.0
        let dlng = Double(radiusM) / (111_320.0 * max(0.1, cos(lat * .pi / 180)))
        let env = "\(lng - dlng),\(lat - dlat),\(lng + dlng),\(lat + dlat)"
        var values: [Int] = []
        for page in 0..<4 {
            let bp = ["where": "1=1", "geometry": env, "geometryType": "esriGeometryEnvelope", "inSR": "4326",
                      "spatialRel": "esriSpatialRelIntersects", "outFields": vf, "returnGeometry": "false",
                      "resultRecordCount": "1000", "resultOffset": "\(page * 1000)", "f": "json"]
            guard let json = await fetch(reg.url, bp), let feats = json["features"] as? [[String: Any]], !feats.isEmpty else { break }
            for f in feats { if let v = toMoney((f["attributes"] as? [String: Any])?[vf]) { values.append(v) } }
            if feats.count < 1000 { break }
        }
        guard !values.isEmpty else {
            return AreaValue(available: false, avgValue: nil, parcels: 0, radiusMeters: radiusM, method: "none",
                             note: "The county GIS server returned no values for that area — nothing invented.")
        }
        return AreaValue(available: true, avgValue: values.reduce(0, +) / values.count, parcels: values.count,
                         radiusMeters: radiusM, method: "bbox_sample")
    }

    static func parcelCount(reg: CountyParcelSource, lat: Double, lng: Double, radiusM: Int, fetch: Fetch) async -> Int? {
        let dlat = Double(radiusM) / 111_320.0
        let dlng = Double(radiusM) / (111_320.0 * max(0.1, cos(lat * .pi / 180)))
        let env = "\(lng - dlng),\(lat - dlat),\(lng + dlng),\(lat + dlat)"
        let p = ["where": "1=1", "geometry": env, "geometryType": "esriGeometryEnvelope", "inSR": "4326",
                 "spatialRel": "esriSpatialRelIntersects", "returnCountOnly": "true", "f": "json"]
        guard let json = await fetch(reg.url, p) else { return nil }
        return (json["count"] as? Int) ?? (json["count"] as? Double).map(Int.init)
    }
}
#endif // circuit-convert

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
