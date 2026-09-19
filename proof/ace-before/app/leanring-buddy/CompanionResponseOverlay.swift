#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Cursor-following overlay that displays streaming AI response text.
//  Uses a non-activating NSPanel so it floats above all apps without
//  stealing focus, and repositions itself near the mouse cursor each frame.
//

import Foundation
import CircuitPortKit
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
    /// Height budget for the text block, set by the manager from the screen the
    /// bubble is on. The panel ignores mouse events, so an answer taller than
    /// the screen could never be scrolled — the view bottom-anchors and clips
    /// at this height so the newest lines always stay visible.
    @Published var bubbleTextMaxHeight: CGFloat = 380
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 340

    func showOverlayAndBeginStreaming() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        createOverlayPanelIfNeeded()
        let didShow =
            StealthEntryLatch.shared.performUnlessRaised {
                guard !StealthVisibilityGate.shared.isActive else {
                    return false
                }
                overlayViewModel.streamingResponseText = ""
                overlayViewModel.bubbleTextMaxHeight = bubbleTextHeightLimit()
                overlayViewModel.isShowingResponse = true
                startCursorTracking()
                overlayPanel?.alphaValue = 1
                overlayPanel?.orderFrontRegardless()
                return true
            } ?? false
        if !didShow {
            hideOverlay()
        }
    }

    func updateStreamingText(_ accumulatedText: String) {
        let didUpdate =
            StealthEntryLatch.shared.performUnlessRaised {
                guard !StealthVisibilityGate.shared.isActive else {
                    return false
                }
                overlayViewModel.streamingResponseText = accumulatedText
                // Re-read per update: the cursor (and the bubble with it) can
                // cross to a different-sized screen mid-stream.
                overlayViewModel.bubbleTextMaxHeight = bubbleTextHeightLimit()
                resizePanelToFitContent()
                return true
            } ?? false
        if !didUpdate {
            hideOverlay()
        }
    }

    func finishStreaming() {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            hideOverlay()
            return
        }
        // Keep the response visible for a few seconds after streaming ends,
        // then fade out so the user has time to read the last chunk.
        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopCursorTracking()
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = AceHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        // 60fps cursor tracking so the panel stays glued to the mouse
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelNearCursor()
            }
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised,
              let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    /// The tallest the text block may grow: 60% of the visible frame of the
    /// screen the cursor is on. The panel must never outgrow its screen — the
    /// origin clamp in `repositionPanelNearCursor` would pin it to the bottom
    /// and push the overflow off the top with no way to scroll it back.
    private func bubbleTextHeightLimit() -> CGFloat {
        let visibleFrameHeight =
            screenContainingPoint(NSEvent.mouseLocation)?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height
                ?? 800
        return visibleFrameHeight * 0.6
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        // fittingSize is already height-bounded: the SwiftUI view caps its text
        // at bubbleTextMaxHeight (60% of the screen) and clips from the top.
        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        let newHeight = fittingSize.height

        // Keep the panel origin relative to the cursor (the timer handles that),
        // but update the frame size so the content fits.
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Adjust origin Y so the panel grows upward (toward the cursor), not downward
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        if viewModel.isShowingResponse {
            Text(viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                // A streaming answer taller than the screen cannot be scrolled
                // (the panel ignores mouse events), so the text is capped and
                // bottom-anchored: overflow clips off the OLDEST lines while
                // the lines still being spoken stay on screen.
                .frame(
                    maxHeight: viewModel.bubbleTextMaxHeight,
                    alignment: .bottomLeading
                )
                .clipped()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AceGlassSurface(cornerRadius: 13))
                .overlay(alignment: .leading) {
                    Capsule().fill(DS.Colors.agentGoldBright)
                        .frame(width: 2, height: 18)
                        .shadow(color: DS.Colors.agentGold.opacity(0.5), radius: 4)
                        .offset(x: 5)
                        .allowsHitTesting(false)
                }
                .scaleEffect(reduceMotion || appeared ? 1 : 0.94, anchor: .topLeading)
                .opacity(reduceMotion || appeared ? 1 : 0)
                .onAppear {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { appeared = true }
                }
                .onDisappear { appeared = false }
        }
    }
}
#endif // circuit-convert
