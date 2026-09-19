#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — homepage capture and focused virtual-set editing controls.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if os(macOS)
import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

enum MarketingWebsitePage: String, CaseIterable, Identifiable {
    case home = "Home"
    case products = "Products"
    case custom = "Custom URL"

    var id: String { rawValue }

    func resolvedURL(from rawValue: String) -> URL? {
        let clean = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = clean.contains("://") ? clean : "https://\(clean)"
        guard var components = URLComponents(string: normalized),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        switch self {
        case .home:
            components.path = "/"
            components.query = nil
            components.fragment = nil
        case .products:
            components.path = "/products"
            components.query = nil
            components.fragment = nil
        case .custom:
            break
        }
        return components.url
    }
}

@MainActor
final class MarketingWebsiteSnapshotter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var scrollPosition: Double = 0
    private var viewport = CGSize(width: 1440, height: 900)

    /// Desktop-class viewport width. Responsive sites lay out the way the buyer designed them at
    /// this width, so only the height moves to match the reel.
    nonisolated static let captureWidth: CGFloat = 1440

    /// The page must be captured at the REEL's aspect ratio. Capturing a fixed 1440x900 desktop
    /// viewport and letting the renderer fill-crop it to the canvas is what silently discarded
    /// ~37% of the page width on a square reel and ~65% on a vertical one. Width stays at desktop
    /// class; the height follows the canvas so the plate composes to frame with nothing cropped
    /// and nothing letterboxed.
    nonisolated static func captureViewport(for canvas: CGSize) -> CGSize {
        let aspect = max(0.05, canvas.width / max(1, canvas.height))
        let height = (captureWidth / aspect).rounded()
        return CGSize(width: captureWidth, height: min(max(height, 480), 4320))
    }

    func snapshot(url: URL, scrollPosition: Double, viewport: CGSize) async throws -> CGImage {
        guard continuation == nil else {
            throw NSError(domain: "BlackLabelMarketing.VirtualSet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A homepage capture is already running."])
        }
        self.scrollPosition = min(1, max(0, scrollPosition))
        let size = CGSize(width: max(320, viewport.width.rounded()), height: max(320, viewport.height.rounded()))
        self.viewport = size
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
            view.navigationDelegate = self; webView = view
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let fraction = scrollPosition
        let script = "window.scrollTo(0, Math.max(0, (document.documentElement.scrollHeight-window.innerHeight)*\(fraction)));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let config = WKSnapshotConfiguration()
                config.rect = webView.bounds
                config.snapshotWidth = NSNumber(value: Double(self?.viewport.width ?? MarketingWebsiteSnapshotter.captureWidth))
                webView.takeSnapshot(with: config) { image, error in
                    if let error { self?.finish(.failure(error)); return }
                    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        self?.finish(.failure(NSError(domain: "BlackLabelMarketing.VirtualSet", code: 2,
                                                      userInfo: [NSLocalizedDescriptionKey: "The homepage capture was empty."]))); return
                    }
                    self?.finish(.success(cg))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<CGImage, Error>) {
        let callback = continuation; continuation = nil
        webView?.navigationDelegate = nil; webView = nil
        callback?.resume(with: result)
    }
}

@MainActor
final class MarketingVirtualSetModel: ObservableObject {
    @Published var websiteURL = ""
    @Published var websitePage: MarketingWebsitePage = .home
    @Published var enabled = false
    @Published var image: CGImage?
    @Published var pageFraming: MarketingPageFraming = .fullPage
    @Published var zoom = 1.0
    @Published var offsetX = 0.0
    @Published var offsetY = 0.0
    @Published var blur = 0.0
    @Published var dim = 0.12
    @Published var edgeSoftness = 4.0
    @Published var scrollPosition = 0.0
    @Published var busy = false
    @Published var status = "Paste the site URL, choose Home or Products, then capture the page."

    /// Pixel size of the reel this capture will sit behind. The capture viewport is derived from
    /// it so the page never has to be cropped to fit.
    @Published private(set) var canvasSize = ReelFormat.square.size

    private let snapshotter = MarketingWebsiteSnapshotter()
    /// Set only for pages captured from the web — a custom image the buyer chose keeps its own
    /// aspect and is never re-captured behind their back.
    private var lastCapturedURL: URL?

    var captureViewport: CGSize { MarketingWebsiteSnapshotter.captureViewport(for: canvasSize) }

    /// Called by the editor when the reel format changes. A page captured for a square reel is the
    /// wrong shape for a vertical one, so re-shoot it rather than letting the renderer crop it.
    func updateCanvas(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard abs(size.width / size.height - canvasSize.width / canvasSize.height) > 0.001 else {
            canvasSize = size; return
        }
        canvasSize = size
        guard lastCapturedURL != nil, !busy else { return }
        captureWebsitePage()
    }

    var background: MarketingVirtualBackground? {
        guard enabled, let image else { return nil }
        return MarketingVirtualBackground(image: image, pageFraming: pageFraming,
                                           zoom: CGFloat(zoom), offsetX: CGFloat(offsetX),
                                           offsetY: CGFloat(offsetY), blur: CGFloat(blur), dim: CGFloat(dim),
                                           edgeSoftness: CGFloat(edgeSoftness))
    }

    func captureWebsitePage() {
        guard let url = websitePage.resolvedURL(from: websiteURL) else {
            status = "Enter a valid website URL."; return
        }
        busy = true
        status = "Capturing \(websitePage.rawValue.lowercased()) at \(url.host ?? "website") privately…"
        Task {
            do {
                image = try await snapshotter.snapshot(url: url, scrollPosition: scrollPosition,
                                                       viewport: captureViewport)
                lastCapturedURL = url
                enabled = true
                status = "\(websitePage.rawValue) page captured at the reel's shape. The complete page is visible behind you."
            } catch { status = "\(websitePage.rawValue) page capture failed: \(error.localizedDescription)" }
            busy = false
        }
    }

    func captureHomepage() { captureWebsitePage() }

    func loadImage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            status = "That background image could not be read."; return
        }
        image = cg; lastCapturedURL = nil; enabled = true
        status = "Custom background loaded. Use Page framing if its shape differs from the reel."
    }

    func remove() { image = nil; lastCapturedURL = nil; enabled = false; status = "Virtual set removed." }
}

struct MarketingVirtualSetEditor: View {
    @ObservedObject var model: MarketingVirtualSetModel
    /// Pixel size of the reel this set sits behind. Drives the capture viewport so the page is
    /// shot at the reel's shape instead of being cropped to it afterwards.
    var canvasSize: CGSize
    @State private var imagePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HOMEPAGE BEHIND YOU").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                    Text("Marketing separates you from the camera and replaces the room with this page in the finished video.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                Toggle("Use", isOn: $model.enabled).toggleStyle(.switch).tint(BLTheme.gold)
                    .disabled(model.image == nil)
            }
            Picker("Website page", selection: $model.websitePage) {
                ForEach(MarketingWebsitePage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(BLTheme.gold)
            TextField(model.websitePage == .custom ? "https://yourcompany.com/your-page" : "https://yourcompany.com",
                      text: $model.websiteURL)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                GoldButton(label: model.busy
                           ? "Capturing…"
                           : (model.image == nil
                              ? "Capture \(model.websitePage.rawValue.lowercased())"
                              : "Switch to \(model.websitePage.rawValue.lowercased())"),
                           icon: model.websitePage == .products ? "shippingbox.fill" : "globe") {
                    model.captureWebsitePage()
                }
                .disabled(model.busy)
                GhostButton(label: "Choose image", icon: "photo") { imagePicker = true }
                if model.image != nil { Button("Remove") { model.remove() }.buttonStyle(.plain).foregroundColor(BLTheme.sub) }
            }
            .fileImporter(isPresented: $imagePicker, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { model.loadImage(url) }
            }
            setting("PAGE SECTION", value: $model.scrollPosition, range: 0...1,
                    valueText: model.scrollPosition < 0.2 ? "Top" : (model.scrollPosition > 0.8 ? "Bottom" : "\(Int(model.scrollPosition * 100))%"))
            Text("The captured page is a still background. Use Home / Products / Custom URL above to switch pages; buttons inside the camera preview are not interactive.")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if model.image != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PAGE FRAMING")
                        .font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.sub)
                    Picker("Page framing", selection: $model.pageFraming) {
                        ForEach(MarketingPageFraming.allCases) { framing in
                            Text(framing.label).tag(framing)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.pageFraming.detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    setting(model.pageFraming == .fullPage ? "AMBIENT ZOOM" : "ZOOM",
                            value: $model.zoom, range: 1...2, valueText: String(format: "%.1fx", model.zoom))
                    setting("DARKEN", value: $model.dim, range: 0...0.6, valueText: "\(Int(model.dim * 100))%")
                    setting(model.pageFraming == .fullPage ? "AMBIENT LEFT / RIGHT" : "MOVE LEFT / RIGHT",
                            value: $model.offsetX, range: -1...1, valueText: String(format: "%+.0f", model.offsetX * 100))
                    setting(model.pageFraming == .fullPage ? "AMBIENT DOWN / UP" : "MOVE DOWN / UP",
                            value: $model.offsetY, range: -1...1, valueText: String(format: "%+.0f", model.offsetY * 100))
                    setting("BACKGROUND BLUR", value: $model.blur, range: 0...24, valueText: "\(Int(model.blur))")
                    setting("EDGE SOFTNESS", value: $model.edgeSoftness, range: 0...12, valueText: "\(Int(model.edgeSoftness))")
                }
            }
            Text(model.status).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(model.status.contains("failed") || model.status.contains("valid") ? BLTheme.danger : BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.enabled ? BLTheme.gold.opacity(0.45) : BLTheme.stroke, lineWidth: 1))
        .onAppear { model.updateCanvas(canvasSize) }
        .onChangeCompat(of: canvasSize) { model.updateCanvas($0) }
    }

    private func setting(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.sub)
                Spacer(); Text(valueText).font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.gold)
            }
            Slider(value: value, in: range).tint(BLTheme.gold)
        }
    }
}
#endif
#endif // circuit-convert
