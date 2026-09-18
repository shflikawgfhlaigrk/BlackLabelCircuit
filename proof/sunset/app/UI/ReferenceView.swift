#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// ReferenceView: the "Reference" tab — match by a streaming link or a local file.
//
// Paste a SoundCloud / YouTube / Spotify track URL and Sunset resolves its public
// metadata (title/artist) and synthesizes the matching style target. Honest about the
// limit: metadata → style, not the raw audio spectrum (that needs the file).

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

struct ReferenceView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Card(title: "Match by link", subtitle: "SoundCloud · YouTube · Spotify") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Paste a track link…", text: $state.referenceLink)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(9)
                                .background(Palette.ink)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke, lineWidth: 1))
                                .foregroundColor(Palette.goldTxt)
                                .onSubmit { state.resolveReferenceLink() }
                            GoldButton(title: state.isResolvingLink ? "…" : "Understand") {
                                state.resolveReferenceLink()
                            }
                            if !state.referenceLink.isEmpty || state.linkReference != nil {
                                Button(action: { state.clearReferenceLink() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(Palette.dim)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .help("Remove style reference")
                            }
                        }
                        if let err = state.linkError {
                            Text(err).font(.system(size: 11)).foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.35))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let ref = state.linkReference {
                            resolvedCard(ref)
                        }
                        Text("Streaming services don't allow audio download, so Sunset reads the track's public info and matches its STYLE. For an exact spectral match, drop the audio file on the Studio tab.")
                            .font(.system(size: 10)).foregroundColor(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(title: "Match by file", subtitle: "Exact spectral fingerprint") {
                    VStack(alignment: .leading, spacing: 8) {
                        GhostButton(title: state.referenceURL == nil ? "Choose reference audio…" : "Change reference file…") {
                            if let url = FilePanels.openAudio(multiple: false).first { state.loadReference(url) }
                        }
                        if let ref = state.referenceURL {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.badge.magnifyingglass").foregroundColor(Palette.gold).font(.system(size: 11))
                                Text(ref.lastPathComponent).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(action: { state.clearReferenceFile() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Palette.dim)
                                }
                                .buttonStyle(.plain)
                                .help("Remove exact reference")
                            }
                            Text("This file's actual spectrum, loudness and width drive the match.")
                                .font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Reference").font(.system(size: 20, weight: .bold)).foregroundColor(Palette.goldTxt)
            Text("Point Sunset at a sound and it targets that voicing.")
                .font(.system(size: 12)).foregroundColor(Palette.dim)
        }
    }

    private func resolvedCard(_ ref: LinkReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill").foregroundColor(Palette.gold).font(.system(size: 15))
                Text(ref.source).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.dim)
                Spacer()
            }
            Text(ref.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.goldTxt)
                .fixedSize(horizontal: false, vertical: true)
            if !ref.artist.isEmpty {
                Text(ref.artist).font(.system(size: 11)).foregroundColor(Palette.dim)
            }
            Divider().overlay(Palette.stroke)
            HStack {
                Text("Synthesized target").font(.system(size: 10)).foregroundColor(Palette.dim)
                Spacer()
                Text(ref.inferredStyle.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.gold)
            }
            Text(String(format: "%@ · ~%d LUFS · sidechain %d dB · kick %.0f%%",
                        ref.inferredStyle.genre.name, Int(ref.inferredStyle.intensity.targetLUFS),
                        Int(ref.inferredStyle.options.sidechainDepthDB), ref.inferredStyle.options.kickPunch * 100))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
            Text("Applied to Studio — this style now drives your master. Head to Studio and hit MASTER.")
                .font(.system(size: 10)).foregroundColor(Palette.goldTxt)
        }
        .padding(12)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.goldDk.opacity(0.5), lineWidth: 1))
    }
}
#endif // circuit-convert
