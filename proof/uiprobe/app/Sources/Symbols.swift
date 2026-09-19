import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#else
import SwiftCrossUI
#endif

struct Starred: View {
    var body: some View { Image(systemName: "star") }
}
