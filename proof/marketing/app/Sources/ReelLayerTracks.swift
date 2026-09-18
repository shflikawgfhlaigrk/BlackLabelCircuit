#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — visible, separate timeline tracks for Reel Studio.
// The controls bind directly to ReelProject/ReelScene render settings; they are not preview-only.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct ReelLayerTracksPanel: View {
    @Binding var scenes: [ReelScene]
    @Binding var music: ReelMusic
    let musicFileName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReelTrackSection(title: "VISUAL CLIPS", icon: "photo.on.rectangle.angled") {
                if scenes.isEmpty {
                    trackHint("Add a visual clip above to start the timeline.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                                clipPill(index: index, scene: scene)
                                if index < scenes.count - 1 {
                                    VStack(spacing: 2) {
                                        Image(systemName: "arrow.right")
                                        Text(scenes[index + 1].transition.label)
                                    }
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundColor(BLTheme.gold)
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }

            ReelTrackSection(title: "TEXT & OVERLAYS", icon: "textformat") {
                if scenes.isEmpty {
                    trackHint("Headline, subtitle, CTA, and logo layers appear here.")
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(scenes.prefix(4).enumerated()), id: \.element.id) { index, scene in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clip \(index + 1)").font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.gold)
                                Text(scene.headline.isEmpty ? "Text layer" : scene.headline)
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .lineLimit(1).foregroundColor(BLTheme.text)
                                Text(String(format: "%.1fs in · %.1fs out", scene.overlayFadeIn, scene.overlayFadeOut))
                                    .font(BLFonts.mono(7.5)).foregroundColor(BLTheme.sub)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7).background(BLTheme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        if scenes.count > 4 {
                            Text("+\(scenes.count - 4)").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                        }
                    }
                }
            }

            ReelTrackSection(title: "PRESENTER (PICTURE-IN-PICTURE)", icon: "person.crop.rectangle") {
                let tiles = scenes.enumerated().compactMap { index, scene in
                    scene.presenter.map { (index, $0) }
                }
                if tiles.isEmpty {
                    trackHint("No presenter tile yet. In a clip above, press Presenter to composite your camera take into a corner of that scene.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tiles, id: \.0) { index, presenter in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("OVER CLIP \(index + 1)").font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.gold)
                                    Text(presenter.corner.label)
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(BLTheme.text).lineLimit(1)
                                    Text(String(format: "%.0f%% wide · %.1fs", presenter.widthFraction * 100, presenter.clip.trimLength))
                                        .font(BLFonts.mono(7.5)).foregroundColor(BLTheme.sub).lineLimit(1)
                                }
                                .frame(width: 108, alignment: .leading).padding(7).background(BLTheme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }

            ReelTrackSection(title: "AUDIO", icon: "waveform") {
                let clipAudioCount = scenes.filter { s in (s.videoClip.map { !$0.muted && $0.audioGain > 0.001 }) ?? false }.count
                let presenterAudioCount = scenes.filter { $0.presenter?.isAudible == true }.count
                if presenterAudioCount > 0 {
                    Label(presenterAudioCount == 1 ? "1 presenter tile carries your voice — mixed into the export at its level"
                                                   : "\(presenterAudioCount) presenter tiles carry your voice — mixed into the export at each tile's level",
                          systemImage: "person.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if clipAudioCount > 0 {
                    Label(clipAudioCount == 1 ? "1 video clip carries its own sound — mixed into the export at the clip's level"
                                              : "\(clipAudioCount) video clips carry their own sound — mixed into the export at each clip's level",
                          systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Place audio over every photo and clip", isOn: $music.enabled)
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).tint(BLTheme.gold)
                if music.enabled {
                    HStack(spacing: 8) {
                        Label(audioName, systemImage: music.source == .buyerTrack ? "music.note" : "waveform.path")
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            .lineLimit(1)
                        Spacer()
                        Text("loops to full timeline").font(BLFonts.mono(8)).foregroundColor(BLTheme.sub)
                    }
                    audioSlider("VOLUME", value: $music.gain, range: 0.05...1, format: "%.0f%%", multiplier: 100)
                    HStack(spacing: 10) {
                        audioSlider("FADE IN", value: $music.fadeIn, range: 0...4, format: "%.1fs")
                        audioSlider("FADE OUT", value: $music.fadeOut, range: 0...4, format: "%.1fs")
                    }
                }
            }

            Text("Drag-style editing is non-destructive: crop, position, filters, opacity, transitions, and every fade are baked into the exported MP4 while the original photos and audio stay untouched.")
                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioName: String {
        if music.source == .builtIn { return "Built-in \(music.mood.rawValue) bed" }
        return musicFileName ?? "Choose a music file below"
    }

    private func clipPill(index: Int, scene: ReelScene) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: scene.videoClip != nil ? "video.fill"
                                  : (scene.imageName.isEmpty ? "rectangle.fill" : "photo.fill"))
                Text("CLIP \(index + 1)")
            }.font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.gold)
            Text(scene.headline.isEmpty ? "Untitled" : scene.headline)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
            if let clip = scene.videoClip {
                Text(String(format: "video %.1f–%.1fs", clip.trimStart, clip.trimEnd))
                    .font(BLFonts.mono(7.5)).foregroundColor(BLTheme.gold.opacity(0.85)).lineLimit(1)
            } else {
                Text(String(format: "%.1fs", scene.seconds)).font(BLFonts.mono(8)).foregroundColor(BLTheme.sub)
            }
        }
        .frame(width: 92, alignment: .leading).padding(7).background(BLTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func trackHint(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
    }

    private func audioSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                             format: String, multiplier: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(BLFonts.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(BLFonts.mono(9, weight: .semibold)).foregroundColor(BLTheme.gold)
            }
            Slider(value: value, in: range).tint(BLTheme.gold)
        }
    }
}

private struct ReelTrackSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.gold)
            content
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.panel.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }
}
#endif // circuit-convert
