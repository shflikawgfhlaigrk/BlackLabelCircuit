import Foundation
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
#else
import SwiftCrossUI
#endif

final class CounterModel: ObservableObject {
    @Published var count = 0
}

struct CounterView: View {
    @StateObject private var model = CounterModel()
    var body: some View {
        VStack {
            Text("Count: \(model.count)")
            Button("Add") { model.count += 1 }
            TextField("Name", text: $model.label)
            Label("Starred", systemImage: "star.fill")
        }
    }
}

extension CounterModel { var label: String { get { "\(count)" } set { count = Int(newValue) ?? count } } }
