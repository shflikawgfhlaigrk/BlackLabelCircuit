// Black Label Academy — AC-10 owner calculators.
//
// A curated set of business calculators that operate ONLY on numbers the buyer types in. Every
// calculator shows its formula verbatim — the math is transparent, not a black box — and NONE ships
// a benchmark, average, or "typical" figure baked in (§5.1: no fabricated number, even a default).
// The result is a pure function of the buyer's own inputs.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct CalcInput: Identifiable {
    let id = UUID()
    let label: String
    let unit: String
    var text: String = ""
    var value: Double? { Double(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
}

struct Calculator: Identifiable {
    let id: String
    let name: String
    let blurb: String
    let formula: String                 // shown to the buyer verbatim — transparent math
    let inputs: [CalcInput]
    let resultLabel: String
    let resultUnit: String              // "%", "$", "months", "units", "x", …
    let compute: ([Double]) -> Double?  // pure; nil when inputs are degenerate (e.g. divide-by-zero)
}

enum CalcLibrary {
    // Formulas only. No seeded numbers, no "industry average" constants.
    static let all: [Calculator] = [
        Calculator(
            id: "breakeven", name: "Break-even units",
            blurb: "How many units you must sell to cover fixed costs.",
            formula: "Units = Fixed costs ÷ (Price − Variable cost per unit)",
            inputs: [CalcInput(label: "Fixed costs", unit: "$"),
                     CalcInput(label: "Price per unit", unit: "$"),
                     CalcInput(label: "Variable cost per unit", unit: "$")],
            resultLabel: "Break-even", resultUnit: "units",
            compute: { v in let m = v[1] - v[2]; return m > 0 ? v[0] / m : nil }),

        Calculator(
            id: "gross-margin", name: "Gross margin",
            blurb: "The share of each sale left after the cost of goods.",
            formula: "Margin % = (Price − COGS) ÷ Price × 100",
            inputs: [CalcInput(label: "Price", unit: "$"),
                     CalcInput(label: "Cost of goods (COGS)", unit: "$")],
            resultLabel: "Gross margin", resultUnit: "%",
            compute: { v in v[0] != 0 ? (v[0] - v[1]) / v[0] * 100 : nil }),

        Calculator(
            id: "markup-to-margin", name: "Markup → margin",
            blurb: "Convert a markup percentage into the true profit margin.",
            formula: "Margin % = Markup% ÷ (100 + Markup%) × 100",
            inputs: [CalcInput(label: "Markup", unit: "%")],
            resultLabel: "Margin", resultUnit: "%",
            compute: { v in (100 + v[0]) != 0 ? v[0] / (100 + v[0]) * 100 : nil }),

        Calculator(
            id: "ltv", name: "Customer lifetime value",
            blurb: "The gross revenue an average customer brings over their lifetime.",
            formula: "LTV = Avg order value × Orders per year × Avg lifespan (years)",
            inputs: [CalcInput(label: "Avg order value", unit: "$"),
                     CalcInput(label: "Orders per year", unit: "#"),
                     CalcInput(label: "Avg lifespan", unit: "yrs")],
            resultLabel: "Lifetime value", resultUnit: "$",
            compute: { v in v[0] * v[1] * v[2] }),

        Calculator(
            id: "cac-payback", name: "CAC payback",
            blurb: "Months to recover the cost of acquiring one customer.",
            formula: "Months = CAC ÷ (Monthly revenue per customer × Gross margin %)",
            inputs: [CalcInput(label: "Cost to acquire (CAC)", unit: "$"),
                     CalcInput(label: "Monthly revenue / customer", unit: "$"),
                     CalcInput(label: "Gross margin", unit: "%")],
            resultLabel: "Payback", resultUnit: "months",
            compute: { v in let d = v[1] * v[2] / 100; return d > 0 ? v[0] / d : nil }),

        Calculator(
            id: "runway", name: "Cash runway",
            blurb: "How many months your cash lasts at the current burn.",
            formula: "Months = Cash on hand ÷ Net monthly burn",
            inputs: [CalcInput(label: "Cash on hand", unit: "$"),
                     CalcInput(label: "Net monthly burn", unit: "$")],
            resultLabel: "Runway", resultUnit: "months",
            compute: { v in v[1] > 0 ? v[0] / v[1] : nil }),

        Calculator(
            id: "roi", name: "Return on investment",
            blurb: "The percentage return on money you put in.",
            formula: "ROI % = (Gain − Cost) ÷ Cost × 100",
            inputs: [CalcInput(label: "Gain from investment", unit: "$"),
                     CalcInput(label: "Cost of investment", unit: "$")],
            resultLabel: "ROI", resultUnit: "%",
            compute: { v in v[1] != 0 ? (v[0] - v[1]) / v[1] * 100 : nil }),

        Calculator(
            id: "effective-hourly", name: "Effective hourly rate",
            blurb: "What you actually earn per hour worked.",
            formula: "Rate = Net income ÷ Hours worked",
            inputs: [CalcInput(label: "Net income", unit: "$"),
                     CalcInput(label: "Hours worked", unit: "hrs")],
            resultLabel: "Effective rate", resultUnit: "$/hr",
            compute: { v in v[1] > 0 ? v[0] / v[1] : nil }),

        Calculator(
            id: "profit-margin", name: "Net profit margin",
            blurb: "The share of revenue that becomes profit after all costs.",
            formula: "Margin % = Net profit ÷ Revenue × 100",
            inputs: [CalcInput(label: "Net profit", unit: "$"),
                     CalcInput(label: "Revenue", unit: "$")],
            resultLabel: "Net margin", resultUnit: "%",
            compute: { v in v[1] != 0 ? v[0] / v[1] * 100 : nil }),
    ]

    static func format(_ value: Double, unit: String) -> String {
        let rounded = (value * 100).rounded() / 100
        let n: String
        if rounded == rounded.rounded() { n = String(format: "%.0f", rounded) }
        else { n = String(format: "%.2f", rounded) }
        switch unit {
        case "$", "$/hr": return "$" + n + (unit == "$/hr" ? "/hr" : "")
        case "%": return n + "%"
        default: return n + " " + unit
        }
    }
}

// MARK: - UI

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct CalculatorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar(title: "Owner calculators") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "function").foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                        Text("Every calculator runs on the numbers you type in. Formulas are shown in full — nothing is estimated or benchmarked for you.")
                            .font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(CalcLibrary.all) { CalculatorCard(calculator: $0) }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 520)
        .background(BLTheme.bg)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct CalculatorCard: View {
    let calculator: Calculator
    @State private var inputs: [CalcInput]

    init(calculator: Calculator) {
        self.calculator = calculator
        _inputs = State(initialValue: calculator.inputs)
    }

    private var result: Double? {
        let vals = inputs.map { $0.value }
        guard vals.allSatisfy({ $0 != nil }) else { return nil }
        return calculator.compute(vals.map { $0! })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(calculator.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(calculator.blurb).font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text(calculator.formula).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.goldLite)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(BLTheme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            ForEach($inputs) { $field in
                HStack(spacing: 8) {
                    Text(field.label).font(.system(size: 12)).foregroundColor(BLTheme.text)
                        .frame(width: 168, alignment: .leading)
                    TextField("0", text: $field.text)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(field.unit).font(.system(size: 11)).foregroundColor(BLTheme.sub).frame(width: 34, alignment: .leading)
                }
            }
            Divider().overlay(BLTheme.line)
            HStack {
                Text(calculator.resultLabel).font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.sub)
                Spacer()
                if let r = result {
                    Text(CalcLibrary.format(r, unit: calculator.resultUnit))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                } else {
                    Text("—").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.16), lineWidth: 1))
    }
}
#endif // circuit-convert
