#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Reel Studio, Content Studio, Leads CRM, Global Search.
// All work on the buyer's own data, fully on-device. No fabrication, no stubs.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVKit) && !CIRCUIT_WINDOWS_SIM
import AVKit
#endif
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

// MARK: - Reel Studio (REAL native .mp4 generation via AVFoundation)

struct ReelStudioScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    @State private var name = ""
    @State private var business = ""
    @State private var topic = ""
    @State private var city = ""
    @State private var format: ReelFormat = .vertical
    @State private var scenes: [ReelScene] = []
    @State private var fps = 30
    @State private var editingID: ReelProject.ID?

    @State private var rendering = false
    @State private var renderProgress: Double = 0
    @State private var lastRenderedURL: URL?
    @State private var posterImage: NSImage?
    @State private var errorMsg = ""
    @State private var toast = ""
    @State private var relayPlatform: SocialPlatform = .instagram
    @State private var publishing = false                     // direct-to-account reel upload in flight
    @State private var template: ReelTemplate = .promo3
    @State private var style: ReelStyleID = .spotlight        // the visual look applied to every scene
    @State private var grade = ReelColorGrade()               // whole-reel color grade (neutral = off)
    @State private var bgImages: [String: CGImage] = [:]      // imageName -> picked background
    @State private var studioLogo: CGImage?                   // optional logo picked in the studio
    @State private var bgPickerScene: ReelScene.ID?           // which scene's bg picker is open
    @State private var videoPickerScene: ReelScene.ID?        // which scene's video-clip picker is open
    @State private var videoURLs: [String: URL] = [:]         // scene id -> readable session copy of its footage
    @State private var clipThumbs: [String: [CGImage]] = [:]  // scene id -> trim-strip thumbnails
    @State private var presenterPickerScene: ReelScene.ID?    // which scene's presenter-tile picker is open
    @State private var presenterURLs: [String: URL] = [:]     // scene id -> readable copy of its presenter take
    @State private var logoPickerOpen = false
    @State private var voice = ReelVoice()                    // on-device narration settings
    @State private var music = ReelMusic()                    // music bed settings (buyer track or on-device bed)
    @State private var musicURL: URL?                         // buyer's own picked track (copied to temp)
    @State private var musicPickerOpen = false
    @State private var musicLink = ""
    @State private var loadingMusicLink = false
    @State private var allowSilentExport = false               // must be chosen explicitly per project
    @State private var loadedDemoOutput = false                 // one real sample render per screen appearance
    #if os(macOS)
    @StateObject private var cameraRecorder = MarketingCameraRecorder()
    @StateObject private var screenRecorder = MarketingScreenRecorder()
    @StateObject private var splitRecorder = MarketingSplitRecorder()
    @State private var captureMode: MarketingCaptureMode = .camera
    #endif

    /// The preview is useful only while work is rendering or after real output exists. Keeping the
    /// empty preview mounted permanently made a blank black pane consume half of every Mac window.
    private var previewIsVisible: Bool {
        rendering || lastRenderedURL != nil || posterImage != nil
    }

    private var hasSelectedClipAudio: Bool {
        scenes.contains { scene in
            let key = scene.id.uuidString
            if let clip = scene.videoClip, !clip.muted, clip.audioGain > 0.001, videoURLs[key] != nil { return true }
            // A presenter tile's own take is an audio source too — usually THE one (their voice).
            if let pres = scene.presenter, pres.isAudible, presenterURLs[key] != nil { return true }
            return false
        }
    }

    private var audioReadiness: ReelAudioReadiness {
        ReelAudio.readiness(currentProject(), musicURL: musicURL, hasClipAudio: hasSelectedClipAudio)
    }

    private var audioCanRender: Bool {
        switch audioReadiness {
        case .ready: return true
        case .silent: return allowSilentExport
        case .blocked: return false
        }
    }

    #if os(macOS)
    private var latestRecordedTakeURL: URL? {
        switch (cameraRecorder.lastRecordingDate, screenRecorder.lastRecordingDate) {
        case let (cameraDate?, screenDate?):
            return cameraDate >= screenDate ? cameraRecorder.lastRecordingURL : screenRecorder.lastRecordingURL
        case (_?, nil):
            return cameraRecorder.lastRecordingURL
        case (nil, _?):
            return screenRecorder.lastRecordingURL
        case (nil, nil):
            return nil
        }
    }
    #endif

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Reel Studio", subtitle: "Compose a real short-form video and export a native .mp4 — vertical, square, or wide.")

                    Panel(title: "Quick start", icon: "wand.and.stars") {
                        VStack(spacing: 12) {
                            Field(title: "Business / operator", text: $business, prompt: "Summit Plumbing Co.")
                            Field(title: "Topic / offer", text: $topic, prompt: "Spring promo, grand opening…")
                            Field(title: "City (optional)", text: $city, prompt: "Austin, TX")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("TEMPLATE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $template) { ForEach(ReelTemplate.allCases) { Text($0.rawValue).tag($0) } }
                                    .labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                            }
                            GoldButton(label: "Build from “\(template.rawValue)”", fill: true, icon: "rectangle.stack.badge.plus") {
                                scenes = template.scenes(business: business, topic: topic, city: city)
                                style = template.defaultStyle    // each template opens with its best-matched look
                                allowSilentExport = false
                                if name.isEmpty { name = business.isEmpty ? "Untitled reel" : business }
                                toast = "Storyboard ready — pick a style, edit scenes, then render."
                            }
                        }
                    }

                    #if os(macOS)
                    Panel(title: "Record in Marketing", icon: captureMode.icon) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Capture mode", selection: $captureMode) {
                                ForEach(MarketingCaptureMode.allCases) { mode in
                                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .tint(BLTheme.gold)

                            switch captureMode {
                            case .camera:
                                CameraCapturePanel(
                                    recorder: cameraRecorder,
                                    format: format,
                                    accentHex: prefs.brandAccentRGB,
                                    title: name.isEmpty ? business : name,
                                    subtitle: topic,
                                    onFinished: useRecordedVideo,
                                    onMessage: { toast = $0; errorMsg = "" },
                                    onError: { errorMsg = $0; toast = "" }
                                )
                            case .screen:
                                ScreenCapturePanel(
                                    recorder: screenRecorder,
                                    format: format,
                                    accentHex: prefs.brandAccentRGB,
                                    title: name.isEmpty ? business : name,
                                    subtitle: topic,
                                    onFinished: useRecordedVideo,
                                    onMessage: { toast = $0; errorMsg = "" },
                                    onError: { errorMsg = $0; toast = "" }
                                )
                            case .split:
                                SplitCapturePanel(
                                    recorder: splitRecorder,
                                    onFinished: useRecordedVideo,
                                    onMessage: { toast = $0; errorMsg = "" },
                                    onError: { errorMsg = $0; toast = "" }
                                )
                            }
                        }
                    }

                    Panel(title: "Remake a reference reel", icon: "rectangle.on.rectangle.angled") {
                        ReferenceReelBuilderPanel(cameraTake: latestRecordedTakeURL) { url in
                            lastRenderedURL = url
                            posterImage = nil
                            renderProgress = 1
                            toast = "Reference-style reel finished with its original soundtrack."
                            errorMsg = ""
                        }
                    }
                    #endif

                    Panel(title: "Style", icon: "paintpalette.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            LazyVGrid(columns: blGridColumns(), spacing: 8) {
                                ForEach(ReelStyleID.allCases) { s in
                                    Button { withAnimation(.easeOut(duration: 0.15)) { style = s } } label: {
                                        VStack(spacing: 3) {
                                            Text(s.rawValue).font(.system(size: 11.5, weight: .bold, design: .rounded))
                                                .foregroundColor(style == s ? BLTheme.inkOnGold : BLTheme.text)
                                        }
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .background(style == s ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(style == s ? Color.clear : BLTheme.stroke, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }
                            Text(style.blurb).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Your brand accent drives every style. Pick a look, then render — the poster and .mp4 match frame-for-frame.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Panel(title: "Color grade", icon: "camera.filters") {
                        VStack(alignment: .leading, spacing: 10) {
                            GoldButton(label: "Auto — match my footage", fill: true, icon: "sparkles") { runAutoGrade() }
                                .disabled(autoGradeSources.isEmpty)
                                .opacity(autoGradeSources.isEmpty ? 0.5 : 1)
                            if autoGradeSources.isEmpty {
                                Text("Auto measures the photos and clips in your scenes and balances exposure, contrast, and color for you — add a background or footage and it lights up.")
                                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            LazyVGrid(columns: blGridColumns(), spacing: 8) {
                                ForEach(ReelColorGrade.Preset.allCases) { p in
                                    Button { withAnimation(.easeOut(duration: 0.15)) { grade = p.grade } } label: {
                                        Text(p.rawValue).font(.system(size: 11.5, weight: .bold, design: .rounded))
                                            .foregroundColor(ReelColorGrade.Preset.matching(grade) == p ? BLTheme.inkOnGold : BLTheme.text)
                                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                                            .background(ReelColorGrade.Preset.matching(grade) == p ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ReelColorGrade.Preset.matching(grade) == p ? Color.clear : BLTheme.stroke, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }
                            DisclosureGroup {
                                VStack(spacing: 8) {
                                    gradeSlider("Exposure", $grade.exposure, -1...1)
                                    gradeSlider("Contrast", $grade.contrast, 0.6...1.4)
                                    gradeSlider("Saturation", $grade.saturation, 0...2)
                                    gradeSlider("Warmth", $grade.temperature, -100...100)
                                    gradeSlider("Tint", $grade.tint, -100...100)
                                    gradeSlider("Vibrance", $grade.vibrance, -1...1)
                                    if !grade.isNeutral {
                                        HStack {
                                            Spacer()
                                            Button { withAnimation { grade = ReelColorGrade() } } label: {
                                                Text("Reset to neutral").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }.padding(.top, 6)
                            } label: {
                                Text(ReelColorGrade.Preset.matching(grade) == nil ? "Fine-tune (custom)" : "Fine-tune")
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                            }.tint(BLTheme.sub)
                            Text("Applies to every scene — photos and footage alike — in the poster and the exported .mp4. Auto sets the sliders from your real media; presets and fine-tune stay live on top.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Panel(title: "Format & timing", icon: "aspectratio") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ASPECT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $format) { ForEach(ReelFormat.allCases) { Text($0.label).tag($0) } }
                                    .labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                            }
                            HStack {
                                Text("FRAME RATE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Spacer()
                                Picker("", selection: $fps) { Text("24").tag(24); Text("30").tag(30); Text("60").tag(60) }
                                    .labelsHidden().pickerStyle(.segmented).frame(width: 150).tint(BLTheme.gold)
                            }
                            if !scenes.isEmpty {
                                let total = scenes.reduce(0.0) { $0 + max(0.4, $1.seconds) }
                                Text(String(format: "%d scenes · %.1fs · %d frames", scenes.count, total, Int((total * Double(fps)).rounded())))
                                    .font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.gold)
                            }
                        }
                    }

                    Panel(title: "Visual clips & transitions", icon: "rectangle.stack.fill") {
                        VStack(spacing: 10) {
                            if scenes.isEmpty {
                                EmptyState(icon: "rectangle.stack.badge.plus", title: "No scenes yet",
                                           hint: "Use Quick start to generate a storyboard, or add scenes one at a time.")
                            } else {
                                ForEach($scenes) { $s in sceneEditor($s) }
                            }
                            GhostButton(label: "Add scene", icon: "plus") {
                                scenes.append(ReelScene(headline: "New scene", subtitle: "", seconds: 2.4))
                            }
                        }
                    }

                    Panel(title: "Layer tracks", icon: "square.3.layers.3d") {
                        ReelLayerTracksPanel(scenes: $scenes, music: $music,
                                             musicFileName: musicURL?.lastPathComponent)
                    }

                    Panel(title: "Voiceover", icon: "waveform") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $voice.enabled) {
                                Text("Narrate this reel (on-device)").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            }.tint(BLTheme.gold)
                            if voice.enabled {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("VOICE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                    Picker("", selection: $voice.voiceIdentifier) {
                                        Text("System default").tag("")
                                        ForEach(englishVoices, id: \.identifier) { v in Text(v.name).tag(v.identifier) }
                                    }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                                }
                                HStack(spacing: 8) {
                                    Text("PACE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                                    Slider(value: $voice.rate, in: 0.35...0.6).tint(BLTheme.gold)
                                }
                                Text("Uses Apple's built-in speech — free, private, no account. Narration is drawn from each scene's text and mixed into the exported .mp4.")
                                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Panel(title: "Music", icon: "music.note") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $music.enabled) {
                                Text("Add a music bed").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            }.tint(BLTheme.gold)
                            if music.enabled {
                                Picker("", selection: $music.source) { ForEach(MusicSource.allCases) { Text($0.rawValue).tag($0) } }
                                    .labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                                if music.source == .buyerTrack {
                                    HStack(spacing: 8) {
                                        GhostButton(label: musicURL != nil ? "Track ✓" : "Add music file", icon: "waveform.badge.plus") { musicPickerOpen = true }
                                        if musicURL != nil {
                                            Button { musicURL = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                                            Text(musicURL?.lastPathComponent ?? "").font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                                        }
                                    }
                                    .fileImporter(isPresented: $musicPickerOpen, allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio]) { result in
                                        if case .success(let url) = result { loadMusic(url) }
                                    }
                                    HStack(spacing: 8) {
                                        TextField("https://example.com/track.mp3", text: $musicLink)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                            .foregroundColor(BLTheme.text)
                                            .padding(.horizontal, 10).padding(.vertical, 8)
                                            .background(BLTheme.bg2)
                                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                                        Button { loadMusicLink() } label: {
                                            if loadingMusicLink { ProgressView().controlSize(.small) }
                                            else { Label("Load link", systemImage: "link.badge.plus") }
                                        }
                                        .buttonStyle(.borderedProminent).tint(BLTheme.gold)
                                        .disabled(loadingMusicLink || musicLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                    Text("Use a track you have the rights to. It's mixed under any narration; nothing is uploaded.")
                                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("MOOD").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                                        Picker("", selection: $music.mood) { ForEach(MusicMood.allCases) { Text($0.rawValue).tag($0) } }
                                            .labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                                        if music.mood.voicing.bpm > 0 && !scenes.isEmpty {
                                            GhostButton(label: "Sync cuts to beat (\(Int(music.mood.voicing.bpm)) BPM)", icon: "metronome") { syncCutsToBeat() }
                                        }
                                        Text("An on-device generated bed — no samples, no account. Subtle by design so it sits under your narration.")
                                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text("LEVEL").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                                    Slider(value: $music.gain, in: 0.1...0.9).tint(BLTheme.gold)
                                    Text(String(format: "%.0f%%", music.gain * 100)).font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.gold).frame(width: 40)
                                }
                            }
                        }
                    }

                    Panel(title: "Render & export", icon: "film.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            Field(title: "Reel name", text: $name, prompt: "Spring promo reel")
                            HStack(spacing: 8) {
                                Text("LOGO").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                                Button { logoPickerOpen = true } label: {
                                    Label(studioLogo != nil ? "Logo ✓" : "Add logo", systemImage: "seal")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(studioLogo != nil ? BLTheme.green : BLTheme.gold)
                                }.buttonStyle(.plain)
                                if studioLogo != nil {
                                    Button { studioLogo = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                                }
                                Spacer()
                                Text(studioLogo == nil && prefs.logoImage != nil ? "Using brand-kit logo" : "")
                                    .font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub)
                            }
                            .fileImporter(isPresented: $logoPickerOpen, allowedContentTypes: [.image]) { result in
                                if case .success(let url) = result { loadStudioLogo(url) }
                            }
                            if rendering {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text(String(format: "Rendering… %.0f%%", renderProgress * 100))
                                            .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                    }
                                    ProgressView(value: renderProgress).tint(BLTheme.gold)
                                }
                            } else {
                                switch audioReadiness {
                                case .ready(let summary):
                                    Label("Audio ready — \(summary)", systemImage: "speaker.wave.2.fill")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundColor(BLTheme.green)
                                case .blocked(let reason):
                                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                                case .silent:
                                    Toggle("Export a deliberately silent reel", isOn: $allowSilentExport)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded)).tint(BLTheme.gold)
                                    Text("No narration, music, or readable clip audio is selected. Silent export stays blocked until you confirm it here.")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                }
                                GoldButton(label: "Render reel (.mp4)", fill: true, icon: "play.rectangle.fill") { render() }
                                    .opacity(scenes.isEmpty || !audioCanRender ? 0.5 : 1)
                                    .disabled(scenes.isEmpty || !audioCanRender)
                                // Poster / cover frame is a still — instant, no full video render needed.
                                GhostButton(label: "Generate poster frame", icon: "photo.fill") { generatePoster() }
                                    .opacity(scenes.isEmpty ? 0.5 : 1).disabled(scenes.isEmpty)
                                    .help("Render the cover image (still) for thumbnails and social posts.")
                            }
                            if lastRenderedURL != nil {
                                HStack {
                                    GoldButton(label: "Save project", icon: "tray.and.arrow.down.fill") { saveProject() }
                                    GoldButton(label: "Export .mp4…", icon: "square.and.arrow.up") { exportRendered() }
                                }
                            }
                            #if os(macOS)
                            // One composer replaces the old one-network-at-a-time picker: select every
                            // destination, publish now, or add all of them to the automatic queue.
                            if lastRenderedURL != nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    Divider().background(BLTheme.stroke)
                                    Text("PUBLISH EVERYWHERE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                    PublishEverywhereComposer(initialMediaURL: lastRenderedURL,
                                                              suggestedCaption: relayCaption(for: .instagram), compact: true)

                                    Divider().background(BLTheme.stroke)
                                    Text("PHONE FALLBACK").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                    Picker("", selection: $relayPlatform) { ForEach(SocialPlatform.allCases) { Text($0.rawValue).tag($0) } }
                                        .labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                                    GoldButton(label: "Send to phone & post", fill: true, icon: "iphone.and.arrow.forward") { sendToPhone() }
                                    Text("Sends the reel to your own iPhone (\(AppBrand.displayName) app, same Apple ID) over Handoff/AirDrop, then opens \(relayPlatform.rawValue) so you post from your own account — no API keys, no review.")
                                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            #endif
                            if posterImage != nil {
                                GoldButton(label: "Export poster (.png)…", icon: "photo.on.rectangle.angled") { exportPoster() }
                            }
                            if !errorMsg.isEmpty { Label(errorMsg, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true) }
                            if !toast.isEmpty { Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green) }
                        }
                    }

                    if !model.reels.isEmpty {
                        Panel(title: "Saved reels (\(model.reels.count))", icon: "film.stack.fill") {
                            VStack(spacing: 8) {
                                ForEach(model.reels) { r in
                                    HStack {
                                        Image(systemName: "film.fill").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                                            .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(r.name.isEmpty ? "Untitled reel" : r.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                            Text("\(r.format.label) · \(r.scenes.count) scenes · \(String(format: "%.1fs", r.totalSeconds))").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                        }
                                        Spacer()
                                        IconButton(system: "square.and.pencil") { load(r) }
                                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteReel(r) }
                                    }
                                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)
            .splitPaneWidth(min: 380, ideal: 560, max: .infinity)

            if previewIsVisible {
                // Live video preview pane. It appears only when it has work to show and is capped so
                // the editor always remains the primary surface, even in a half-screen Mac window.
                ZStack {
                    BLTheme.bg2.ignoresSafeArea()
                    if let url = lastRenderedURL {
                        VStack(spacing: 12) {
                            ReelPlayerView(url: url)
                                .frame(maxWidth: format == .wide ? 520 : 320, maxHeight: 520)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                                .shadow(color: BLTheme.gold.opacity(0.2), radius: 20, y: 8)
                            Text(DemoMode.active
                                 ? "SAMPLE OUTPUT · Actual .mp4 generated on-device"
                                 : "Rendered preview — your actual .mp4")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(DemoMode.active ? BLTheme.gold : BLTheme.sub)
                                .accessibilityIdentifier("demo.proof.reel.output")
                                .accessibilityValue(DemoMode.active && DemoArtifacts.hasRenderedReel()
                                                    ? "cached real mp4 · \(url.lastPathComponent)"
                                                    : "rendered mp4")
                        }
                        .padding(24)
                    } else if let poster = posterImage {
                        VStack(spacing: 12) {
                            Image(nsImage: poster)
                                .resizable().scaledToFit()
                                .frame(maxWidth: format == .wide ? 520 : 320, maxHeight: 520)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                                .shadow(color: BLTheme.gold.opacity(0.2), radius: 20, y: 8)
                            Text("Poster frame — your actual cover image").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        .padding(24)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView(value: renderProgress).tint(BLTheme.gold).frame(width: 180)
                            Text("Rendering your reel…").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        }
                    }
                }
                .frame(maxWidth: 520)
                .splitPaneWidth(min: 300, ideal: 380, max: 520)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: previewIsVisible)
        .onAppear {
            if business.isEmpty { business = prefs.brandName }
            if city.isEmpty { city = prefs.defaultMarket }
            loadDemoOutputIfNeeded()
        }
    }

    /// Demo acquisition proof: load the saved sample project and show a real .mp4 produced by the
    /// shipped renderer. The artifact is cached outside the buyer workspace and never runs outside
    /// explicit demo mode. A real workspace continues to open with its own projects and no output.
    private func loadDemoOutputIfNeeded() {
        guard DemoMode.active, !loadedDemoOutput, let sample = model.reels.first else { return }
        loadedDemoOutput = true
        load(sample)
        let destination = DemoArtifacts.renderedReelURL
        if DemoArtifacts.hasRenderedReel() {
            lastRenderedURL = destination
            renderProgress = 1
            toast = "Sample output loaded — this is an actual on-device .mp4."
            return
        }

        rendering = true
        renderProgress = 0
        toast = "Rendering the labeled sample reel on-device…"
        let temporary = DemoArtifacts.directoryURL.appendingPathComponent("lighthouse-sample-reel.rendering.mp4")
        try? FileManager.default.createDirectory(at: DemoArtifacts.directoryURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: temporary)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ReelRenderer.render(project: sample, to: temporary) { progress in
                    DispatchQueue.main.async { renderProgress = progress }
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                DispatchQueue.main.async {
                    guard DemoMode.active else { rendering = false; return }
                    lastRenderedURL = destination
                    rendering = false
                    renderProgress = 1
                    toast = "Sample output ready — actual .mp4 generated on-device."
                }
            } catch {
                DispatchQueue.main.async {
                    rendering = false
                    errorMsg = "Sample render failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func useRecordedVideo(_ url: URL) {
        lastRenderedURL = url
        posterImage = nil
        renderProgress = 1
    }

    @ViewBuilder private func sceneEditor(_ s: Binding<ReelScene>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HEADLINE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                Spacer()
                Button { moveScene(s.wrappedValue.id, by: -1) } label: {
                    Image(systemName: "arrow.left").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain).help("Move clip earlier")
                Button { moveScene(s.wrappedValue.id, by: 1) } label: {
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain).help("Move clip later")
                Button { duplicateScene(s.wrappedValue.id) } label: {
                    Image(systemName: "plus.square.on.square").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain).help("Duplicate clip")
                Button { scenes.removeAll { $0.id == s.wrappedValue.id } } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.danger)
                }.buttonStyle(.plain)
            }
            TextField("Eyebrow (small label, optional)", text: s.eyebrow).textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            TextField("Headline", text: s.headline).textFieldStyle(.plain)
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            TextField("Subtitle (optional)", text: s.subtitle).textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            if s.wrappedValue.videoClip == nil {
                HStack(spacing: 8) {
                    Text("DURATION").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                    Slider(value: s.seconds, in: 0.6...6.0, step: 0.2).tint(BLTheme.gold)
                    Text(String(format: "%.1fs", s.seconds.wrappedValue)).font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.gold).frame(width: 38)
                }
            } else {
                // Video scene: the trim IS the duration — the slider would fight the in/out points.
                HStack(spacing: 8) {
                    Text("DURATION").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                    Spacer()
                    Text(String(format: "%.1fs — set by the clip trim below", max(0.4, s.seconds.wrappedValue)))
                        .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.gold)
                }
            }
            HStack(spacing: 8) {
                Text("TRANSITION IN").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                Picker("", selection: s.transition) { ForEach(SceneTransition.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                Text("ROLE").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                Picker("", selection: s.kind) {
                    Text("Opener").tag(SceneKind.opener); Text("Standard").tag(SceneKind.standard); Text("CTA").tag(SceneKind.cta)
                }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                    .help("CTA renders the subtitle as a tappable-looking button chip.")
                Spacer()
                let hasBG = !s.wrappedValue.imageName.isEmpty
                Button { bgPickerScene = s.wrappedValue.id } label: {
                    Label(hasBG ? "Background ✓" : "Background", systemImage: "photo")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(hasBG ? BLTheme.green : BLTheme.gold)
                }.buttonStyle(.plain)
                if hasBG {
                    Button { let k = s.wrappedValue.imageName; s.wrappedValue.imageName = ""; bgImages[k] = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain)
                }
                let hasClip = s.wrappedValue.videoClip != nil
                Button { videoPickerScene = s.wrappedValue.id } label: {
                    Label(hasClip ? "Video ✓" : "Video", systemImage: "video")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(hasClip ? BLTheme.green : BLTheme.gold)
                }.buttonStyle(.plain)
                    .help("Add your own footage — the scene plays the trimmed clip instead of a photo background.")
                if hasClip {
                    Button { removeVideoClip(s) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain)
                }
                let hasPresenter = s.wrappedValue.presenter != nil
                Button { presenterPickerScene = s.wrappedValue.id } label: {
                    Label(hasPresenter ? "Presenter ✓" : "Presenter", systemImage: "person.crop.rectangle")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(hasPresenter ? BLTheme.green : BLTheme.gold)
                }.buttonStyle(.plain)
                    .help("Cut to yourself in a corner: your camera take is composited over this scene as a picture-in-picture tile.")
                if hasPresenter {
                    Button { removePresenter(s) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain)
                }
            }
            .fileImporter(isPresented: Binding(get: { videoPickerScene == s.wrappedValue.id },
                                               set: { if !$0 { videoPickerScene = nil } }),
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result { loadVideoClip(url, into: s) }
                videoPickerScene = nil
            }
            .fileImporter(isPresented: Binding(get: { presenterPickerScene == s.wrappedValue.id },
                                               set: { if !$0 { presenterPickerScene = nil } }),
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result { loadPresenterClip(url, into: s) }
                presenterPickerScene = nil
            }
            if s.wrappedValue.videoClip != nil { videoClipEditor(s) }
            if s.wrappedValue.presenter != nil { presenterEditor(s) }
            if !s.wrappedValue.imageName.isEmpty || s.wrappedValue.videoClip != nil {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("FILTER").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                            Picker("", selection: s.photoFilter) {
                                ForEach(ReelPhotoFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                            Spacer()
                            Button("Reset") {
                                s.wrappedValue.photoScale = 1; s.wrappedValue.photoRotation = 0
                                s.wrappedValue.photoOffsetX = 0; s.wrappedValue.photoOffsetY = 0
                                s.wrappedValue.photoOpacity = 1; s.wrappedValue.photoFilter = .original
                            }.buttonStyle(.plain).foregroundColor(BLTheme.gold)
                        }
                        reelLayerSlider("ZOOM / CROP", value: s.photoScale, range: 1...2.5, format: "%.2fx")
                        reelLayerSlider("ROTATE", value: s.photoRotation, range: -45...45, format: "%.0f°")
                        reelLayerSlider("MOVE X", value: s.photoOffsetX, range: -1...1, format: "%+.2f")
                        reelLayerSlider("MOVE Y", value: s.photoOffsetY, range: -1...1, format: "%+.2f")
                        reelLayerSlider("OPACITY", value: s.photoOpacity, range: 0...1, format: "%.0f%%", multiplier: 100)
                        HStack(spacing: 10) {
                            reelLayerSlider("FADE IN", value: s.photoFadeIn, range: 0...2, format: "%.1fs")
                            reelLayerSlider("FADE OUT", value: s.photoFadeOut, range: 0...2, format: "%.1fs")
                        }
                    }.padding(.top, 8)
                } label: {
                    Label(s.wrappedValue.videoClip != nil ? "Edit video — crop, position, filter & fade"
                                                          : "Edit photo — crop, position, filter & fade",
                          systemImage: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
            }
            DisclosureGroup {
                VStack(spacing: 8) {
                    reelLayerSlider("TEXT OPACITY", value: s.overlayOpacity, range: 0...1, format: "%.0f%%", multiplier: 100)
                    HStack(spacing: 10) {
                        reelLayerSlider("FADE IN", value: s.overlayFadeIn, range: 0...2, format: "%.1fs")
                        reelLayerSlider("FADE OUT", value: s.overlayFadeOut, range: 0...2, format: "%.1fs")
                    }
                }.padding(.top, 8)
            } label: {
                Label("Text & overlay layer", systemImage: "textformat")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            }
        }
        .padding(11).background(BLTheme.panel.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
        .fileImporter(isPresented: Binding(get: { bgPickerScene == s.wrappedValue.id },
                                           set: { if !$0 { bgPickerScene = nil } }),
                      allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { loadBackground(url, into: s) }
            bgPickerScene = nil
        }
    }

    private func moveScene(_ id: UUID, by offset: Int) {
        guard let from = scenes.firstIndex(where: { $0.id == id }) else { return }
        let to = min(scenes.count - 1, max(0, from + offset))
        guard from != to else { return }
        let scene = scenes.remove(at: from)
        scenes.insert(scene, at: to)
    }

    private func duplicateScene(_ id: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        var copy = scenes[index]
        copy.id = UUID()
        if let image = bgImages[copy.imageName] {
            let newKey = "bg-\(copy.id.uuidString)"
            bgImages[newKey] = image
            copy.imageName = newKey
        }
        let oldKey = scenes[index].id.uuidString
        if copy.videoClip != nil {
            // Session video assets are keyed by scene id — point the duplicate at the same file.
            videoURLs[copy.id.uuidString] = videoURLs[oldKey]
            clipThumbs[copy.id.uuidString] = clipThumbs[oldKey]
        }
        if copy.presenter != nil {
            presenterURLs[copy.id.uuidString] = presenterURLs[oldKey]
        }
        scenes.insert(copy, at: index + 1)
    }

    @ViewBuilder private func reelLayerSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
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

    /// The per-scene video-clip editor: filmstrip trim (in/out handles), live length readout,
    /// and the clip's own audio controls. Shown only when the scene carries footage.
    @ViewBuilder private func videoClipEditor(_ s: Binding<ReelScene>) -> some View {
        let key = s.wrappedValue.id.uuidString
        let clip = s.wrappedValue.videoClip ?? ReelVideoClip()
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if videoURLs[key] == nil {
                    Label("This clip's file isn't available in this session — re-add the video so it renders.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
                ClipTrimBar(
                    thumbnails: clipThumbs[key] ?? [],
                    duration: max(0.4, clip.sourceSeconds),
                    trimStart: Binding(get: { s.wrappedValue.videoClip?.trimStart ?? 0 },
                                       set: { s.wrappedValue.videoClip?.trimStart = $0; syncClipDuration(s) }),
                    trimEnd: Binding(get: { s.wrappedValue.videoClip?.trimEnd ?? 0 },
                                     set: { s.wrappedValue.videoClip?.trimEnd = $0; syncClipDuration(s) }))
                HStack {
                    Text(String(format: "IN %.2fs", clip.trimStart))
                        .font(BLFonts.mono(9, weight: .semibold)).foregroundColor(BLTheme.sub)
                    Spacer()
                    Text(String(format: "%.1fs plays", clip.trimLength))
                        .font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.gold)
                    Spacer()
                    Text(String(format: "OUT %.2fs", clip.trimEnd))
                        .font(BLFonts.mono(9, weight: .semibold)).foregroundColor(BLTheme.sub)
                }
                Toggle(isOn: Binding(get: { s.wrappedValue.videoClip?.muted ?? false },
                                     set: { s.wrappedValue.videoClip?.muted = $0 })) {
                    Text("Mute clip audio").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                if !(s.wrappedValue.videoClip?.muted ?? false) {
                    HStack(spacing: 8) {
                        Text("CLIP AUDIO").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                        Slider(value: Binding(get: { s.wrappedValue.videoClip?.audioGain ?? 1 },
                                              set: { s.wrappedValue.videoClip?.audioGain = $0 }), in: 0...1.5).tint(BLTheme.gold)
                        Text(String(format: "%.0f%%", (s.wrappedValue.videoClip?.audioGain ?? 1) * 100))
                            .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.gold).frame(width: 40)
                    }
                    Text("The clip's own sound is mixed with any narration and music bed at this level.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(clip.fileName).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    Spacer()
                    Button { removeVideoClip(s) } label: {
                        Label("Remove clip", systemImage: "trash")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 8)
        } label: {
            Label("Trim video clip — in/out & audio", systemImage: "timeline.selection")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
        }
    }

    /// The presenter picture-in-picture editor: which corner the tile sits in, how big it is, and
    /// the take's own audio. Shown only when the scene carries a presenter take. Every control here
    /// binds to a real render setting — the values are baked into the exported MP4.
    @ViewBuilder private func presenterEditor(_ s: Binding<ReelScene>) -> some View {
        let key = s.wrappedValue.id.uuidString
        let pres = s.wrappedValue.presenter ?? ReelPresenterOverlay()
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if presenterURLs[key] == nil {
                    Label("This presenter take isn't available in this session — re-add the video so the tile renders.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text("CORNER").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                    Picker("", selection: Binding(get: { s.wrappedValue.presenter?.corner ?? .bottomLeft },
                                                  set: { s.wrappedValue.presenter?.corner = $0 })) {
                        ForEach(ReelPresenterCorner.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                    Spacer()
                    Text(String(format: "%.1fs plays", pres.clip.trimLength))
                        .font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold)
                }
                reelLayerSlider("TILE SIZE", value: Binding(get: { s.wrappedValue.presenter?.widthFraction ?? 0.26 },
                                                            set: { s.wrappedValue.presenter?.widthFraction = $0 }),
                                range: ReelPresenterOverlay.widthRange, format: "%.0f%% of frame width", multiplier: 100)
                reelLayerSlider("EDGE MARGIN", value: Binding(get: { s.wrappedValue.presenter?.marginFraction ?? 0.055 },
                                                              set: { s.wrappedValue.presenter?.marginFraction = $0 }),
                                range: 0...0.14, format: "%.1f%%", multiplier: 100)
                reelLayerSlider("CORNER ROUNDING", value: Binding(get: { s.wrappedValue.presenter?.cornerRadiusFraction ?? 0.11 },
                                                                  set: { s.wrappedValue.presenter?.cornerRadiusFraction = $0 }),
                                range: 0...0.5, format: "%.0f%%", multiplier: 100)
                HStack(spacing: 10) {
                    reelLayerSlider("FADE IN", value: Binding(get: { s.wrappedValue.presenter?.fadeIn ?? 0.25 },
                                                              set: { s.wrappedValue.presenter?.fadeIn = $0 }),
                                    range: 0...2, format: "%.1fs")
                    reelLayerSlider("FADE OUT", value: Binding(get: { s.wrappedValue.presenter?.fadeOut ?? 0.3 },
                                                               set: { s.wrappedValue.presenter?.fadeOut = $0 }),
                                    range: 0...2, format: "%.1fs")
                }
                HStack(spacing: 14) {
                    Toggle(isOn: Binding(get: { s.wrappedValue.presenter?.showsBorder ?? true },
                                         set: { s.wrappedValue.presenter?.showsBorder = $0 })) {
                        Text("Accent border").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    }.tint(BLTheme.gold)
                    Toggle(isOn: Binding(get: { s.wrappedValue.presenter?.showsShadow ?? true },
                                         set: { s.wrappedValue.presenter?.showsShadow = $0 })) {
                        Text("Drop shadow").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    }.tint(BLTheme.gold)
                }
                Toggle(isOn: Binding(get: { s.wrappedValue.presenter?.clip.muted ?? false },
                                     set: { s.wrappedValue.presenter?.clip.muted = $0 })) {
                    Text("Mute my voice from this take").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                if !(s.wrappedValue.presenter?.clip.muted ?? false) {
                    HStack(spacing: 8) {
                        Text("MY AUDIO").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                        Slider(value: Binding(get: { s.wrappedValue.presenter?.clip.audioGain ?? 1 },
                                              set: { s.wrappedValue.presenter?.clip.audioGain = $0 }), in: 0...1.5).tint(BLTheme.gold)
                        Text(String(format: "%.0f%%", (s.wrappedValue.presenter?.clip.audioGain ?? 1) * 100))
                            .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.gold).frame(width: 40)
                    }
                }
                HStack {
                    Text(pres.clip.fileName).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    Spacer()
                    Button { removePresenter(s) } label: {
                        Label("Remove presenter", systemImage: "trash")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                    }.buttonStyle(.plain)
                }
                Text("The tile is composited over this scene's picture and baked into the exported .mp4. It sits above the headline and progress chrome and below any burned-in captions.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        } label: {
            Label("Presenter tile — corner, size & audio", systemImage: "person.crop.rectangle")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
        }
    }

    /// Copy the picked presenter take into a temp file (same streamed copy the scene clip uses) so
    /// the background render queue always has read access, then attach the overlay descriptor.
    private func loadPresenterClip(_ url: URL, into s: Binding<ReelScene>) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-presenter-\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dst) }
        catch { errorMsg = "Couldn't read that video file."; return }
        let dur = ReelVideoAV.videoSeconds(of: dst)
        guard dur > 0.1 else {
            try? FileManager.default.removeItem(at: dst)
            errorMsg = "That file has no readable video track."; return
        }
        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try? url.bookmarkData()
        #endif
        // The tile plays for as long as the scene it sits on; a shorter take holds its last frame.
        let want = max(0.4, s.wrappedValue.seconds)
        var overlay = ReelPresenterOverlay()
        overlay.clip = ReelVideoClip(fileName: url.lastPathComponent, path: dst.path, bookmark: bookmark,
                                     sourceSeconds: dur, trimStart: 0, trimEnd: min(dur, want))
        s.wrappedValue.presenter = overlay
        presenterURLs[s.wrappedValue.id.uuidString] = dst
        errorMsg = ""
        toast = "Presenter tile added — bottom left by default. Pick a corner and size in the scene."
    }

    private func removePresenter(_ s: Binding<ReelScene>) {
        presenterURLs[s.wrappedValue.id.uuidString] = nil
        s.wrappedValue.presenter = nil
    }

    /// Re-attach saved presenter takes after loading a project — last session copy first, then the
    /// security-scoped bookmark, exactly like the scene clips.
    private func resolvePresenterClips() {
        for scene in scenes {
            guard let pres = scene.presenter else { continue }
            let key = scene.id.uuidString
            if presenterURLs[key] != nil { continue }
            if let url = pres.clip.resolveReadableCopy() { presenterURLs[key] = url }
        }
    }

    /// A video scene's duration IS its trim length — keep them locked so the storyboard timing,
    /// the render, and the clip-audio placement all agree.
    private func syncClipDuration(_ s: Binding<ReelScene>) {
        guard let clip = s.wrappedValue.videoClip else { return }
        s.wrappedValue.seconds = clip.trimLength
    }

    private func removeVideoClip(_ s: Binding<ReelScene>) {
        let key = s.wrappedValue.id.uuidString
        s.wrappedValue.videoClip = nil
        videoURLs[key] = nil
        clipThumbs[key] = nil
        s.wrappedValue.seconds = min(6.0, max(0.6, s.wrappedValue.seconds))   // back onto the slider's range
    }

    /// Copy the picked movie into a temp file (streamed, so large footage never loads into RAM)
    /// while the security scope is open — the background render queue then always has read access.
    private func loadVideoClip(_ url: URL, into s: Binding<ReelScene>) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-clip-\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dst) }
        catch { errorMsg = "Couldn't read that video file."; return }
        let dur = ReelVideoAV.videoSeconds(of: dst)
        guard dur > 0.1 else {
            try? FileManager.default.removeItem(at: dst)
            errorMsg = "That file has no readable video track."; return
        }
        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try? url.bookmarkData()
        #endif
        let clip = ReelVideoClip(fileName: url.lastPathComponent, path: dst.path, bookmark: bookmark,
                                 sourceSeconds: dur, trimStart: 0, trimEnd: dur)
        s.wrappedValue.videoClip = clip
        s.wrappedValue.seconds = clip.trimLength
        let key = s.wrappedValue.id.uuidString
        videoURLs[key] = dst
        generateClipThumbs(url: dst, key: key, duration: dur)
        errorMsg = ""; toast = "Video clip added — trim the in/out points in the scene."
    }

    /// Build the trim-strip thumbnails off the main thread (real frames from the buyer's footage).
    private func generateClipThumbs(url: URL, key: String, duration: Double) {
        Task.detached(priority: .userInitiated) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            var thumbs: [CGImage] = []
            let count = 8
            for i in 0..<count {
                let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let r = try? await gen.image(at: t) { thumbs.append(r.image) }
            }
            let done = thumbs
            await MainActor.run { clipThumbs[key] = done }
        }
    }

    /// Re-attach saved clips after loading a project: last session copy first, then the
    /// security-scoped bookmark. Anything unresolved keeps an honest re-pick hint in its editor.
    private func resolveVideoClips() {
        for scene in scenes {
            guard let clip = scene.videoClip else { continue }
            let key = scene.id.uuidString
            if videoURLs[key] != nil { continue }
            if let url = clip.resolveReadableCopy() {
                videoURLs[key] = url
                generateClipThumbs(url: url, key: key, duration: clip.sourceSeconds)
            }
        }
    }

    /// Load a picked image file as a scene background (decoded to CGImage, keyed by a stable name).
    private func loadBackground(_ url: URL, into s: Binding<ReelScene>) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMsg = "Couldn't read that image."; return
        }
        let key = "bg-\(s.wrappedValue.id.uuidString)"
        bgImages[key] = img
        s.wrappedValue.imageName = key
        toast = "Background added to the scene."
    }

    private func currentProject() -> ReelProject {
        ReelProject(id: editingID ?? UUID(), name: name, format: format, scenes: scenes,
                    paletteAccentHex: prefs.brandAccentRGB, styleID: style, fps: fps, voice: voice, music: music,
                    grade: grade.isNeutral ? nil : grade)
    }

    private func gradeSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range).tint(BLTheme.gold)
        }
    }

    /// Everything Auto can actually measure: picked scene backgrounds plus the first frame of
    /// each loaded footage clip (the trim-strip thumbnails already decoded).
    private var autoGradeSources: [CGImage] {
        Array(bgImages.values) + clipThumbs.values.compactMap { $0.first }
    }

    private func runAutoGrade() {
        guard let auto = ReelColorGrade.auto(analyzing: autoGradeSources) else { return }
        withAnimation(.easeOut(duration: 0.15)) { grade = auto }
        toast = auto.isNeutral ? "Auto grade: your media is already balanced — left neutral."
                               : "Auto grade: \(auto.summary)"
    }

    /// Copy the buyer's picked audio into a temp file so the background render always has read access
    /// (security-scoped URLs don't survive the hop to the render queue).
    private func loadMusic(_ url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { errorMsg = "Couldn't read that audio file."; return }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("blm-music-\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try data.write(to: dst); musicURL = dst; toast = "Music track added." }
        catch { errorMsg = "Couldn't load that audio file." }
    }

    private func loadMusicLink() {
        loadingMusicLink = true; errorMsg = ""; toast = "Downloading music…"
        Task {
            do {
                let url = try await RemoteMusicLoader.load(musicLink)
                await MainActor.run {
                    musicURL = url; loadingMusicLink = false
                    toast = "Music downloaded and ready to mix."
                }
            } catch {
                await MainActor.run {
                    loadingMusicLink = false; toast = ""
                    errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Snap every scene's duration to the built-in bed's beat grid so cuts land on the beat.
    private func syncCutsToBeat() {
        let bpm = music.mood.voicing.bpm
        guard bpm > 0, !scenes.isEmpty else { return }
        let aligned = ReelAudio.beatAlignedDurations(scenes.map { $0.seconds }, bpm: bpm)
        for i in scenes.indices where i < aligned.count { scenes[i].seconds = aligned[i] }
        toast = "Scene cuts snapped to \(Int(bpm)) BPM."
    }

    /// Assemble the render assets from the studio-picked logo/backgrounds (falling back to the
    /// brand-kit logo in Settings). Shared by the .mp4 render and the still poster.
    private func currentAssets() -> ReelRenderer.Assets {
        var assets = ReelRenderer.Assets()
        if let cg = studioLogo {
            assets.logo = cg
        } else if let logo = prefs.logoImage, let cg = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            assets.logo = cg
        }
        assets.backgrounds = bgImages
        assets.music = musicURL
        assets.videoClips = videoURLs
        assets.presenterClips = presenterURLs
        return assets
    }

    private func render() {
        errorMsg = ""; toast = ""
        switch audioReadiness {
        case .blocked(let reason): errorMsg = reason; return
        case .silent where !allowSilentExport:
            errorMsg = "Choose an audio source or explicitly confirm a silent export."
            return
        case .ready, .silent: break
        }
        rendering = true; renderProgress = 0
        let proj = currentProject()
        let assets = currentAssets()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("blm-reel-\(proj.id.uuidString).mp4")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ReelRenderer.render(project: proj, to: out, assets: assets) { p in
                    DispatchQueue.main.async { renderProgress = p }
                }
                DispatchQueue.main.async { lastRenderedURL = out; rendering = false; renderProgress = 1; toast = "Rendered \(proj.scenes.count) scenes to a native .mp4." }
            } catch {
                DispatchQueue.main.async { rendering = false; errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    #if os(macOS)
    /// Honest caption seed from the reel itself; the buyer edits it on the phone.
    private func relayCaption(for p: SocialPlatform) -> String {
        let base = name.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? (scenes.first?.headline ?? "") : base
    }

    private func sendToPhone() {
        guard let url = lastRenderedURL else { return }
        let placement = ReelRelay.defaultPlacement(for: relayPlatform)
        // Advertise over Handoff (ReelRelay.activityType) so it surfaces on the buyer's own iPhone,
        // plus an AirDrop fallback (the reliable transport). The phone then opens the native composer.
        ReelRelaySender.shared.advertise(fileURL: url, platform: relayPlatform, placement: placement,
                                         caption: relayCaption(for: relayPlatform),
                                         reelID: (editingID?.uuidString ?? name))
        // Neither leg guarantees delivery — Handoff only advertises, and AirDrop opens a picker
        // the buyer can cancel (or the service can be unavailable). Say what actually happened.
        if ReelRelaySender.shared.airdrop(fileURL: url) {
            toast = "AirDrop opened — pick your iPhone to send the reel, then post to \(relayPlatform.rawValue) from your own account. It's also offered via Handoff."
            errorMsg = ""
        } else {
            errorMsg = "AirDrop isn't available on this Mac right now. The reel is still offered to your iPhone via Handoff — or use “Export .mp4…” to share it yourself."
            toast = ""
        }
    }

    /// The honest publish state for the selected network, given the shipped capability table + whether
    /// a real credential is stored. Drives the UI: only `.ready` exposes the direct-upload button.
    /// `expiredAuth` is distinct from `needsAuth`: a credential IS stored, it is simply dead, and the
    /// buyer needs to reconnect rather than start from scratch. (NOTE: this helper currently has no
    /// caller in the shipped UI — it is kept correct so wiring it up cannot resurrect the
    /// stored-token-means-live assumption.)
    enum DirectPublishState { case ready, needsAuth, expiredAuth, needsPublicURL, relayOnly, unsupported }
    private func directPublishState(for p: SocialPlatform) -> DirectPublishState {
        if SocialPublishCapability.desktopRelayGated(p) { return .relayOnly }         // TikTok
        if SocialPublishCapability.fetchesMediaByURL(p) { return .needsPublicURL }    // Instagram / Threads
        if !SocialPublishCapability.supportsLocalVideoPublish(p) { return .unsupported } // Facebook / LinkedIn
        guard let token = SocialCredentialStore.token(for: p), !token.isEmpty else { return .needsAuth }
        // A credential whose recorded expiry has passed is dead: the upload would be accepted by the
        // UI and rejected by the provider. Surface it as needing auth (which it does) rather than
        // exposing a "ready" button that cannot work.
        if SocialCredentialStore.liveness(for: p).isKnownDead { return .expiredAuth }
        return .ready                                                                 // X / YouTube + live credential
    }

    /// Upload the rendered reel straight to the buyer's own connected account. Persists the temp .mp4
    /// into RenderedReels/ first (stable path for the upload + any retry), builds a media-populated
    /// SocialPost, and surfaces the provider's real post id or a real error — never a fake success.
    private func publishReelNow() {
        guard let temp = lastRenderedURL else { return }
        guard let token = SocialCredentialStore.token(for: relayPlatform), !token.isEmpty else {
            errorMsg = "Connect your \(relayPlatform.rawValue) account before publishing."; return
        }
        let platform = relayPlatform
        let durable: URL
        do { durable = try RenderedReelStore.persist(temp, name: name) }
        catch { errorMsg = "Couldn't stage the reel for upload: \(error.localizedDescription)"; return }
        let post = SocialPost.reel(fileURL: durable, caption: relayCaption(for: platform), title: name)
        publishing = true; errorMsg = ""; toast = "Uploading reel to \(platform.rawValue)…"
        Task {
            let result = await SocialPublishService().publish(post, to: platform,
                                                              account: SocialAccount(accessToken: token))
            await MainActor.run {
                publishing = false
                switch result {
                case .success(let r): toast = "Published to \(platform.rawValue). Post id \(r.id)."
                case .failure(let e): errorMsg = e.errorDescription ?? "Publish failed."
                }
            }
        }
    }
    #endif

    private func saveProject() {
        var p = currentProject()
        if editingID == nil { editingID = p.id } else { p.id = editingID! }
        model.upsertReel(p)
        toast = "Reel project saved."
    }

    private func exportRendered() {
        guard let src = lastRenderedURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.nameFieldStringValue = (name.isEmpty ? "reel" : name.replacingOccurrences(of: " ", with: "-").lowercased()) + ".mp4"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.removeItem(at: dst)
            do { try FileManager.default.copyItem(at: src, to: dst); toast = "Exported \(dst.lastPathComponent)." }
            catch { errorMsg = "Couldn't export: \(error.localizedDescription)" }
        }
    }

    private func generatePoster() {
        errorMsg = ""; toast = ""
        let proj = currentProject()
        let assets = currentAssets()
        guard let cg = ReelRenderer.renderPosterFrame(project: proj, assets: assets) else {
            errorMsg = "Couldn't render the poster frame."; return
        }
        posterImage = NSImage(cgImage: cg, size: proj.format.size)
        toast = "Poster frame rendered — export it as a .png."
    }

    private func exportPoster() {
        let proj = currentProject()
        let assets = currentAssets()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = (name.isEmpty ? "reel" : name.replacingOccurrences(of: " ", with: "-").lowercased()) + "-poster.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dst = panel.url {
            if ReelRenderer.writePosterPNG(project: proj, to: dst, assets: assets) {
                toast = "Exported \(dst.lastPathComponent)."
            } else { errorMsg = "Couldn't export the poster frame." }
        }
    }

    private func loadStudioLogo(_ url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMsg = "Couldn't read that logo image."; return
        }
        studioLogo = cg; toast = "Logo added."
    }

    /// English on-device voices for the narration picker (sorted by name).
    private var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    private func load(_ r: ReelProject) {
        editingID = r.id; name = r.name; format = r.format; scenes = r.scenes; fps = r.fps; voice = r.voice
        style = r.styleID; music = r.music; grade = r.grade ?? ReelColorGrade()
        bgImages = [:]; studioLogo = nil; musicURL = nil   // saved projects reference asset names; re-pick session assets
        videoURLs = [:]; clipThumbs = [:]; presenterURLs = [:]
        allowSilentExport = false
        resolveVideoClips()      // clips carry durable bookmarks — re-attach what still resolves
        resolvePresenterClips()  // same for the presenter takes behind the corner tiles
        lastRenderedURL = nil; posterImage = nil; toast = "Loaded \(r.name)."
    }
}

// MARK: - Clip trim bar (filmstrip + draggable in/out handles)

/// Thumbnail-strip trim control: real frames from the buyer's footage with two draggable gold
/// handles. Dimmed regions fall outside the trim. Pure control — readouts live in the caller.
private struct ClipTrimBar: View {
    let thumbnails: [CGImage]
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double

    private let handleW: CGFloat = 10
    private let barH: CGFloat = 46
    /// Minimum trimmed length in seconds (matches the storyboard's shortest scene).
    private let minLength: Double = 0.4

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let d = max(0.01, duration)
            let x0 = CGFloat(max(0, min(1, trimStart / d))) * w
            let x1 = CGFloat(max(0, min(1, trimEnd / d))) * w
            ZStack(alignment: .leading) {
                // Filmstrip background (honest placeholder while thumbnails generate).
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        RoundedRectangle(cornerRadius: 8).fill(BLTheme.bg)
                            .overlay(Text("Generating preview…")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.sub))
                    } else {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, cg in
                            Image(decorative: cg, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: w / CGFloat(thumbnails.count), height: barH)
                                .clipped()
                        }
                    }
                }
                .frame(width: w, height: barH)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Dim the discarded head and tail.
                Rectangle().fill(Color.black.opacity(0.62)).frame(width: max(0, x0), height: barH)
                Rectangle().fill(Color.black.opacity(0.62)).frame(width: max(0, w - x1), height: barH).offset(x: x1)

                // Selected-range outline.
                RoundedRectangle(cornerRadius: 6).stroke(BLTheme.gold, lineWidth: 2)
                    .frame(width: max(handleW * 2, x1 - x0), height: barH)
                    .offset(x: x0)

                handle(at: x0, width: w, leading: true)
                handle(at: x1, width: w, leading: false)
            }
            .coordinateSpace(name: "clip-trim-bar")
        }
        .frame(height: barH)
    }

    private func handle(at x: CGFloat, width: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(BLTheme.gold)
            .frame(width: handleW, height: barH)
            .overlay(Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 9, weight: .black)).foregroundColor(BLTheme.inkOnGold))
            .offset(x: leading ? x : x - handleW)
            .contentShape(Rectangle())
            // The drag must be measured in the BAR's space — the handle itself is only 10 pt wide,
            // so its local coordinates would pin every drag to a sliver of the timeline.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("clip-trim-bar")).onChanged { g in
                let sec = Double(max(0, min(width, g.location.x)) / width) * duration
                if leading {
                    trimStart = min(max(0, sec), max(0, trimEnd - minLength))
                } else {
                    trimEnd = max(min(duration, sec), min(duration, trimStart + minLength))
                }
            })
    }
}

// MARK: - Reel preview player (AppKit AVPlayerView, NOT SwiftUI VideoPlayer)
// On macOS, SwiftUI's `VideoPlayer` is implemented in the _AVKit_SwiftUI overlay as a generic
// NSViewRepresentable. When the app is built against one macOS SDK and run on a newer OS, that
// generic's class-metadata superclass fails to resolve and the app aborts the instant the
// preview is built (observed live: SIGABRT in getSuperclassMetadata / _AVKit_SwiftUI on macOS
// 27 beta — the render succeeded, then setting lastRenderedURL crashed the app). A plain ObjC
// AVPlayerView has no Swift generic metadata, so the reel preview is stable across SDK/OS skew.
#if os(macOS)
private struct ReelPlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.player = AVPlayer(url: url)
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            v.player = AVPlayer(url: url)
        }
    }
}
#else
// iOS uses AVPlayerViewController (AVKit) — there is no AVPlayerView on UIKit. Same rationale:
// avoid SwiftUI VideoPlayer (the _AVKit_SwiftUI generic that SIGABRTs on SDK/OS skew).
private struct ReelPlayerView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if (vc.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            vc.player = AVPlayer(url: url)
        }
    }
}
#endif

// MARK: - Content Studio (multi-format generation in the buyer's brand voice)

struct ContentStudioScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    @State private var format: Studio.ContentFormat = .socialPost
    @State private var business = ""
    @State private var topic = ""
    @State private var city = ""
    @State private var tone: CaptionTone = .punchy
    @State private var output = ""
    @State private var variations: [String] = []          // ad-copy A/B/C variations
    @State private var lanes: [(lane: String, draft: String)] = []   // one idea → 7 lanes
    @State private var savedNote = ""
    @State private var inputError = ""
    @State private var showCampaign = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Content Studio", subtitle: "Generate social, blog, ad, email, landing, and SMS copy in your brand voice.")

                // MK-20: one segment → a full campaign (reel + landing page + email sequence) in one flow.
                Panel(title: "Build a full campaign", icon: "rectangle.3.group.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pick a lead segment and draft a matching promo reel, landing page, and 3-step email sequence in your brand voice — all in one step. Nothing sends until you review and enroll from your own mailbox.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        GoldButton(label: "Build campaign", fill: true, icon: "wand.and.stars.inverse") { showCampaign = true }
                    }
                }
                .sheet(isPresented: $showCampaign) {
                    CampaignBuilderScreen().environmentObject(model).environmentObject(prefs).sheetCloseBar()
                }

                Panel(title: "Format", icon: "square.grid.2x2.fill") {
                    LazyVGrid(columns: blGridColumns(), spacing: 10) {
                        ForEach(Studio.ContentFormat.allCases) { f in
                            Button { withAnimation(.easeOut(duration: 0.15)) { format = f } } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: f.icon).font(.system(size: 16, weight: .bold))
                                        .foregroundColor(format == f ? BLTheme.inkOnGold : BLTheme.gold)
                                        .frame(width: 38, height: 38)
                                        .background(format == f ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                    Text(f.rawValue).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(format == f ? BLTheme.text : BLTheme.sub)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(format == f ? BLTheme.gold.opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(format == f ? BLTheme.gold.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                    Text(format.hint).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }

                Panel(title: "Inputs", icon: "pencil.and.outline") {
                    VStack(spacing: 12) {
                        Field(title: "Business / operator", text: $business, prompt: "Summit Plumbing Co.")
                        Field(title: "Topic / offer", text: $topic, prompt: "Drain cleaning, spring promo…")
                        Field(title: "City (optional)", text: $city, prompt: "Austin, TX")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TONE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                            Picker("", selection: $tone) { ForEach(CaptionTone.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                        }
                        GoldButton(label: format == .adCopy ? "Generate 3 ad variations" : "Generate \(format.rawValue.lowercased())", fill: true, icon: "sparkles") {
                            withCommittedTextInput {
                                guard validateBrief() else { return }
                                savedNote = ""; inputError = ""
                                if format == .adCopy {
                                    output = ""; lanes = []
                                    variations = Studio.adVariations(business: business, topic: topic, city: city, tone: tone)
                                } else {
                                    variations = []; lanes = []
                                    output = Studio.content(format: format, business: business, topic: topic, city: city, tone: tone, hashtag: prefs.captionHashtag)
                                }
                            }
                        }
                        if !inputError.isEmpty {
                            Text(inputError).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // One idea → all 7 publishing lanes (Email, IG, TikTok, X, Facebook, LinkedIn, Threads).
                Panel(title: "Repurpose across all 7 lanes", icon: "square.on.square.dashed") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turn one idea into a tailored draft for every channel — generation is live across all seven lanes.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        GoldButton(label: "Repurpose this idea to 7 lanes", fill: true, icon: "rectangle.split.3x1.fill") {
                            withCommittedTextInput {
                                guard validateBrief() else { return }
                                savedNote = ""; inputError = ""; output = ""; variations = []
                                lanes = Studio.repurpose(idea: topic, business: business, city: city, tone: tone, hashtag: prefs.captionHashtag)
                            }
                        }
                    }
                }

                if !savedNote.isEmpty {
                    Label(savedNote, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }

                if !output.isEmpty {
                    Panel(title: "Output", icon: "doc.text.fill") {
                        outputBlock(output, formatLabel: format.rawValue, allowCaption: format == .socialPost)
                    }
                }

                if !variations.isEmpty {
                    Panel(title: "Ad variations (A/B/C)", icon: "megaphone.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(variations.enumerated()), id: \.offset) { i, v in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("VARIATION \(["A","B","C"][min(i,2)])").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.gold).tracking(0.6)
                                    outputBlock(v, formatLabel: "Ad — Variation \(["A","B","C"][min(i,2)])", allowCaption: false)
                                }
                            }
                        }
                    }
                }

                if !lanes.isEmpty {
                    Panel(title: "7-lane drafts", icon: "rectangle.split.3x1.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lanes.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.lane.uppercased()).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.gold).tracking(0.6)
                                    outputBlock(item.draft, formatLabel: "Social — \(item.lane)", allowCaption: false)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .onAppear { if business.isEmpty { business = prefs.brandName }; if city.isEmpty { city = prefs.defaultMarket }; tone = prefs.captionTone }
    }

    /// Accessibility automation and fast pointer activation can invoke a button while AppKit's
    /// field editor is still first responder. End editing synchronously so the SwiftUI bindings
    /// contain the visible text before validation or generation reads them.
    private func withCommittedTextInput(_ action: () -> Void) {
        #if os(macOS)
        _ = NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
        action()
    }

    private func validateBrief() -> Bool {
        var missing: [String] = []
        if business.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("business / operator") }
        if topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("topic / offer") }
        guard missing.isEmpty else {
            inputError = "Add \(missing.joined(separator: " and ")) before generating so the app doesn't invent the brief."
            output = ""; variations = []; lanes = []
            return false
        }
        return true
    }

    /// A generated-text block with Copy / Save-to-library (+ optional Save-to-captions) / Export.
    @ViewBuilder private func outputBlock(_ text: String, formatLabel: String, allowCaption: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            HStack {
                GoldButton(label: "Copy", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                GoldButton(label: "Save to library", icon: "tray.and.arrow.down.fill") {
                    let firstLine = text.split(separator: "\n").first.map(String.init) ?? formatLabel
                    model.addContentItem(ContentItem(format: formatLabel, topic: topic.isEmpty ? "general" : topic,
                                                     title: String(firstLine.prefix(80)), body: text))
                    if allowCaption { model.addCaption(Caption(topic: topic.isEmpty ? "general" : topic, text: text)) }
                    savedNote = "Saved to your Content Library."
                }
                GhostButton(label: "Export…", icon: "square.and.arrow.up") { exportSpecific(text, label: formatLabel) }
            }
        }
    }

    private func exportSpecific(_ text: String, label: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(label.replacingOccurrences(of: " ", with: "-").lowercased()).txt"
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Build campaign (MK-20): one segment → reel + landing page + email sequence, then enroll

/// The one-flow campaign builder: the buyer picks a real lead-DB category facet, and CampaignBuilder
/// drafts a promo reel, a landing page (XSS-safe Studio.landingPage), and a 3-step brand-voiced email
/// sequence — all from the buyer's OWN brand fields. The flow stops at review/enroll; nothing auto-sends.
struct CampaignBuilderScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @StateObject private var leadDB = LeadDBStore()

    @State private var selectedCategory = ""
    @State private var selectedCount = 0
    @State private var city = ""
    @State private var bundle: CampaignBundle?
    @State private var buildError = ""
    @State private var showEnroll = false
    @State private var rendering = false
    @State private var renderNote = ""

    private var brand: CampaignBrand { CampaignBrand(prefs: prefs, city: city) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build campaign").font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("One segment → reel + landing page + email sequence").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                IconButton(system: "xmark", tint: BLTheme.sub) { dismiss() }
            }
            .padding(18)
            Divider().background(BLTheme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    segmentPicker
                    if !buildError.isEmpty {
                        Label(buildError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let b = bundle { assets(b) }
                }
                .padding(18)
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
        .task { if leadDB.industries.isEmpty { await leadDB.loadFacets() } }
        .onAppear { if city.isEmpty { city = prefs.defaultMarket } }
        .sheet(isPresented: $showEnroll) {
            if let b = bundle { EnrollLeadsSheet(sequence: b.sequence).environmentObject(model).sheetCloseBar() }
        }
    }

    // MARK: pick a real lead-DB industry facet (count is the REAL facet size, never estimated)

    private var segmentPicker: some View {
        Panel(title: "1 · Pick a lead segment", icon: "person.3.sequence.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if leadDB.industries.isEmpty {
                    Text("Loading segments from the lead catalog…")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    Menu {
                        ForEach(leadDB.industries, id: \.0) { (industry, n) in
                            Button("\(taxonomyLabel(industry))  ·  \(n.formatted())") { selectedCategory = industry; selectedCount = n }
                        }
                    } label: {
                        HStack {
                            Text(selectedCategory.isEmpty ? "Choose an industry" : taxonomyLabel(selectedCategory))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(selectedCategory.isEmpty ? BLTheme.sub : BLTheme.text)
                            Spacer()
                            if selectedCount > 0 {
                                Text("\(selectedCount.formatted()) leads").font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.gold)
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
                        }
                        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Field(title: "City (optional)", text: $city, prompt: "Austin, TX")
                GoldButton(label: "Build campaign for \(selectedCategory.isEmpty ? "this segment" : selectedCategory)", fill: true, icon: "wand.and.stars.inverse") {
                    buildCampaign()
                }
            }
        }
    }

    private func buildCampaign() {
        buildError = ""; renderNote = ""
        do {
            bundle = try CampaignBuilder.buildLive(facet: selectedCategory, matchCount: selectedCount, brand: brand)
        } catch {
            bundle = nil
            buildError = error.localizedDescription
        }
    }

    // MARK: the three drafted assets

    @ViewBuilder private func assets(_ b: CampaignBundle) -> some View {
        // (a) Reel storyboard — a real, renderable ReelProject; render to an .mp4 on the buyer's disk.
        Panel(title: "2 · Promo reel", icon: "film.stack.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(b.reel.name).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                ForEach(Array(b.reel.headlines.enumerated()), id: \.offset) { i, h in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 16)
                        Text(h).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                HStack {
                    GoldButton(label: rendering ? "Rendering…" : "Render reel .mp4…", icon: "square.and.arrow.down") { renderReel(b) }
                        .disabled(rendering).opacity(rendering ? 0.5 : 1)
                    if !renderNote.isEmpty {
                        Text(renderNote).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // (b) Landing page — the buyer's own site; export the HTML.
        Panel(title: "3 · Landing page", icon: "globe") {
            VStack(alignment: .leading, spacing: 8) {
                HTMLPreview(html: b.siteHTML).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                GhostButton(label: "Export site .html…", icon: "square.and.arrow.up") { exportSite(b) }
            }
        }
        // (c) Email sequence — brand-voiced 3-step cadence; enroll leads to send from the buyer's mailbox.
        Panel(title: "4 · Email sequence", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(b.sequence.steps.enumerated()), id: \.offset) { i, step in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("STEP \(i + 1) · \(step.delayDays == 0 ? "on enroll" : "+\(step.delayDays)d")")
                            .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.gold).tracking(0.6)
                        Text(step.subject).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text(step.body).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                GoldButton(label: "Enroll leads →", fill: true, icon: "paperplane.fill") {
                    model.upsertSequence(b.sequence)   // save the drafted cadence to the buyer's Sequences
                    showEnroll = true
                }
            }
        }
    }

    private func renderReel(_ b: CampaignBundle) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(b.category.replacingOccurrences(of: " ", with: "-").lowercased())-promo.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = CampaignBuilder.reelProject(from: b.reel, brand: brand)
        rendering = true; renderNote = ""
        Task.detached {
            var ok = false; var msg = ""
            do { try ReelRenderer.render(project: project, to: url); ok = true; msg = "Rendered: \(url.lastPathComponent)" }
            catch { msg = "Render failed: \(error.localizedDescription)" }
            await MainActor.run { rendering = false; renderNote = ok ? msg : ""; if !ok { buildError = msg } }
        }
    }

    private func exportSite(_ b: CampaignBundle) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(b.category.replacingOccurrences(of: " ", with: "-").lowercased())-landing.html"
        if panel.runModal() == .OK, let url = panel.url { try? b.siteHTML.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Content Library (every saved generated draft, all formats, persists)

struct ContentLibraryScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    private var items: [ContentItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.contentLibrary }
        return model.contentLibrary.filter { ($0.title + $0.body + $0.format + $0.topic).lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Content Library", subtitle: "Every draft you generate — social, blog, ad, email, landing, SMS, and per-lane — saved in one place so the next builds on the last.")
                if model.contentLibrary.isEmpty {
                    EmptyState(icon: "tray.full.fill", title: "Nothing saved yet",
                               hint: "Generate copy in Content Studio and \(AppBrand.tapVerb) “Save to library”. Everything you keep shows up here.")
                } else {
                    Panel(title: "Saved (\(model.contentLibrary.count))", icon: "tray.full.fill") {
                        VStack(spacing: 10) {
                            Field(title: "Search", text: $query, prompt: "Filter by text, format, or topic")
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.format.isEmpty ? "Content" : item.format)
                                            .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(BLTheme.goldGrad).clipShape(Capsule())
                                        Spacer()
                                        IconButton(system: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.body, forType: .string) }
                                        ConfirmDeleteButton(title: "Delete this saved draft?",
                                                            message: "It will be removed from your library. This cannot be undone.") {
                                            model.deleteContentItem(item)
                                        }
                                    }
                                    Text(item.title.isEmpty ? item.body : item.title)
                                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(2)
                                    Text(item.body).font(.system(size: 11.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                                        .lineLimit(4).textSelection(.enabled)
                                }
                                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Leads (CRM): captured leads + manual add + CSV export

struct LeadsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var campaign = ""
    @State private var note = ""
    @State private var toast = ""
    @State private var query = ""
    @State private var shown = LeadsScreen.pageSize
    @State private var enriching = false
    @State private var enrichNote = ""
    @State private var selectedLead: Lead?

    /// Max leads processed per "Find missing emails" run — bounds calls against the buyer's own
    /// provider quota so one click can't drain their API credits.
    static let enrichBatch = 50

    /// Rows rendered per "Show more" step. The CRM pool can hold tens of thousands of imported
    /// leads; rendering them ALL in one non-lazy ForEach froze the whole machine (2026-07-07,
    /// 10,001 rows). The list is search-first and renders a bounded window, never the full pool.
    static let pageSize = 50
    static let pageStep = 200

    private var filtered: [Lead] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.leads }
        return model.leads.filter {
            $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q)
                || $0.sourceCampaign.lowercased().contains(q) || $0.phone.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Leads (CRM)", subtitle: "Capture and track leads from your landing pages and campaigns.")

                Panel(title: "Add a lead", icon: "person.crop.circle.badge.plus") {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Field(title: "Name", text: $name, prompt: "Jordan Lee")
                            Field(title: "Email", text: $email, prompt: "jordan@example.com")
                        }
                        HStack(spacing: 12) {
                            Field(title: "Phone (optional)", text: $phone, prompt: "(512) 555-0142")
                            Field(title: "Campaign / source", text: $campaign, prompt: "spring_sale")
                        }
                        Field(title: "Note (optional)", text: $note, prompt: "Asked about pricing")
                        GoldButton(label: "Add lead", fill: true, icon: "plus") { add() }
                        if !toast.isEmpty { Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green) }
                    }
                }

                enrichmentPanel

                if model.leads.isEmpty {
                    Panel(title: "Your leads", icon: "person.2") {
                        EmptyState(icon: "person.crop.circle.badge.questionmark", title: "No leads yet",
                                   hint: "Add leads manually, or generate a landing page with a lead-capture form in Site Studio and record the responses you receive here.")
                    }
                } else {
                    Panel(title: "Leads (\(model.leads.count))", icon: "person.2.fill") {
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                Field(title: "Search", text: $query, prompt: "Name, email, campaign, phone…")
                                Spacer()
                                GhostButton(label: "Export CSV", icon: "square.and.arrow.up") { exportCSV() }
                            }
                            if filtered.isEmpty {
                                EmptyState(icon: "magnifyingglass", title: "No leads match \"\(query)\"",
                                           hint: "Try a different name, email, campaign, or phone fragment.")
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(filtered.prefix(shown)) { l in leadRow(l) }
                                }
                                if filtered.count > shown {
                                    Button {
                                        shown += LeadsScreen.pageStep
                                    } label: {
                                        Text("Show more  (\(min(shown, filtered.count)) of \(filtered.count))")
                                            .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    }.buttonStyle(.plain)
                                } else if filtered.count > LeadsScreen.pageSize {
                                    Text("All \(filtered.count) shown")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $selectedLead) { lead in
            LeadDetailSheet(lead: lead)
        }
        .onAppear {
            #if os(iOS)
            if DemoMode.active, DemoProofSurface.current == .crmDetail, selectedLead == nil {
                selectedLead = model.leads.first
            }
            #endif
        }
        .onChange(of: query) { _ in shown = LeadsScreen.pageSize }   // new search restarts the window
    }

    @ViewBuilder private func leadRow(_ l: Lead) -> some View {
        let display = LeadEmailDisplay.resolve(email: l.email, guessedEmail: l.guessedEmail, guessedPattern: l.guessedEmailPattern)
        HStack(spacing: 12) {
            Image(systemName: "person.fill").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(l.name.isEmpty ? "(no name)" : l.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                emailLine(display, extra: [l.phone, l.sourceCampaign])
                if !l.message.isEmpty { Text(l.message).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).italic().lineLimit(2) }
            }
            Spacer()
            IconButton(system: "info.circle", accessibilityText: "Open lead details") { selectedLead = l }
                .accessibilityIdentifier("lead.detail.\(l.id.uuidString)")
            leadRowActions(l, display: display)
            ConfirmDeleteButton(title: "Delete this lead?",
                                message: "\(l.name.isEmpty ? "This lead" : l.name) will be removed from your CRM. This cannot be undone.") {
                model.deleteLead(l)
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    /// The address line. A CONFIRMED email shows plainly; a GUESS shows the address followed by a
    /// muted "Guessed · unverified" pill — never the green/verified tone, so the two can't be confused.
    @ViewBuilder private func emailLine(_ display: LeadEmailDisplay, extra: [String]) -> some View {
        let tail = extra.filter { !$0.isEmpty }.joined(separator: " · ")
        switch display {
        case .none:
            if !tail.isEmpty { Text(tail).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1) }
        case .confirmed(let addr):
            Text([addr, tail].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
        case .guessed(let addr, _):
            HStack(spacing: 6) {
                Text(addr).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                // Honest guess pill — muted grey, question-mark glyph. NEVER BLTheme.green.
                Label(display.badge ?? "Guessed · unverified", systemImage: display.icon)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(BLTheme.panelHi).clipShape(Capsule())
                    .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                if !tail.isEmpty { Text("· \(tail)").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1) }
            }
        }
    }

    /// Per-lead actions. A confirmed email gets the mail button; a lead with a name+domain but no
    /// email gets an opt-in "Guess email" action; a lead already carrying a guess gets a clear button
    /// (and a mail button that's honest about mailing an unverified guess).
    @ViewBuilder private func leadRowActions(_ l: Lead, display: LeadEmailDisplay) -> some View {
        switch display {
        case .confirmed(let addr):
            IconButton(system: "envelope") {
                if let url = Studio.mailtoURL(to: addr, subject: "Following up", body: "Hi \(l.name),\n\n") {
                    DemoMode.openExternal(url, simulatedNote: "Demo: this would open your mail app to follow up with \(l.name).")
                }
            }
        case .guessed(let addr, _):
            IconButton(system: "envelope.badge") {
                if let url = Studio.mailtoURL(to: addr, subject: "Following up", body: "Hi \(l.name),\n\n") {
                    DemoMode.openExternal(url, simulatedNote: "Demo: this would open your mail app to the GUESSED (unverified) address for \(l.name).")
                }
            }
            IconButton(system: "xmark.circle") { model.clearGuess(for: l.id) }
        case .none:
            if EmailGuessEngine.canGuess(email: l.email, name: l.name, domain: l.domain) {
                IconButton(system: "questionmark.circle") { model.guessEmail(for: l.id) }
            }
        }
    }

    // MARK: - Find missing emails (BYO enrichment provider — on-device, local-only)

    /// Leads with a company domain but no email — the only ones a name→email finder can help.
    private var missingEmailLeads: [Lead] { model.leads.filter { $0.email.isEmpty && !$0.domain.isEmpty } }

    @ViewBuilder private var enrichmentPanel: some View {
        let vendor = leadEngine.settings.enrichment.provider.finderVendor
        let ready = leadEngine.settings.enrichment.providerReady && vendor != nil
        let chain = leadEngine.settings.enrichment.enrichmentChain
        let chainReady = chain.contains { EnrichmentKeychain.hasKey($0) }
        let count = missingEmailLeads.count
        Panel(title: "Find missing emails", icon: "sparkle.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                if chainReady {
                    Text("\(count) lead\(count == 1 ? "" : "s") missing an email. Run your waterfall — \(chain.map { $0.label }.joined(separator: " → ")) — trying each provider in order until the first confirmed hit. Every result caches on the lead, so re-running is instant and free.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    GoldButton(label: enriching ? "Running waterfall…" : (count == 0 ? "Nothing to find" : "Run waterfall (\(min(count, LeadsScreen.enrichBatch)))"),
                               fill: true, icon: "arrow.triangle.branch") {
                        if !enriching && count > 0 { findMissingEmailsWaterfall(chain: chain) }
                    }
                    .disabled(enriching || count == 0)
                } else if ready {
                    Text("\(count) lead\(count == 1 ? "" : "s") \(count == 1 ? "has" : "have") a company domain but no email. Look them up through your own \(vendor!.label) account — results attach to each lead here and never leave your \(PlatformWords.device).")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    GoldButton(label: enriching ? "Searching…" : (count == 0 ? "Nothing to find" : "Find missing emails (\(min(count, LeadsScreen.enrichBatch)))"),
                               fill: true, icon: "magnifyingglass") {
                        if !enriching && count > 0 { findMissingEmails(vendor: vendor!) }
                    }
                    .disabled(enriching || count == 0)
                } else {
                    Text("Connect your own Hunter or Apollo API key in Connectors → Enrichment to find work emails for leads that are missing one. Nothing is ever fabricated — a lookup that finds no email leaves the lead unchanged.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                if !enrichNote.isEmpty {
                    Text(enrichNote).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(enrichNote.contains("failed") || enrichNote.contains("Connect") ? BLTheme.gold : BLTheme.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Run the buyer's OWN enrichment provider over up to `enrichBatch` leads missing an email.
    /// Each hit fills the blank email LOCALLY + logs an `.enriched` activity; a no-match leaves the
    /// lead untouched (never fabricated); a provider error is surfaced honestly with its reason.
    private func findMissingEmails(vendor: EnrichmentVendor) {
        guard let key = EnrichmentKeychain.get(vendor) else {
            enrichNote = "Your \(vendor.label) key isn't saved — reconnect it in Connectors → Enrichment."; return
        }
        let targets = Array(missingEmailLeads.prefix(LeadsScreen.enrichBatch))
        let remainder = max(0, missingEmailLeads.count - targets.count)
        enriching = true; enrichNote = ""
        Task {
            var found = 0, noMatch = 0, failed = 0, lastErr = ""
            for lead in targets {
                let query = lead.name.isEmpty ? lead.company : lead.name
                do {
                    let result = try await EnrichmentProviderClient.find(name: query, domain: lead.domain, vendor: vendor, apiKey: key)
                    await MainActor.run {
                        if let i = model.leads.firstIndex(where: { $0.id == lead.id }) {
                            let (updated, filled) = EnrichmentProviderClient.attach(result, to: model.leads[i])
                            if filled {
                                model.leads[i] = updated
                                model.log(lead.id, .enriched, EnrichmentProviderClient.provenanceNote(result))
                                found += 1
                            } else { noMatch += 1 }
                        }
                    }
                } catch EnrichmentProviderError.noMatch {
                    noMatch += 1
                } catch {
                    failed += 1
                    lastErr = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
            await MainActor.run {
                enriching = false
                var parts = ["\(found) found"]
                if noMatch > 0 { parts.append("\(noMatch) no match") }
                if failed > 0 { parts.append("\(failed) failed — \(lastErr)") }
                if remainder > 0 { parts.append("\(remainder) more left for the next run") }
                enrichNote = parts.joined(separator: " · ")
            }
        }
    }

    /// MK-17 — run the buyer's ORDERED provider waterfall over up to `enrichBatch` leads missing an
    /// email. Each lead's chain runs until the first confirmed hit (then stops), the outcome caches on
    /// the lead (instant + free re-runs), and a hit fills the CONFIRMED email lane. Honest counts only.
    private func findMissingEmailsWaterfall(chain: [EnrichmentVendor]) {
        let targets = Array(missingEmailLeads.prefix(LeadsScreen.enrichBatch))
        let remainder = max(0, missingEmailLeads.count - targets.count)
        enriching = true; enrichNote = ""
        Task {
            var found = 0, noMatch = 0, cached = 0
            for lead in targets {
                let r = await model.enrichWaterfall(for: lead.id, chain: chain)
                if r.fromCache { cached += 1 }
                if r.isHit { found += 1 } else { noMatch += 1 }
            }
            await MainActor.run {
                enriching = false
                var parts = ["\(found) found"]
                if noMatch > 0 { parts.append("\(noMatch) no match") }
                if cached > 0 { parts.append("\(cached) from cache (instant, free)") }
                if remainder > 0 { parts.append("\(remainder) more left for the next run") }
                enrichNote = parts.joined(separator: " · ")
            }
        }
    }

    private func add() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty || !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            toast = "Add at least a name or email."; return
        }
        model.addLead(Lead(legacy: CapturedLead(name: name, email: email, phone: phone, message: note, sourceCampaign: campaign)))
        name = ""; email = ""; phone = ""; campaign = ""; note = ""
        toast = "Lead added."
    }

    private func exportCSV() {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Name,Email,Phone,Campaign,Note,Created\n"
        for l in model.leads {
            csv += [cell(l.name), cell(l.email), cell(l.phone), cell(l.sourceCampaign), cell(l.message),
                    cell(l.created.formatted(date: .numeric, time: .shortened))].joined(separator: ",") + "\n"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "leads.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                model.logSecurity("export", "\(model.leads.count) leads → \(url.lastPathComponent)")
                toast = "Exported \(model.leads.count) leads to \(url.lastPathComponent)."
            } catch {
                toast = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

/// A real, reachable detail surface for the unified lead record. It shows only values stored on the
/// buyer's lead; absent fields stay explicitly blank instead of being inferred or fabricated.
struct LeadDetailSheet: View {
    let lead: Lead
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(BLTheme.goldGrad).frame(width: 44, height: 44)
                    Image(systemName: "person.fill").font(.system(size: 18, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(lead.displayName)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundColor(BLTheme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    HStack(spacing: 7) {
                        StatusPill(text: lead.status.label, tint: lead.status.tint)
                        if DemoMode.active { StatusPill(text: "SAMPLE", tint: BLTheme.gold) }
                    }
                    Text("Lead detail · \(lead.source.label)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        .accessibilityIdentifier("demo.proof.crm.detail")
                }
                Spacer(minLength: 8)
                IconButton(system: "xmark", accessibilityText: "Close lead details", targetSize: 44) { dismiss() }
                    .accessibilityIdentifier("demo.proof.crm.close")
            }
            .padding(20)
            Divider().overlay(BLTheme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Panel(title: "Contact", icon: "person.text.rectangle") {
                        detailLine("Email", lead.email, empty: "No confirmed email")
                        detailLine("Phone", lead.phone, empty: "No phone")
                        detailLine("Company", lead.company, empty: "No company")
                        detailLine("Domain", lead.domain, empty: "No domain")
                        detailLine("Address", lead.address, empty: "No address")
                    }

                    Panel(title: "Acquisition", icon: "scope") {
                        detailLine("Source", lead.source.label)
                        detailLine("Campaign", lead.sourceCampaign, empty: "No campaign recorded")
                        detailLine("Industry", lead.industry.isEmpty ? lead.type.label : lead.industry, empty: "No industry")
                        detailLine("Added", lead.created.formatted(date: .abbreviated, time: .shortened))
                    }

                    Panel(title: "Context", icon: "text.bubble.fill") {
                        detailLine("Message", lead.message, empty: "No form message")
                        detailLine("Notes", lead.notes, empty: "No notes")
                        if lead.tags.isEmpty {
                            detailLine("Tags", "", empty: "No tags")
                        } else {
                            HStack(spacing: 6) {
                                Text("TAGS").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).frame(width: 74, alignment: .leading)
                                ForEach(lead.tags, id: \.self) { tag in
                                    Text(tag).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                                        .padding(.vertical, 3).padding(.horizontal, 7).background(BLTheme.gold.opacity(0.12)).clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 520, idealHeight: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
        .background(BLTheme.bg)
    }

    @ViewBuilder private func detailLine(_ label: String, _ value: String, empty: String = "") -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.uppercased())
                .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                .frame(width: 74, alignment: .leading)
            Text(value.isEmpty ? empty : value)
                .font(.system(size: 12.5, weight: value.isEmpty ? .medium : .semibold, design: .rounded))
                .foregroundColor(value.isEmpty ? BLTheme.sub : BLTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Global search (⌘K)

struct GlobalSearchView: View {
    var go: (Section) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Hit: Identifiable { let id = UUID(); let title: String; let subtitle: String; let icon: String; let dest: Section; var triage: [TriageTag] = [] }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return navHits }
        var out: [Hit] = []
        out += navHits.filter { $0.title.lowercased().contains(q) }
        for r in model.reels where r.name.lowercased().contains(q) { out.append(Hit(title: r.name.isEmpty ? "Untitled reel" : r.name, subtitle: "Reel project", icon: "film.fill", dest: .reels)) }
        for s in model.sites where (s.name + s.businessType + s.city).lowercased().contains(q) { out.append(Hit(title: s.name.isEmpty ? "Untitled site" : s.name, subtitle: "Site project", icon: "globe", dest: .studio)) }
        for c in model.clientLeads where (c.company + c.name + c.industry + c.domain).lowercased().contains(q) { out.append(Hit(title: c.company.isEmpty ? c.name : c.company, subtitle: "Saved client", icon: "building.2.fill", dest: .leadsHub)) }
        // MK-23 fused ⌘K: the whole lead DB AND the mailbox in one sub-second local search, each hit
        // carrying an on-device REPLY/BOUNCE triage tag derived from the real activity log + inbox
        // classification (no fabricated confidence). Leads route to the CRM, messages to the Inbox.
        let fused = CommandBar.search(query, in: .init(leads: model.leads, inbox: model.inbox, activities: model.activities), limit: 24)
        for h in fused {
            out.append(Hit(title: h.title.isEmpty ? "(untitled)" : h.title,
                           subtitle: h.subtitle,
                           icon: h.kind == .message ? "envelope" : "person.fill",
                           dest: h.kind == .message ? .inbox : .leadsHub,
                           triage: h.tags))
        }
        for cap in model.captions where (cap.topic + cap.text).lowercased().contains(q) { out.append(Hit(title: cap.topic, subtitle: "Caption", icon: "text.quote", dest: .ideation)) }
        for lk in model.links where (lk.label + lk.campaign + lk.url).lowercased().contains(q) { out.append(Hit(title: lk.label.isEmpty ? lk.campaign : lk.label, subtitle: "Campaign link", icon: "link", dest: .dashboard)) }
        for sg in model.segments where sg.name.lowercased().contains(q) { out.append(Hit(title: sg.name.isEmpty ? "Untitled segment" : sg.name, subtitle: "Audience segment", icon: "person.3.sequence.fill", dest: .growHub)) }
        for cm in model.campaigns where (cm.name + cm.subject).lowercased().contains(q) { out.append(Hit(title: cm.name.isEmpty ? cm.subject : cm.name, subtitle: "Email campaign", icon: "envelope.badge.fill", dest: .outreach)) }
        for a in model.audits where (a.url + a.title).lowercased().contains(q) { out.append(Hit(title: a.url, subtitle: "Brand audit · \(a.score)/100", icon: "checkmark.shield.fill", dest: .growHub)) }
        return Array(out.prefix(40))
    }

    /// A small honest triage chip (Replied / Bounced / Sent) — tinted from the tag, no confidence number.
    @ViewBuilder private func triageChip(_ tag: TriageTag) -> some View {
        let tint: Color = tag == .replied ? BLTheme.green : (tag == .bounced ? BLTheme.red : .blue)
        HStack(spacing: 3) {
            Image(systemName: tag.systemImage).font(.system(size: 8, weight: .bold))
            Text(tag.label).font(BLFonts.mono(8.5, weight: .bold))
        }
        .foregroundColor(tint)
        .padding(.vertical, 2).padding(.horizontal, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }
    private var navHits: [Hit] {
        Section.sidebarSections.map { Hit(title: $0.rawValue, subtitle: "Go to \($0.group)", icon: $0.icon, dest: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(BLTheme.gold)
                TextField("Search leads, mailbox, reels, sites, campaigns — with reply/bounce triage…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                    .focused($focused).onSubmit { if let f = hits.first { go(f.dest) } }
                // The 'esc' chip is now a real button bound to Escape — previously it was a decorative
                // label, so opening search and not picking a result left no way to close the overlay.
                // Touch has no Escape key: iOS renders a standard ✕ close button at a 44pt target.
                #if os(macOS)
                Button { dismiss() } label: {
                    Text("esc").font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub)
                        .padding(.vertical, 3).padding(.horizontal, 7)
                        .background(BLTheme.bg2, in: Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain).help("Close search (Esc)").keyboardShortcut(.cancelAction)
                #else
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold)).foregroundColor(BLTheme.sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
                .keyboardShortcut(.cancelAction)
                #endif
            }
            .padding(14)
            Rectangle().fill(BLTheme.stroke).frame(height: 1)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(hits) { h in
                        Button { go(h.dest) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: h.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(h.subtitle).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                }
                                Spacer()
                                ForEach(h.triage, id: \.self) { triageChip($0) }
                                Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.5))
                            }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if hits.isEmpty {
                        Text("No matches").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).padding(20)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 380)
        }
        #if os(macOS)
        .frame(width: 540)
        #else
        .frame(maxWidth: .infinity)   // iPhone: fill the sheet width (540 would overflow a 390pt phone)
        #endif
        .background(BLTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
        .onAppear { focused = true }
        .onExitCommand { dismiss() }   // Esc closes even while the search field holds focus
    }
}
#endif // circuit-convert
