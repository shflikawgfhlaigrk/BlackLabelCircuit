// Black Label Marketing — Reel Relay transport + dispatcher.
//
// The novel cross-platform publish core: a rendered .mp4 leaves the Mac, arrives on the buyer's
// OWN iPhone (over Apple Handoff continuation streams, AirDrop as the reliable fallback), and ONE
// dispatcher drops it into each network's native composer under the account the buyer is already
// signed into. No OAuth redirect, no public URL, no per-buyer dev app, no posting-API review,
// nothing server-side. Pure rail-selection lives in Social.swift (ReelRelay) and is unit-tested;
// this file is the platform glue, split by #if so it compiles in BOTH the macOS and iOS targets.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if os(iOS)
import UIKit
import Photos
#if canImport(TikTokOpenShareSDK)
import TikTokOpenShareSDK   // present only after the app-level TikTok OpenSDK dep + client_key are added
#endif
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - macOS: advertise the reel over Handoff + vend its bytes over the continuation stream
#if os(macOS)

/// Builds the publish NSUserActivity and vends the rendered .mp4 to the iPhone when it opens the
/// continuation streams. Hold a strong reference (the activity's delegate is unowned).
final class ReelRelaySender: NSObject, NSUserActivityDelegate {
    static let shared = ReelRelaySender()
    private var fileURL: URL?
    private(set) var activity: NSUserActivity?

    /// Make the activity current so it surfaces on the buyer's own iPhone (same Apple ID, same-Team app).
    func advertise(fileURL: URL, platform: SocialPlatform, placement: PublishPlacement, caption: String, reelID: String) {
        self.fileURL = fileURL
        let a = NSUserActivity(activityType: ReelRelay.activityType)
        a.title = "Publish reel to \(platform.rawValue)"
        a.isEligibleForHandoff = true
        a.supportsContinuationStreams = true
        a.userInfo = ReelRelay.activityUserInfo(platform: platform, placement: placement, caption: caption, reelID: reelID)
        a.delegate = self
        a.becomeCurrent()
        self.activity = a
    }

    func invalidate() { activity?.invalidate(); activity = nil; fileURL = nil }

    // The iPhone opened the continuation streams — stream the .mp4 bytes device-to-device.
    func userActivity(_ userActivity: NSUserActivity, didReceive inputStream: InputStream, outputStream: OutputStream) {
        guard let url = fileURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            outputStream.open(); defer { outputStream.close() }
            guard let data = try? Data(contentsOf: url) else { return }
            data.withUnsafeBytes { raw in
                var p = raw.bindMemory(to: UInt8.self).baseAddress!
                var remaining = data.count
                while remaining > 0 {
                    let n = outputStream.write(p, maxLength: remaining)
                    if n <= 0 { break }
                    p += n; remaining -= n
                }
            }
        }
    }

    /// Reliable fallback: AirDrop the .mp4 to the buyer's own iPhone (then it opens in this app).
    @discardableResult
    func airdrop(fileURL: URL) -> Bool {
        guard let svc = NSSharingService(named: .sendViaAirDrop) else { return false }
        svc.perform(withItems: [fileURL]); return true
    }
}
#endif

// MARK: - iOS: receive the reel, stage it, dispatch to the native rail
#if os(iOS)

struct PendingPublish: Identifiable {
    let id = UUID()
    var videoURL: URL
    var platform: SocialPlatform?
    var placement: PublishPlacement?
    var caption: String
}

/// App-level inbox. main.swift feeds it from .onContinueUserActivity (Handoff) and .onOpenURL (AirDrop).
final class ReelRelayInbox: ObservableObject {
    @Published var pending: PendingPublish?

    /// Handoff: pull the .mp4 over the continuation stream, then surface the publish sheet.
    func ingest(continue activity: NSUserActivity) {
        guard activity.activityType == ReelRelay.activityType else { return }
        let parsed = ReelRelay.parse(activity.userInfo ?? [:])
        activity.getContinuationStreams { [weak self] input, output, _ in
            guard let input = input else { return }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-\(UUID().uuidString).mp4")
            ReelRelayInbox.drain(input, to: dst)
            DispatchQueue.main.async {
                self?.pending = PendingPublish(videoURL: dst, platform: parsed?.platform,
                                               placement: parsed?.placement, caption: parsed?.caption ?? "")
            }
        }
    }

    /// AirDrop / share-sheet: a raw .mp4 file opened in the app (no platform metadata → buyer picks).
    func ingest(fileURL url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: url, to: dst)
        pending = PendingPublish(videoURL: dst, platform: nil, placement: nil, caption: "")
    }

    private static func drain(_ input: InputStream, to url: URL) {
        input.open(); defer { input.close() }
        guard let out = OutputStream(url: url, append: false) else { return }
        out.open(); defer { out.close() }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            var off = 0
            while off < n { let w = out.write(&buf[off], maxLength: n - off); if w <= 0 { break }; off += w }
        }
    }
}

/// The 7-network dispatcher. Each branch ends in the buyer tapping Post inside the official app
/// (on their own session) — which is what keeps every rail ToS-clean.
enum ReelRelayDispatcher {
    /// Black Label's own Facebook App ID — used only as `source_application` for Instagram Stories
    /// sharing (client-side, no App Review). Set once at the brand level.
    static var instagramSourceAppID: String {
        (Bundle.main.object(forInfoDictionaryKey: "InstagramSourceAppID") as? String) ?? ""
    }

    static func post(_ item: PendingPublish, platform: SocialPlatform) {
        let placement = item.placement ?? ReelRelay.defaultPlacement(for: platform)
        let rail = ReelRelay.rail(for: platform, placement: placement)
        // Always put the caption on the clipboard — honest: most rails can't pre-fill it.
        if !item.caption.isEmpty { UIPasteboard.general.string = item.caption }
        switch rail {
        case .instagramStories: shareInstagramStory(item.videoURL)
        case .instagramFeed:    shareSheet(item.videoURL, caption: item.caption)   // exclusivegram has no reliable prefill; sheet → IG
        case .tiktokOpenSDK:    shareTikTok(item.videoURL, caption: item.caption)
        case .shareSheet:       shareSheet(item.videoURL, caption: item.caption)
        }
    }

    private static func shareInstagramStory(_ videoURL: URL) {
        guard let scheme = URL(string: "instagram-stories://share?source_application=\(instagramSourceAppID)"),
              UIApplication.shared.canOpenURL(scheme),
              let data = try? Data(contentsOf: videoURL) else { shareSheet(videoURL, caption: ""); return }
        let items: [[String: Any]] = [["com.instagram.sharedSticker.backgroundVideo": data]]
        UIPasteboard.general.setItems(items, options: [.expirationDate: Date().addingTimeInterval(60 * 5)])
        UIApplication.shared.open(scheme)
    }

    private static func shareTikTok(_ videoURL: URL, caption: String) {
        #if canImport(TikTokOpenShareSDK)
        stageToPhotos(videoURL) { localID in
            guard let localID = localID else { shareSheet(videoURL, caption: caption); return }
            let req = TikTokShareRequest(localIdentifiers: [localID], mediaType: .video,
                                         redirectURI: "com.blacklabel.marketing://tiktok")
            req.send(nil)
        }
        #else
        // Until the app-level TikTok OpenSDK dep + client_key are added, fall back to the native
        // share sheet (TikTok's own Share Extension). Works today, zero key, one extra tap.
        shareSheet(videoURL, caption: caption)
        #endif
    }

    private static func shareSheet(_ videoURL: URL, caption: String) {
        var items: [Any] = [videoURL]
        if !caption.isEmpty { items.append(caption) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let top = topViewController() else { return }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }

    /// Save the .mp4 into the user's own Photos library and return its localIdentifier (the handle
    /// the TikTok OpenSDK needs). Requires NSPhotoLibraryAddUsageDescription.
    static func stageToPhotos(_ url: URL, completion: @escaping (String?) -> Void) {
        var localID: String?
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
            localID = req.placeholderForCreatedAsset?.localIdentifier
        }, completionHandler: { ok, _ in
            DispatchQueue.main.async { completion(ok ? localID : nil) }
        })
    }

    static func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        if let nav = root as? UINavigationController { return topViewController(nav.visibleViewController) }
        if let tab = root as? UITabBarController { return topViewController(tab.selectedViewController) }
        if let presented = root?.presentedViewController { return topViewController(presented) }
        return root
    }
}

/// The publish sheet the iOS app shows when a reel arrives. Pre-selects the platform/caption from
/// Handoff; for an AirDropped file the buyer picks the network. One tap → native composer.
struct ReelRelayPublishSheet: View {
    let item: PendingPublish
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var platform: SocialPlatform
    @State private var caption: String

    init(item: PendingPublish, onDone: @escaping () -> Void) {
        self.item = item; self.onDone = onDone
        _platform = State(initialValue: item.platform ?? .instagram)
        _caption = State(initialValue: item.caption)
    }

    private var currentRail: ShareRail {
        ReelRelay.rail(for: platform, placement: item.placement ?? ReelRelay.defaultPlacement(for: platform))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish reel").font(.title2.weight(.bold))

            Text("NETWORK").font(.caption).foregroundColor(.secondary)
            Picker("Post to", selection: $platform) {
                ForEach(SocialPlatform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            Text("CAPTION").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $caption)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            if !ReelRelay.captionPrefills(currentRail) {
                Text("Caption will be copied to your clipboard — paste it in the composer.")
                    .font(.footnote).foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                var enriched = item; enriched.caption = caption
                ReelRelayDispatcher.post(enriched, platform: platform)
                onDone(); dismiss()
            } label: {
                Label("Open \(platform.rawValue) composer", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") { onDone(); dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}
#endif
