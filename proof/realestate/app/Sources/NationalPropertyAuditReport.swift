// Black Label Real Estate - national property coverage audit/drilldown.
// Reports only indexed records as coverage proof; provider manifests stay audit metadata.
import Foundation

struct NationalPropertyCoverageState: Identifiable, Hashable {
    var state: String
    var recordCount: Int
    var countyCount: Int
    var sourceCount: Int

    var id: String { state }
}

struct NationalPropertyCoverageCounty: Identifiable, Hashable {
    var state: String
    var county: String
    var recordCount: Int
    var sourceCount: Int
    var sourceKinds: [NationalPropertySourceKind]

    var id: String { "\(state):\(county.lowercased())" }
    var locationLabel: String { county.isEmpty ? state : "\(county), \(state)" }
}

struct NationalPropertyCoverageSourceAudit: Identifiable, Hashable {
    var source: NationalPropertySource
    var indexedRecordCount: Int
    var indexedStateCount: Int
    var indexedCountyCount: Int
    var latestImport: NationalPropertyBulkImportCheckpoint?

    var id: String { source.id }
    var manifestOnly: Bool { source.recordCount > 0 && indexedRecordCount == 0 }
    var coverageBasisLabel: String {
        if indexedRecordCount > 0 {
            return "\(indexedRecordCount) indexed records"
        }
        if manifestOnly {
            return "Manifest only - not coverage proof"
        }
        return "No indexed records"
    }
}

struct NationalPropertyCoverageDrilldown: Hashable {
    var coverage: NationalPropertyCoverage
    var states: [NationalPropertyCoverageState]
    var counties: [NationalPropertyCoverageCounty]
    var sources: [NationalPropertyCoverageSourceAudit]
    var imports: [NationalPropertyBulkImportCheckpoint]
    var missingStateCodes: [String]
    var generatedAt: Date

    var honestReadinessLabel: String {
        if coverage.nationwideReady {
            return "Sellable national coverage is proven by dense indexed records."
        }
        if coverage.recordCount == 0 {
            return "No indexed property records yet. Connect a provider or import county/public records."
        }
        if coverage.nationallyIndexed {
            return "All required states/DC have indexed records, but sellable national coverage is NOT proven."
        }
        return "Nationwide coverage is NOT proven. Empty states/counties need provider, licensed bulk, or public-record imports."
    }
}

struct NationalPropertyAuditReport: Hashable {
    var drilldown: NationalPropertyCoverageDrilldown
    var maxCountyRows: Int = 500

    func markdown() -> String {
        var lines: [String] = []
        lines.append("# National Property Coverage Audit")
        lines.append("")
        lines.append("Generated: \(Self.iso.string(from: drilldown.generatedAt))")
        lines.append("Verdict: \(drilldown.honestReadinessLabel)")
        lines.append("")
        lines.append("Coverage basis: indexed property rows only. Source manifest counts are shown for audit, but they do not satisfy state/county coverage.")
        lines.append("")
        lines.append("## Totals")
        lines.append("- Indexed records: \(drilldown.coverage.recordCount)")
        lines.append("- Sources connected: \(drilldown.coverage.sourceCount)")
        lines.append("- States with indexed records: \(drilldown.coverage.stateCount)/\(NationalPropertyCoverage.requiredStateCodes.count)")
        lines.append("- Counties with indexed records: \(drilldown.coverage.countyCount)")
        lines.append("- Rights-approved sources: \(drilldown.coverage.rightsApprovedSources)")
        lines.append("- Rights-blocked sources: \(drilldown.coverage.rightsBlockedSources)")
        lines.append("- Sellable national coverage: \(drilldown.coverage.nationwideReady ? "yes" : "no")")
        lines.append("- Minimum sellable national rows: \(NationalPropertyCoverage.minimumSellableNationwideRecords)")
        lines.append("")
        if drilldown.missingStateCodes.isEmpty {
            lines.append("Missing required states/DC: none")
        } else {
            lines.append("Missing required states/DC: \(drilldown.missingStateCodes.joined(separator: ", "))")
        }
        lines.append("")
        appendSources(to: &lines)
        appendStates(to: &lines)
        appendCounties(to: &lines)
        appendImports(to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendSources(to lines: inout [String]) {
        lines.append("## Sources")
        if drilldown.sources.isEmpty {
            lines.append("No property sources connected.")
            lines.append("")
            return
        }
        lines.append("| Source | Kind | Scope | Rights | Indexed records | Declared/source count | Latest import | Note |")
        lines.append("| --- | --- | --- | --- | ---: | ---: | --- | --- |")
        for row in drilldown.sources {
            let latest = row.latestImport.map { importSummary($0) } ?? "none"
            let note = row.manifestOnly ? "manifest only; not coverage proof" : row.source.coverageNote
            lines.append("| \(Self.cell(row.source.displayLabel)) | \(Self.cell(row.source.kind.label)) | \(Self.cell(row.source.scopeLabel)) | \(Self.cell(row.source.rightsStatusLabel)) | \(row.indexedRecordCount) | \(row.source.recordCount) | \(Self.cell(latest)) | \(Self.cell(note)) |")
        }
        lines.append("")
    }

    private func appendStates(to lines: inout [String]) {
        lines.append("## State Coverage")
        if drilldown.states.isEmpty {
            lines.append("No states have indexed records.")
            lines.append("")
            return
        }
        lines.append("| State | Indexed records | Counties | Sources |")
        lines.append("| --- | ---: | ---: | ---: |")
        for row in drilldown.states {
            lines.append("| \(Self.cell(row.state)) | \(row.recordCount) | \(row.countyCount) | \(row.sourceCount) |")
        }
        lines.append("")
    }

    private func appendCounties(to lines: inout [String]) {
        lines.append("## County Coverage")
        if drilldown.counties.isEmpty {
            lines.append("No counties have indexed records.")
            lines.append("")
            return
        }
        lines.append("| County | Indexed records | Sources | Source kinds |")
        lines.append("| --- | ---: | ---: | --- |")
        let limited = drilldown.counties.prefix(max(0, maxCountyRows))
        for row in limited {
            let kinds = row.sourceKinds.map(\.label).joined(separator: ", ")
            lines.append("| \(Self.cell(row.locationLabel)) | \(row.recordCount) | \(row.sourceCount) | \(Self.cell(kinds)) |")
        }
        if drilldown.counties.count > maxCountyRows {
            lines.append("")
            lines.append("_\(drilldown.counties.count - maxCountyRows) additional county rows omitted by export limit._")
        }
        lines.append("")
    }

    private func appendImports(to lines: inout [String]) {
        lines.append("## Import Receipts")
        if drilldown.imports.isEmpty {
            lines.append("No bulk import receipts recorded.")
            lines.append("")
            return
        }
        lines.append("| Import | Source | Status | Attempted | Committed | Skipped | Duplicates | Updated | Error |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |")
        for receipt in drilldown.imports {
            let updated = Self.iso.string(from: receipt.updatedAt)
            lines.append("| \(Self.cell(receipt.importId)) | \(Self.cell(receipt.sourceLabel)) | \(Self.cell(receipt.status.rawValue)) | \(receipt.attemptedRows) | \(receipt.committedRows) | \(receipt.skippedRows) | \(receipt.duplicateRows) | \(updated) | \(Self.cell(receipt.lastError)) |")
        }
        lines.append("")
    }

    private func importSummary(_ receipt: NationalPropertyBulkImportCheckpoint) -> String {
        "\(receipt.status.rawValue): \(receipt.committedRows) committed, \(receipt.skippedRows) skipped"
    }

    private static func cell(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let iso = ISO8601DateFormatter()
}


extension RealEstateLocalDatabase {
    func propertyCoverageDrilldown(generatedAt: Date = Date()) throws -> NationalPropertyCoverageDrilldown {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    func exportNationalPropertyAuditMarkdown(maxCountyRows: Int = 500,
                                             generatedAt: Date = Date()) throws -> String {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }
}
