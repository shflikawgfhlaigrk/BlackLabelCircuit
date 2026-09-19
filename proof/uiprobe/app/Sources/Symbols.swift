import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#else
import SwiftCrossUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Starred: View {
    var body: some View { Image(systemName: "star") }
}
#endif // circuit-convert
