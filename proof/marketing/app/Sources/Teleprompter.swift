// Black Label Marketing — teleprompter for on-camera recording.
//
// The prompter is a screen-side reading aid rendered OVER the live camera preview.
// It is never composited into the recorded movie: the recorder writes raw camera
// frames (AVCaptureMovieFileOutput), so nothing drawn here can reach the file.
//
// Scrolling is elapsed-time based (wall clock via TimelineView), not frame-step
// based, so a dropped frame never desyncs the pace from the spoken words.
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
#endif

// MARK: - Latest reel-plan bridge

/// The newest AI reel plan produced anywhere in the app (e.g. the Reference Reel
/// viral planner, or a draft made inside the prompter's own script editor). The
/// camera teleprompter prefills its script from this when one exists — honest
/// empty state otherwise.
final class TeleprompterPlanStore: ObservableObject {
    static let shared = TeleprompterPlanStore()
    @Published private(set) var latestPlan: ViralReelPlan?

    func record(_ plan: ViralReelPlan) {
        if Thread.isMainThread { latestPlan = plan }
        else { DispatchQueue.main.async { self.latestPlan = plan } }
    }
}

// MARK: - Model

/// Script + pacing state for the camera teleprompter. Pure state and arithmetic —
/// the overlay view derives its scroll offset from `progress(at:)` each tick.
final class TeleprompterModel: ObservableObject {
    static let wpmRange: ClosedRange<Double> = 80...220
    static let fontRange: ClosedRange<Double> = 16...44

    @Published var script = ""
    /// Reading pace. Changing it mid-read rescales the elapsed clock so the
    /// current position holds — the scroll speeds up or slows down in place
    /// instead of jumping.
    @Published var wordsPerMinute: Double = 140 {
        didSet {
            guard oldValue > 0, wordsPerMinute > 0, oldValue != wordsPerMinute else { return }
            let now = Date()
            accumulated = elapsed(at: now) * oldValue / wordsPerMinute
            if isPlaying { playStartedAt = now }
        }
    }
    @Published var fontSize: Double = 24
    /// Horizontally flip the script — for reading off teleprompter beam-splitter glass.
    @Published var mirrored = false
    @Published private(set) var isPlaying = false

    private var accumulated: TimeInterval = 0
    private var playStartedAt: Date?

    var wordCount: Int { script.split(whereSeparator: \.isWhitespace).count }
    var hasScript: Bool { wordCount > 0 }

    /// Seconds to read the whole script at the chosen pace. Pure arithmetic from
    /// the real word count — no invented figures.
    var scrollDuration: TimeInterval {
        max(1, Double(wordCount) / max(1, wordsPerMinute) * 60)
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying, let start = playStartedAt else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(start))
    }

    /// 0…1 read progress at a wall-clock instant.
    func progress(at date: Date = Date()) -> Double {
        guard hasScript else { return 0 }
        return min(1, elapsed(at: date) / scrollDuration)
    }

    func play() {
        guard !isPlaying, hasScript else { return }
        if progress() >= 1 { accumulated = 0 }      // replay from the top after a full read
        playStartedAt = Date()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        accumulated = elapsed()
        playStartedAt = nil
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Back to the top; keeps rolling if currently playing.
    func reset() {
        accumulated = 0
        if isPlaying { playStartedAt = Date() }
        objectWillChange.send()
    }

    /// Start from the top — called when a recording take begins.
    func restartFromTop() {
        accumulated = 0
        playStartedAt = Date()
        isPlaying = hasScript
    }

    /// One spoken script from an AI reel plan: hook → proof → CTA.
    static func script(from plan: ViralReelPlan) -> String {
        [plan.hook, plan.proofLine, plan.callToAction]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Prefill from the newest recorded reel plan when the script is still empty.
    @discardableResult
    func seedFromLatestPlanIfEmpty() -> Bool {
        guard script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let plan = TeleprompterPlanStore.shared.latestPlan else { return false }
        script = Self.script(from: plan)
        return true
    }
}

// MARK: - Overlay

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Semi-transparent scrolling script over the live camera preview (top third).
/// Screen-only: the movie output records raw camera frames, so this overlay can
/// never appear in the finished video.
struct TeleprompterOverlay: View {
    @ObservedObject var model: TeleprompterModel
    var onEdit: () -> Void

    @State private var textHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                if model.hasScript {
                    scriptWindow
                } else {
                    emptyHint
                }
                controls
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.top, 42)          // clears the REC / camera-name pills row
            Spacer(minLength: 0)
        }
    }

    private var emptyHint: some View {
        Text("No script yet — Edit script to write or draft one.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private var scriptWindow: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isPlaying)) { tl in
                let readY = proxy.size.height * 0.30
                let offset = readY - model.progress(at: tl.date) * textHeight
                ZStack(alignment: .top) {
                    Rectangle().fill(BLTheme.gold.opacity(0.45))
                        .frame(height: 1.2)
                        .offset(y: readY)
                    Text(model.script)
                        .font(.system(size: model.fontSize, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TeleprompterTextHeightKey.self, value: g.size.height)
                        })
                        .scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                        .offset(y: offset)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .frame(height: 86)
        .onPreferenceChange(TeleprompterTextHeightKey.self) { textHeight = $0 }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            prompterButton(model.isPlaying ? "pause.fill" : "play.fill",
                           help: model.isPlaying ? "Pause the prompter" : "Roll the prompter") {
                model.togglePlay()
            }
            prompterButton("arrow.counterclockwise", help: "Back to the top") { model.reset() }

            Image(systemName: "tortoise.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
            Slider(value: $model.wordsPerMinute, in: TeleprompterModel.wpmRange)
                .controlSize(.mini)
                .frame(width: 74)
                .tint(BLTheme.gold)
            Image(systemName: "hare.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
            Text("\(Int(model.wordsPerMinute)) WPM")
                .font(BLFonts.mono(8.5, weight: .bold)).foregroundColor(.white.opacity(0.8))

            Spacer(minLength: 0)

            prompterButton("textformat.size.smaller", help: "Smaller script text") {
                model.fontSize = max(TeleprompterModel.fontRange.lowerBound, model.fontSize - 2)
            }
            prompterButton("textformat.size.larger", help: "Larger script text") {
                model.fontSize = min(TeleprompterModel.fontRange.upperBound, model.fontSize + 2)
            }
            prompterButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                           active: model.mirrored, help: "Mirror the text (teleprompter glass)") {
                model.mirrored.toggle()
            }
            prompterButton("square.and.pencil", help: "Edit the script") { onEdit() }
        }
    }

    private func prompterButton(_ system: String, active: Bool = false, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(active ? BLTheme.inkOnGold : .white)
                .frame(width: 22, height: 22)
                .background(active ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.white.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private struct TeleprompterTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif // circuit-convert

// MARK: - Script editor sheet

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Write or draft the prompter script. Prefills from the newest AI reel plan when
/// one exists; the draft button runs the same on-device planner (honest template
/// fallback when Apple Intelligence is unavailable — never fabricated metrics).
struct TeleprompterScriptEditor: View {
    @ObservedObject var model: TeleprompterModel
    /// Truthful operator context from the panel (reel name/business + topic) —
    /// used only as the brief for an on-device draft.
    var brand = ""
    var topic = ""

    @ObservedObject private var planStore = TeleprompterPlanStore.shared
    @State private var drafting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Teleprompter script")
                    .font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Text("Scrolls over the live preview while you record. On screen only — never in the finished video.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $model.script)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 190)
                .background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))

            if model.hasScript {
                Text(String(format: "%d words · ≈ %.0fs read at %d WPM",
                            model.wordCount, model.scrollDuration, Int(model.wordsPerMinute)))
                    .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.gold)
            }

            HStack(spacing: 8) {
                if let plan = planStore.latestPlan {
                    GhostButton(label: "Use reel plan", icon: "wand.and.stars") {
                        model.script = TeleprompterModel.script(from: plan)
                    }
                    .help("Prefill from the newest plan (\(plan.source))")
                }
                GhostButton(label: drafting ? "Drafting…" : "Draft with on-device AI", icon: "sparkles") { draft() }
                    .disabled(drafting)
                Spacer()
                if model.hasScript {
                    GhostButton(label: "Clear", icon: "trash") { model.script = "" }
                }
                GoldButton(label: "Done", icon: "checkmark") { dismiss() }
            }

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("PACE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                    Slider(value: $model.wordsPerMinute, in: TeleprompterModel.wpmRange)
                        .controlSize(.small).frame(width: 130).tint(BLTheme.gold)
                    Text("\(Int(model.wordsPerMinute)) WPM")
                        .font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.text)
                }
                Toggle("Mirror text", isOn: $model.mirrored)
                    .toggleStyle(.switch).tint(BLTheme.gold)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
            }
            Text(planStore.latestPlan == nil && !drafting && !model.hasScript
                 ? "No reel plan yet — write your script above, or draft one with the on-device planner."
                 : "The prompter rolls automatically when recording starts.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(minWidth: 470, minHeight: 400)
        .sheetCloseBar()
    }

    private func draft() {
        drafting = true
        let brandText = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicText = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let plan = await ViralReelPlanner.generate(
                brand: brandText.isEmpty ? "This business" : brandText,
                buildSummary: topicText.isEmpty ? "What is being said to camera in this take" : topicText,
                audience: "Viewers of this short-form reel",
                goal: "A clear spoken-to-camera script"
            )
            model.script = TeleprompterModel.script(from: plan)
            TeleprompterPlanStore.shared.record(plan)
            drafting = false
        }
    }
}
#endif // circuit-convert
