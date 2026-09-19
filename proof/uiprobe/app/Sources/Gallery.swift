import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#else
import SwiftCrossUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif

enum Theme {
    static let gold = Color(red: 0.95, green: 0.78, blue: 0.3)
    static let goldGrad = LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.8, green: 0.6, blue: 0.2)], startPoint: .top, endPoint: .bottom)
}

struct Item: Identifiable { let id = UUID(); let name: String }

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}

struct Sparkline: View {
    let points: [CGFloat]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: 0, y: geo.size.height * (1 - first)))
                for (i, p) in points.enumerated().dropFirst() {
                    path.addLine(to: CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(points.count - 1), y: geo.size.height * (1 - p)))
                }
            }
            .stroke(Theme.goldGrad, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct Gallery: View {
    @State private var on = false
    @State private var level = 3
    @State private var volume = 0.5
    @State private var picked: Item?
    @State private var confirm = false
    @State private var showInfo = false
    @State private var ticks = 0
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items = [Item(name: "One"), Item(name: "Two"), Item(name: "Three")]
    let timer = Timer.circuitCombine.publish(every: 1, on: .main, in: .common).autoconnect()
    let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]
    let spacing: CGFloat = 10

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                Text("Gallery")
                    .font(.custom("Avenir Next", size: 24))
                    .tracking(1.5)
                    .foregroundStyle(Theme.goldGrad)
                Text(Date(), style: .relative)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $on) { Text("Enabled") }
                    .toggleStyle(.switch)
                    .tint(Theme.gold)
                Stepper("Level \(level)", value: $level, in: 1...10)
                Slider(value: $volume, in: 0...1, step: 0.1)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        Button(item.name) { picked = item }
                            .buttonStyle(.borderedProminent)
                            .clipShape(Capsule())
                    }
                }
                Sparkline(points: [0.2, 0.5, 0.4, 0.9])
                    .frame(height: 40)
                Circle()
                    .fill(AnyShapeStyle(on ? AnyShapeStyle(Theme.goldGrad) : AnyShapeStyle(.quaternary)))
                    .frame(width: 24, height: 24)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.goldGrad, lineWidth: 2)
                    .frame(height: 20)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time)
                        .monospacedDigit()
                }
                Text("Ticks \(ticks)")
                    .modifier(Card())
                Button("Delete", role: .destructive) { confirm = true }
                    .keyboardShortcut(.delete, modifiers: [])
                Label("Info", systemImage: "info.circle")
                    .onTapGesture { showInfo = true }
                    .help("More about the gallery")
            }
            .padding(spacing)
        }
        .background(.red.opacity(0.05))
        .onChange(of: on) { newValue in ticks += newValue ? 1 : 0 }
        .onChange(of: level) { old, new in ticks += new - old }
        .onReceive(timer) { _ in ticks += 1 }
        .sheet(item: $picked) { item in Text(item.name).padding() }
        .alert("About", isPresented: $showInfo) {
            Button("OK") {}
        } message: {
            Text("Converted with Circuit.")
        }
        .confirmationDialog("Delete everything?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete") { ticks = 0 }
            Button("Cancel") {}
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { ticks = 0 }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: on)
    }
}
