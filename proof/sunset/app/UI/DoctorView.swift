#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct DoctorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let report = state.doctorReport {
                    scoreCard(report)
                    issueCard(report)
                    HStack(alignment: .top, spacing: 16) {
                        releaseCard(report)
                        translationCard(report)
                    }
                    if !report.referenceTraits.isEmpty { referenceCard(report) }
                    if state.isAnalyzingStems || report.stemConflictReport != nil { stemConflictCard(report) }
                    matrixCard
                } else {
                    emptyCard
                    matrixCard
                }
            }
            .padding(20)
        }
        .background(Palette.bg)
        .foregroundColor(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Doctor").font(.system(size: 20, weight: .bold)).foregroundColor(Palette.goldTxt)
                Text("Deterministic release checks").font(.system(size: 11)).foregroundColor(Palette.dim)
            }
            Spacer()
            GhostButton(title: "Analyze") { state.refreshDoctor() }
                .disabled(state.isProcessing || state.isRenderingMatrix)
            GhostButton(title: "Export proof…") { exportProof() }
                .disabled(state.doctorReport == nil)
            GhostButton(title: "Export bundle…") { exportBundle() }
                .disabled(state.result == nil)
            GoldButton(title: state.isRenderingMatrix ? "Rendering…" : "Master matrix") {
                state.renderMasterMatrix()
            }
            .disabled(state.isRenderingMatrix || state.isProcessing)
        }
    }

    private func scoreCard(_ report: DoctorReport) -> some View {
        Card(title: "Release readiness", subtitle: report.summary) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().stroke(Palette.stroke, lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: CGFloat(report.score) / 100)
                        .stroke(scoreColor(report.score), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(report.score)").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("/100").font(.system(size: 10)).foregroundColor(Palette.dim)
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 7) {
                    metric("LUFS", fmt(report.metrics.integratedLUFS), "integrated")
                    metric("LRA", "\(fmt(report.metrics.loudnessRangeLU)) LU", "range")
                    metric("True peak", "\(fmt(report.metrics.truePeakDBTP)) dBTP", "final ceiling")
                    metric("Codec", "\(fmt(report.metrics.codecPeakDBTP)) dBTP", "lossy preview")
                    metric("Crest", "\(fmt(report.metrics.crestFactorDB)) dB", "punch reserve")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    metric("Clips", "\(report.metrics.clippedSamples)", "full-scale samples")
                    metric("DC", String(format: "%.4f", report.metrics.dcOffset), "offset")
                    metric("Mono", String(format: "%.2f", report.metrics.monoCorrelation), "correlation")
                    metric("Low width", String(format: "%.2f", report.metrics.lowEndSideRatio), "sub side ratio")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    metric("Mud", "\(fmt(report.metrics.mudExcessDB)) dB", "180-500 Hz")
                    metric("Harsh", "\(fmt(report.metrics.harshExcessDB)) dB", "2.5-6.5 kHz")
                    metric("Tilt", "\(fmt(report.metrics.spectralTiltDBPerOctave))", "dB/oct")
                    metric("Transients", String(format: "%.1f/s", report.metrics.transientDensity), "density")
                }
            }
        }
    }

    private func issueCard(_ report: DoctorReport) -> some View {
        Card(title: "Mix Doctor", subtitle: "Problems, causes, and deterministic fixes") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            severityPill(issue.severity)
                            Text(issue.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                        }
                        Text(issue.detail).font(.system(size: 11)).foregroundColor(Palette.dim)
                        Text(issue.fix).font(.system(size: 11)).foregroundColor(Palette.gold)
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Palette.stroke.opacity(0.5))
                }
            }
        }
    }

    private func releaseCard(_ report: DoctorReport) -> some View {
        Card(title: "Release checks", subtitle: "Platform and codec gates") {
            VStack(spacing: 7) {
                ForEach(report.releaseChecks) { check in
                    HStack(spacing: 8) {
                        severityDot(check.severity)
                        Text(check.name).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                        Spacer()
                        Text(check.value).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.gold)
                        Text(check.target).font(.system(size: 10)).foregroundColor(Palette.dim)
                    }
                }
                Divider().overlay(Palette.stroke.opacity(0.5)).padding(.vertical, 3)
                ForEach(report.platformEstimates) { estimate in
                    HStack(spacing: 8) {
                        severityDot(estimate.severity)
                        Text(estimate.platform).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                        Spacer()
                        Text(String(format: "%+.1f dB", estimate.playbackGainDB))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.gold)
                        Text(String(format: "%.1f LUFS / %.1f dBTP", estimate.estimatedPlaybackLUFS, estimate.codecPeakDBTP))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
                    }
                }
                Divider().overlay(Palette.stroke.opacity(0.5)).padding(.vertical, 3)
                HStack(spacing: 8) {
                    Text("Codec preview").font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                    Spacer()
                    // Honest: real encode→decode audition is AAC-only; there is no licensed MP3 encoder.
                    Text(CodecPreview.uiLabel).font(.system(size: 10)).foregroundColor(Palette.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func translationCard(_ report: DoctorReport) -> some View {
        Card(title: "Translation", subtitle: "Playback risk by system") {
            VStack(spacing: 8) {
                ForEach(report.translations) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.device).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.goldTxt)
                            Spacer()
                            Text("\(t.score)").font(.system(size: 11, design: .monospaced)).foregroundColor(scoreColor(t.score))
                            Button(action: { state.auditionTranslation(t) }) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11)).foregroundColor(Palette.gold)
                            }
                            .buttonStyle(.plain)
                            .help("Audition \(t.device)")
                        }
                        ProgressView(value: Double(t.score), total: 100).tint(scoreColor(t.score))
                        Text(t.note).font(.system(size: 10)).foregroundColor(Palette.dim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func referenceCard(_ report: DoctorReport) -> some View {
        Card(title: "Reference DNA", subtitle: "Numerical differences from the reference file") {
            VStack(spacing: 6) {
                ForEach(report.referenceTraits) { trait in
                    HStack(spacing: 8) {
                        severityDot(trait.severity)
                        Text(trait.name).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                            .frame(width: 126, alignment: .leading)
                        Text(trait.target).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(Palette.stroke)
                        Text(trait.reference).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.gold)
                        Spacer()
                        Text(trait.delta).font(.system(size: 11, design: .monospaced)).foregroundColor(severityColor(trait.severity))
                    }
                }
            }
        }
    }

    private func stemConflictCard(_ report: DoctorReport) -> some View {
        Card(title: "Stem conflict map", subtitle: "Kick/bass, vocal/synth, snare/presence masking") {
            VStack(alignment: .leading, spacing: 9) {
                if state.isAnalyzingStems {
                    ProgressView().tint(Palette.gold)
                    Text("Analyzing selected stems…").font(.system(size: 11)).foregroundColor(Palette.dim)
                } else if let conflict = report.stemConflictReport {
                    Text(conflict.summary).font(.system(size: 11)).foregroundColor(Palette.dim)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(conflict.lanes) { lane in
                            HStack(spacing: 10) {
                                Text(lane.pair).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.goldTxt)
                                    .frame(width: 150, alignment: .leading)
                                severityBar(lane.severity)
                                Text(lane.frequencyHz.map { freqLabel($0) } ?? "n/a")
                                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.gold)
                                    .frame(width: 58, alignment: .leading)
                                Text(String(format: "%.0f%%", lane.severity * 100))
                                    .font(.system(size: 10, design: .monospaced)).foregroundColor(scoreColor(Int(100 - lane.severity * 70)))
                                    .frame(width: 38, alignment: .trailing)
                                Spacer()
                            }
                            Text("\(lane.carveSuggestion) \(lane.sidechainSuggestion)")
                                .font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    }
                    Divider().overlay(Palette.stroke.opacity(0.45)).padding(.vertical, 2)
                    if conflict.cells.isEmpty {
                        Text("No high-priority fights found.")
                            .font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                    } else {
                        ForEach(conflict.cells.prefix(12)) { cell in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(cell.title).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.goldTxt)
                                        .frame(width: 142, alignment: .leading)
                                    severityBar(cell.severity)
                                    Text(freqLabel(cell.freqHz)).font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.gold)
                                    Text(String(format: "%.0f%%", cell.severity * 100))
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(severityColor(cell.severity >= 0.55 ? .warn : .info))
                                    Spacer()
                                }
                                Text(cell.suggestion).font(.system(size: 10)).foregroundColor(Palette.dim)
                            }
                            Divider().overlay(Palette.stroke.opacity(0.45))
                        }
                    }
                }
            }
        }
    }

    private var matrixCard: some View {
        Card(title: "Master matrix", subtitle: "Render deterministic versions and choose by metrics") {
            VStack(alignment: .leading, spacing: 10) {
                if state.isRenderingMatrix {
                    ProgressView(value: state.progress).tint(Palette.gold)
                }
                if state.masterVariants.isEmpty {
                    Text("No variants rendered.")
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                } else {
                    ForEach(state.masterVariants) { variant in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(variant.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                                Text(variant.blurb).font(.system(size: 10)).foregroundColor(Palette.dim)
                            }
                            Spacer()
                            Text("\(variant.score)/100").font(.system(size: 11, design: .monospaced)).foregroundColor(scoreColor(variant.score))
                            Text("\(fmt(variant.lufs)) LUFS").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.gold)
                            Text("\(fmt(variant.truePeak)) dBTP").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                            Text("\(fmt(variant.lra)) LRA").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                            Text("\(fmt(variant.codecPeak)) codec").font(.system(size: 11, design: .monospaced)).foregroundColor(variant.codecPeak < 0 ? Palette.dim : severityColor(.fail))
                            GhostButton(title: "Hear") { state.auditionVariant(variant) }
                            GhostButton(title: "Apply") { state.applyVariant(variant) }
                        }
                        Divider().overlay(Palette.stroke.opacity(0.45))
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        Card(title: "No analysis", subtitle: "Load or master a track") {
            Text("Doctor runs on the loaded mix or finished master.")
                .font(.system(size: 11)).foregroundColor(Palette.dim)
        }
    }

    private func metric(_ name: String, _ value: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 10)).foregroundColor(Palette.dim).frame(width: 72, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(Palette.gold)
            Text(detail).font(.system(size: 10)).foregroundColor(Palette.dim)
        }
    }

    private func severityPill(_ s: DoctorSeverity) -> some View {
        Text(s.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(severityColor(s))
            .clipShape(Capsule())
    }

    private func severityDot(_ s: DoctorSeverity) -> some View {
        Circle().fill(severityColor(s)).frame(width: 8, height: 8)
    }

    private func severityBar(_ value: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.stroke.opacity(0.45))
                Capsule().fill(value >= 0.55 ? severityColor(.warn) : Palette.gold)
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(width: 120, height: 7)
    }

    private func severityColor(_ s: DoctorSeverity) -> Color {
        switch s {
        case .pass: return Color(red: 0.43, green: 0.86, blue: 0.54)
        case .info: return Palette.gold
        case .warn: return Color(red: 0.98, green: 0.62, blue: 0.24)
        case .fail: return Color(red: 0.94, green: 0.25, blue: 0.22)
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 85 ? severityColor(.pass) : (score >= 65 ? severityColor(.warn) : severityColor(.fail))
    }

    private func fmt(_ v: Double) -> String {
        v.isFinite ? String(format: "%+.1f", v) : "--"
    }

    private func freqLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    private func exportProof() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveText(defaultName: "\(base) - Sunset proof.txt") {
            state.exportProof(to: url)
        }
    }

    private func exportBundle() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveWav(defaultName: "\(base) - Sunset release.wav") {
            state.exportReleaseBundle(to: url)
        }
    }
}
#endif // circuit-convert
