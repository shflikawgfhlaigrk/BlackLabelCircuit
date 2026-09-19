import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AcademicSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Essay checks").font(.system(size: 12, weight: .bold))
            Text("Built into Ace: MLA formatting, citation consistency, quotation matching and a local writing review.")
                .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            Text("Each saved essay includes a review tied to that document. Ace checks repetition, long sentences and draft placeholders on this Mac. Review your sources and assignment requirements before submitting.")
                .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.academic.status")
        }
    }
}
#endif // circuit-convert
