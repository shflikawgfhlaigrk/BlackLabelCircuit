#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// VigilHouse3DView — the House lens in true 3D.
//
// SceneKit rendering of the SAME self-learned LearnedHome the 2D Canvas
// draws: measured walls stand up with their door gaps carved, room cells
// tint with occupancy belief, the fleet's nodes sit wall-high with their
// self-assigned names, and THE DOT moves through the volume with its
// walked trail. Drag orbits the camera (SceneKit's built-in control).
//
// Honesty contract (§5.1) is inherited 1:1 from the 2D view: every layer
// here is the engine's own measurement or an explicitly labeled owner
// correction — nothing is invented for depth's sake.
//
// CPU contract: the scene re-renders ONLY when the frame data changes
// (rendersContinuously stays false, no SCNActions, no repeatForever —
// the fleet FX rule). An idle or unfocused window costs 0% CPU.
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

// MARK: - Snapshot the view renders from

struct House3DSnapshot: Equatable {
    let home: LearnedHome?
    let occupantLabel: String?
    let liveLabels: Set<String>
    let userWalls: [HomeUserWall]
    let installSpots: [InstallSpot]   // VG-27 owner mounting plan
}

// MARK: - NSViewRepresentable

struct VigilHouse3D: NSViewRepresentable {
    let snapshot: House3DSnapshot

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = SCNScene()
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling2X
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.defaultCameraController.maximumVerticalAngle = 85
        v.defaultCameraController.minimumVerticalAngle = 8
        // NOT rendersContinuously: SceneKit only redraws on scene mutation or
        // camera drag, so the idle map costs nothing.
        v.rendersContinuously = false

        let scene = v.scene!
        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.1
        camera.zFar = 200
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(7.5, 9.5, 11.5)
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        let root = SCNNode()
        root.name = "houseRoot"
        scene.rootNode.addChildNode(root)
        context.coordinator.root = root
        context.coordinator.rebuild(snapshot)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.rebuild(snapshot)
    }

    // MARK: - Coordinator: diffing rebuild

    final class Coordinator {
        var root: SCNNode?
        private var last: House3DSnapshot?

        func rebuild(_ snap: House3DSnapshot) {
            guard snap != last, let root = root else { return }
            last = snap
            root.childNodes.forEach { $0.removeFromParentNode() }
            root.addChildNode(House3DBuilder.build(snap))
        }
    }
}

// MARK: - Scene construction (pure: Snapshot -> SCNNode tree)

enum House3DBuilder {
    static let S: CGFloat = 10          // world size of the unit map square
    static let wallH: CGFloat = 1.05    // measured-wall height
    static let gold = NSColor(red: 0.788, green: 0.663, blue: 0.380, alpha: 1)
    static let champ = NSColor(red: 0.831, green: 0.773, blue: 0.627, alpha: 1)
    static let dimC = NSColor(white: 0.55, alpha: 1)

    /// unit map coords (x right, y up-north) -> world (X right, -Z north)
    static func world(_ p: [Double], y: CGFloat = 0) -> SCNVector3 {
        SCNVector3((CGFloat(p[0]) - 0.5) * S, y, (0.5 - CGFloat(p[1])) * S)
    }

    static func constantMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = true
        return m
    }

    /// One geometry of GL lines through the given world-space pairs.
    static func lines(_ segs: [(SCNVector3, SCNVector3)], color: NSColor) -> SCNNode {
        guard !segs.isEmpty else { return SCNNode() }
        var verts: [SCNVector3] = []
        verts.reserveCapacity(segs.count * 2)
        for s in segs { verts.append(s.0); verts.append(s.1) }
        let idx: [Int32] = Array(0..<Int32(verts.count))
        let src = SCNGeometrySource(vertices: verts)
        let el = idx.withUnsafeBufferPointer { buf in
            SCNGeometryElement(data: Data(buffer: buf), primitiveType: .line,
                               primitiveCount: segs.count, bytesPerIndex: 4)
        }
        let g = SCNGeometry(sources: [src], elements: [el])
        g.materials = [constantMaterial(color)]
        return SCNNode(geometry: g)
    }

    /// A standing wall slab between two unit-coord endpoints.
    static func slab(_ a: [Double], _ b: [Double], height: CGFloat,
                     thickness: CGFloat, color: NSColor) -> SCNNode {
        let wa = world(a), wb = world(b)
        let dx = wb.x - wa.x, dz = wb.z - wa.z
        let len = sqrt(dx * dx + dz * dz)
        guard len > 0.001 else { return SCNNode() }
        let box = SCNBox(width: len, height: height, length: thickness, chamferRadius: 0)
        box.materials = [constantMaterial(color)]
        let n = SCNNode(geometry: box)
        n.position = SCNVector3((wa.x + wb.x) / 2, height / 2, (wa.z + wb.z) / 2)
        n.eulerAngles.y = atan2(-dz, dx)
        return n
    }

    /// Flat filled polygon on the floor from unit-coord points.
    static func floorCell(_ pts: [[Double]], color: NSColor, y: CGFloat) -> SCNNode {
        guard pts.count >= 3 else { return SCNNode() }
        let path = NSBezierPath()
        // SCNShape lives in XY; rotating -90° about X maps local (x, y) to
        // world (x, -y), so feed y = -worldZ.
        func flat(_ p: [Double]) -> CGPoint {
            let w = world(p)
            return CGPoint(x: w.x, y: -w.z)
        }
        path.move(to: flat(pts[0]))
        for q in pts.dropFirst() { path.line(to: flat(q)) }
        path.close()
        path.flatness = 0.05
        let shape = SCNShape(path: path, extrusionDepth: 0)
        shape.materials = [constantMaterial(color)]
        let n = SCNNode(geometry: shape)
        n.eulerAngles.x = -.pi / 2
        n.position.y = y
        return n
    }

    static func sphere(_ radius: CGFloat, color: NSColor) -> SCNNode {
        let s = SCNSphere(radius: radius)
        s.segmentCount = 20
        s.materials = [constantMaterial(color)]
        return SCNNode(geometry: s)
    }

    static func label(_ text: String, at pos: SCNVector3, size: CGFloat,
                      color: NSColor) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        t.flatness = 0.3
        t.materials = [constantMaterial(color)]
        let n = SCNNode(geometry: t)
        let (mn, mx) = n.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, mn.y, 0)
        n.scale = SCNVector3(size, size, size)
        n.position = pos
        n.constraints = [SCNBillboardConstraint()]
        return n
    }

    static func build(_ snap: House3DSnapshot) -> SCNNode {
        let root = SCNNode()

        // floor grid — always present, the "space" itself
        var grid: [(SCNVector3, SCNVector3)] = []
        let steps = 10
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            grid.append((world([u, 0]), world([u, 1])))
            grid.append((world([0, u]), world([1, u])))
        }
        root.addChildNode(lines(grid, color: champ.withAlphaComponent(0.10)))

        // VG-27 install spots — the owner's mounting plan, rendered BEFORE the
        // learned-home guard so planning works with zero hardware (the pre-order
        // case: decide where the camera goes before anything arrives). Planned =
        // translucent champagne; installed = solid green. Cameras mount wall-high,
        // everything else sits at reachable-device height. An annotation layer,
        // never a fabricated device (§5.1).
        let installedGreen = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.45, alpha: 1)
        for s in snap.installSpots where s.pos.count == 2 {
            let c = s.installed ? installedGreen : champ
            let mountY: CGFloat = s.kind == .camera ? wallH * 0.95 : 0.45
            let p = world(s.pos, y: mountY)
            let core = sphere(0.07, color: c.withAlphaComponent(s.installed ? 0.95 : 0.5))
            core.position = p
            root.addChildNode(core)
            root.addChildNode(lines([(p, SCNVector3(p.x, 0.02, p.z))],
                                    color: c.withAlphaComponent(0.25)))
            root.addChildNode(label(s.kind.label.uppercased() + (s.installed ? "" : " · PLANNED"),
                                    at: SCNVector3(p.x, p.y + 0.16, p.z), size: 0.018,
                                    color: s.installed ? installedGreen
                                                      : champ.withAlphaComponent(0.75)))
        }

        guard let h = snap.home, !h.nodes.isEmpty else { return root }
        let posterior = h.occupancy?.posterior ?? [:]
        let hasWalls = (h.walls ?? []).contains { $0.kind == "wall" || $0.kind == "wall+door" }

        // 0) owner-scanned RoomPlan layer — faint standing reference planes
        if let sw = h.scan?.walls {
            for seg in sw where seg.count == 2 {
                root.addChildNode(slab(seg[0], seg[1], height: wallH * 0.9,
                                       thickness: 0.015,
                                       color: NSColor.white.withAlphaComponent(0.07)))
            }
        }

        // 1) learned room cells — floor tint = occupancy belief
        for (nid, node) in h.nodes {
            guard let cell = node.cell, cell.count >= 3 else { continue }
            let belief = posterior[nid] ?? 0
            root.addChildNode(floorCell(cell,
                color: gold.withAlphaComponent(0.045 + 0.28 * belief), y: 0.002))
        }

        // 2) sensing-coverage outline — honest footprint, low fence not wall
        if let outline = h.outline, outline.count >= 3 {
            var segs: [(SCNVector3, SCNVector3)] = []
            for i in 0..<outline.count {
                segs.append((world(outline[i], y: 0.02),
                             world(outline[(i + 1) % outline.count], y: 0.02)))
            }
            root.addChildNode(lines(segs, color: gold.withAlphaComponent(0.30)))
        }

        // 2b) owner-drawn wall corrections — labeled layer (white, like 2D)
        for w in snap.userWalls where w.a.count == 2 && w.b.count == 2 {
            root.addChildNode(slab(w.a, w.b, height: wallH,
                                   thickness: 0.05,
                                   color: NSColor.white.withAlphaComponent(0.32)))
        }

        // 3) WALLS — measured physics, door gaps already carved by the engine
        for w in h.walls ?? [] {
            switch w.kind {
            case "wall", "wall+door":
                for seg in w.segments ?? [] where seg.count == 2 {
                    root.addChildNode(slab(seg[0], seg[1], height: wallH,
                                           thickness: 0.06,
                                           color: champ.withAlphaComponent(0.30)))
                }
            case "open-passage":
                if w.boundary.count == 2 {
                    root.addChildNode(slab(w.boundary[0], w.boundary[1],
                                           height: 0.04, thickness: 0.03,
                                           color: dimC.withAlphaComponent(0.18)))
                }
            default:
                break
            }
        }

        // 4) doors — walked openings, flat gold rings on the floor
        for d in h.doors ?? [] where d.pos.count == 2 {
            let torus = SCNTorus(ringRadius: 0.14, pipeRadius: 0.015)
            torus.materials = [constantMaterial(gold.withAlphaComponent(0.75))]
            let n = SCNNode(geometry: torus)
            n.position = world(d.pos, y: 0.02)
            root.addChildNode(n)
        }

        // 5) learned handoff edges — subdued once real walls exist
        let maxW = max(1.0, h.edges.map(\.w).max() ?? 1.0)
        for e in h.edges {
            guard let a = h.nodes[String(e.a)], let b = h.nodes[String(e.b)] else { continue }
            let f = e.w / maxW
            let alpha = (0.14 + 0.4 * f) * (hasWalls ? 0.35 : 1.0)
            root.addChildNode(lines([(world(a.pos, y: 0.05), world(b.pos, y: 0.05))],
                                    color: gold.withAlphaComponent(alpha)))
        }

        // 6) recent trajectory — the walked path, rising slightly off the floor
        if let track = h.occupancy?.track, track.count >= 2 {
            let pts = track.compactMap { h.nodes[String($0.node)]?.pos }
            if pts.count >= 2 {
                for i in 1..<pts.count {
                    let age = Double(i) / Double(pts.count - 1)
                    root.addChildNode(lines(
                        [(world(pts[i - 1], y: 0.08), world(pts[i], y: 0.08))],
                        color: gold.withAlphaComponent(0.07 + 0.28 * age)))
                }
            }
        }

        // 7) fleet nodes — wall-high emissive markers with self-assigned names
        for (_, node) in h.nodes {
            let isOccupant = snap.occupantLabel != nil && node.label == snap.occupantLabel
            let live = snap.liveLabels.contains(node.label)
            let p = world(node.pos, y: wallH * 0.82)
            let core = sphere(0.09, color: live ? gold : dimC.withAlphaComponent(0.7))
            core.position = p
            root.addChildNode(core)
            if live {
                let halo = sphere(0.16, color: (isOccupant ? gold : champ).withAlphaComponent(0.18))
                halo.position = p
                root.addChildNode(halo)
            }
            // drop line to the floor grounds the marker in the volume
            root.addChildNode(lines([(p, SCNVector3(p.x, 0.02, p.z))],
                                    color: champ.withAlphaComponent(0.16)))
            let named = node.label != "unlabeled" && node.confidence >= 0.15
            let txt = named ? node.display.uppercased() : "LEARNING…"
            root.addChildNode(label(txt,
                at: SCNVector3(p.x, p.y + 0.22, p.z), size: 0.022,
                color: isOccupant ? champ : (named ? champ.withAlphaComponent(0.8)
                                                   : dimC.withAlphaComponent(0.7))))
        }

        // 8) THE DOTS — room-level multi-occupancy. The tracked occupant
        //    (kind "primary") is a gold body-height marker; every OTHER
        //    independently-occupied room is a cyan marker. Honesty: one dot
        //    per occupied ROOM, not per person — two bodies in one room show
        //    as one (this RF fleet has no per-person signal). Falls back to
        //    the single legacy `dot` when the engine hasn't sent `dots`.
        let occCyan = NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.98, alpha: 1)
        // the tracked occupant is the GREEN you-are-here ping (Founder ask
        // 2026-07-26) — gold belongs to nodes/rooms, green means YOU
        let youGreen = NSColor(calibratedRed: 0.22, green: 0.95, blue: 0.45, alpha: 1)
        let dots: [HomeDot] = (h.dots?.isEmpty == false) ? h.dots! : [h.dot].compactMap { $0 }
        for (i, dot) in dots.enumerated() where dot.pos.count == 2 {
            let isPrimary = i == 0 && (dot.kind ?? "primary") == "primary"
            let c = isPrimary ? youGreen : occCyan
            switch dot.mode {
            case "room":
                let ring = SCNTorus(ringRadius: 0.30, pipeRadius: 0.02)
                ring.materials = [constantMaterial(c.withAlphaComponent(0.85))]
                let n = SCNNode(geometry: ring)
                n.position = world(dot.pos, y: 0.03)
                root.addChildNode(n)
            default: // live | holding
                let bright = dot.mode == "live"
                let p = world(dot.pos, y: 0.42)
                let core = sphere(0.11, color: c)
                core.position = p
                root.addChildNode(core)
                let glow = sphere(bright ? 0.26 : 0.18,
                                  color: c.withAlphaComponent(bright ? 0.22 : 0.14))
                glow.position = p
                if isPrimary {
                    // breathing green halo — the you-marker pulses in the volume
                    glow.runAction(.repeatForever(.sequence([
                        .scale(to: 1.7, duration: bright ? 0.7 : 1.2),
                        .scale(to: 1.0, duration: bright ? 0.7 : 1.2)])))
                }
                root.addChildNode(glow)
                root.addChildNode(lines([(p, SCNVector3(p.x, 0.02, p.z))],
                                        color: c.withAlphaComponent(0.35)))
            }
        }

        return root
    }
}
#endif // circuit-convert
