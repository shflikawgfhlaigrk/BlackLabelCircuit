#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Spectrum3DView: a real 3D spectrum (SceneKit), showing BEFORE and AFTER together.
//
// Two rows of bars — AFTER up front in gold, BEFORE behind in dim blue — one bar per
// third-octave band, height = energy. Drag to orbit, pinch to zoom (allowsCameraControl).
// Rebuilds only when the data actually changes, so playback/scrub never thrash it (0% idle).

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(SceneKit) && !CIRCUIT_WINDOWS_SIM
import SceneKit
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

/// SCNView that hands scroll-wheel events up the responder chain instead of zooming the
/// camera. This view sits at the top of the workspace's ScrollView — plain two-finger
/// scrolling must always scroll the workspace, never get swallowed by the 3D camera.
/// Orbit stays drag-only; trackpad pinch still zooms.
private final class ScrollPassthroughSCNView: SCNView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct Spectrum3DView: NSViewRepresentable {
    var before: [Float]
    var after: [Float]
    var eqCurve: [Float]

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastBefore: [Float] = [Float(Int.min)]   // force first build
        var lastAfter: [Float] = []
    }

    func makeNSView(context: Context) -> SCNView {
        let v = ScrollPassthroughSCNView()
        v.backgroundColor = NSColor(red: 0.03, green: 0.02, blue: 0.07, alpha: 1)
        v.allowsCameraControl = true            // drag-orbit / pinch-zoom; scroll passes through
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = false           // no idle CPU; renders on interaction/rebuild
        v.scene = buildScene()
        context.coordinator.lastBefore = before
        context.coordinator.lastAfter = after
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        // Only rebuild when the spectrum data changed (not on every playhead tick).
        guard before != context.coordinator.lastBefore || after != context.coordinator.lastAfter else { return }
        context.coordinator.lastBefore = before
        context.coordinator.lastAfter = after
        v.scene = buildScene()
    }

    // MARK: - Scene

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        // Camera on a rig so allowsCameraControl orbits a sensible center.
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 42
        cam.camera?.zNear = 0.1; cam.camera?.zFar = 200
        cam.position = SCNVector3(0, 7, 15)
        cam.eulerAngles = SCNVector3(-0.42, 0, 0)
        root.addChildNode(cam)

        // Lights: warm key + cool fill + ambient.
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.color = NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)
        key.eulerAngles = SCNVector3(-0.9, 0.5, 0); root.addChildNode(key)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.color = NSColor(white: 0.22, alpha: 1); root.addChildNode(amb)

        // Floor.
        let floor = SCNNode(geometry: SCNFloor())
        (floor.geometry as? SCNFloor)?.reflectivity = 0.06
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.05, green: 0.04, blue: 0.09, alpha: 1)
        root.addChildNode(floor)

        let n = max(before.count, after.count)
        guard n > 0 else {
            addLabel("Master a track to see it in 3D", to: root)
            return scene
        }

        let spacing: Float = 0.62
        let width = Float(n - 1) * spacing
        let gold = NSColor(red: 1.0, green: 0.78, blue: 0.36, alpha: 1)
        let dim  = NSColor(red: 0.42, green: 0.47, blue: 0.62, alpha: 1)

        addRow(after,  z: 0.9,  color: gold, spacing: spacing, width: width, root: root, glow: 0.6)
        addRow(before, z: -1.6, color: dim,  spacing: spacing, width: width, root: root, glow: 0.15)

        return scene
    }

    private func addRow(_ data: [Float], z: Float, color: NSColor, spacing: Float,
                        width: Float, root: SCNNode, glow: CGFloat) {
        guard !data.isEmpty else { return }
        let minDB: Float = -72, maxDB: Float = -6, maxH: Float = 5.0
        for (i, v) in data.enumerated() {
            let t = max(0, min(1, (v - minDB) / (maxDB - minDB)))
            let h = 0.06 + t * maxH
            let box = SCNBox(width: 0.42, height: CGFloat(h), length: 0.42, chamferRadius: 0.03)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.emission.contents = color
            mat.emission.intensity = glow * CGFloat(0.3 + 0.7 * t)
            box.firstMaterial = mat
            let node = SCNNode(geometry: box)
            let x = Float(i) * spacing - width / 2
            node.position = SCNVector3(x, h / 2, z)
            root.addChildNode(node)
        }
    }

    private func addLabel(_ text: String, to root: SCNNode) {
        let t = SCNText(string: text, extrusionDepth: 0.4)
        t.font = NSFont.systemFont(ofSize: 3, weight: .semibold)
        t.firstMaterial?.diffuse.contents = NSColor(white: 0.5, alpha: 1)
        let node = SCNNode(geometry: t)
        node.scale = SCNVector3(0.9, 0.9, 0.9)
        node.position = SCNVector3(-9, 1, 0)
        root.addChildNode(node)
    }
}
#endif // circuit-convert
