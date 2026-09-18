#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Design Canvas screen (the freeform drag-and-drop design editor).
//
// Library: create/rename/duplicate/delete documents on any preset or custom-pixel format.
// Editor: a zoomable true-aspect canvas with select / drag / 8-handle resize / rotate, snap-to-
// center-and-edge guides, z-order + duplicate + delete + lock, a full inspector (typography,
// brand-palette color pickers, opacity), and pixel-exact export (single PNG/JPEG or one-click
// every-format to a folder). Undo/redo via a document snapshot stack. Keyboard on macOS: arrows
// nudge, ⌘D duplicates, delete removes, ⌘Z/⇧⌘Z undo/redo.
//
// §5.1: ships EMPTY — no seeded designs, no stock assets. Everything on the canvas is what the
// buyer typed, imported from their own files, or pulled from their own brand kit.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Screen (library ⇄ editor)

struct DesignCanvasScreen: View {
    @EnvironmentObject var prefs: Prefs
    @StateObject private var store = DesignDocumentStore()
    @State private var openDocID: UUID?

    var body: some View {
        Group {
            if let id = openDocID, let doc = store.document(id) {
                DesignEditorView(store: store, document: doc, onClose: { openDocID = nil })
                    .id(id)
            } else {
                DesignLibraryView(store: store, onOpen: { openDocID = $0 })
            }
        }
    }
}

// MARK: - Library (document list + new-design format picker)

private struct DesignLibraryView: View {
    @ObservedObject var store: DesignDocumentStore
    let onOpen: (UUID) -> Void

    @State private var customW = "1080"
    @State private var customH = "1080"
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var errorMsg = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Design Canvas",
                             subtitle: "Design real social graphics on a true-pixel canvas — drag, resize, rotate, export.")

                Panel(title: "New design", icon: "plus.square.on.square") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Pick a format to start with a blank canvas. Your own images and brand kit only — no stock assets.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: blGridColumns(minItemWidth: 150, spacing: 10, macColumns: 3), spacing: 10) {
                            ForEach(DesignFormat.presets) { format in
                                DesignFormatChip(format: format) { create(format) }
                            }
                        }
                        HStack(spacing: 10) {
                            Field(title: "Width px", text: $customW, prompt: "1080")
                            Field(title: "Height px", text: $customH, prompt: "1080")
                            GoldButton(label: "Create custom", icon: "plus") { createCustom() }
                        }
                        if !errorMsg.isEmpty {
                            Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                        }
                    }
                }

                Panel(title: "Your designs", icon: "square.grid.2x2") {
                    if store.documents.isEmpty {
                        HStack {
                            Spacer()
                            EmptyState(icon: "square.on.square.dashed", title: "No designs yet",
                                       hint: "Pick a format above and start with a blank canvas. Your own images and brand kit only — no stock assets.")
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.documents) { doc in
                                documentRow(doc)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder private func documentRow(_ doc: DesignDocument) -> some View {
        HStack(spacing: 12) {
            DesignThumbView(document: doc)
                .frame(width: 64, height: 64)
                .background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                if renameID == doc.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.gold.opacity(0.6), lineWidth: 1))
                        .onSubmit { commitRename(doc.id) }
                } else {
                    Text(doc.name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Text("\(doc.format.label) · \(doc.elements.count) layer\(doc.elements.count == 1 ? "" : "s") · \(doc.updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if renameID == doc.id {
                GhostButton(label: "Save", icon: "checkmark") { commitRename(doc.id) }
            } else {
                GhostButton(label: "Open", icon: "arrow.up.forward.square") { onOpen(doc.id) }
                IconButton(system: "pencil", accessibilityText: "Rename") { renameID = doc.id; renameText = doc.name }
                IconButton(system: "doc.on.doc", accessibilityText: "Duplicate") { _ = store.duplicate(doc.id) }
                IconButton(system: "trash", tint: BLTheme.danger, accessibilityText: "Delete") { store.delete(doc.id) }
            }
        }
        .padding(10)
        .background(BLTheme.bg2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func create(_ format: DesignFormat) {
        errorMsg = ""
        let doc = store.create(format: format)
        onOpen(doc.id)
    }

    private func createCustom() {
        guard let w = Int(customW.trimmingCharacters(in: .whitespaces)),
              let h = Int(customH.trimmingCharacters(in: .whitespaces)),
              w >= 64, h >= 64, w <= 8192, h <= 8192 else {
            errorMsg = "Enter a width and height between 64 and 8192 pixels."
            return
        }
        create(.custom(width: w, height: h))
    }

    private func commitRename(_ id: UUID) {
        store.rename(id, to: renameText)
        renameID = nil
        renameText = ""
    }
}

/// Format preset chip (mirrors ThemeStudio's PresetChip conventions, with a true aspect swatch).
private struct DesignFormatChip: View {
    let format: DesignFormat
    let tap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                // True-aspect mini canvas so the buyer sees the shape they're choosing.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(BLTheme.panelHi)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(BLTheme.gold.opacity(0.45), lineWidth: 1))
                    .aspectRatio(max(0.35, min(2.6, format.aspect)), contentMode: .fit)
                    .frame(height: 44)
                Text(format.name).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(format.width)×\(format.height)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(BLTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(hover ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .accessibilityLabel("\(format.name), \(format.width) by \(format.height)")
    }
}

/// Async document thumbnail rendered by the pixel-exact exporter at a tiny scale.
private struct DesignThumbView: View {
    let document: DesignDocument
    @State private var thumb: CGImage?
    var body: some View {
        Group {
            if let thumb {
                Image(decorative: thumb, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(BLTheme.sub)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: document.updated) {
            let doc = document
            let scale = 128 / max(CGFloat(doc.format.width), CGFloat(doc.format.height))
            let rendered = await Task.detached(priority: .utility) { DesignExport.render(doc, scale: scale) }.value
            thumb = rendered
        }
    }
}

// MARK: - Editor

private struct DesignEditorView: View {
    @EnvironmentObject var prefs: Prefs
    @ObservedObject var store: DesignDocumentStore
    let onClose: () -> Void

    @State private var doc: DesignDocument
    @State private var selection: UUID?
    @State private var undoStack: [DesignDocument] = []
    @State private var redoStack: [DesignDocument] = []
    @State private var zoom: CGFloat = 1                 // relative to fit
    @State private var magStart: CGFloat?
    @State private var dragOrigin: CGPoint?
    @State private var resizeStart: CGRect?
    @State private var activeGuides: [DesignGuide] = []
    @State private var showImageImporter = false
    @State private var toast = ""
    @State private var errorMsg = ""
    @State private var magicBusy = false
    @State private var genPrompt = ""
    @State private var genStyle: ImageMagicEngine.GenerationStyle = .illustration
    @State private var generating = false
    @State private var customW = ""
    @State private var customH = ""

    init(store: DesignDocumentStore, document: DesignDocument, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _doc = State(initialValue: document)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                editorToolbar
                statusLine
                canvasArea
            }
            .splitPaneWidth(min: 540, ideal: 780)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) { inspector }
                    .padding(14)
            }
            .splitPaneWidth(min: 300, ideal: 340, max: 420)
            .background(BLTheme.bg2.opacity(0.35))
        }
        .background(keyboardShortcuts)
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.png, .jpeg, .heic, .image],
                      allowsMultipleSelection: false) { result in
            importImage(result)
        }
        .onDisappear { commit(); store.flush() }
    }

    // MARK: toolbar

    private var editorToolbar: some View {
        // ~14 controls need ~600pt: on a phone the row must scroll horizontally — squeezed, the
        // chips ellipsize and tap targets collapse below 44pt.
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) { editorToolbarRow }
            .background(BLTheme.bg)
            .overlay(Rectangle().fill(BLTheme.stroke).frame(height: 1), alignment: .bottom)
        #else
        editorToolbarRow
            .background(BLTheme.bg)
            .overlay(Rectangle().fill(BLTheme.stroke).frame(height: 1), alignment: .bottom)
        #endif
    }

    private var editorToolbarRow: some View {
        HStack(spacing: 8) {
            GhostButton(label: "Library", icon: "chevron.left") { commit(); onClose() }
            TextField("Design name", text: Binding(
                get: { doc.name },
                set: { doc.name = $0; commit() }))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                #if os(iOS)
                .frame(minWidth: 150, maxWidth: 200)   // horizontal scroll proposes no width — keep the field typable
                #else
                .frame(maxWidth: 200)
                #endif
            Spacer(minLength: 8)
            GhostButton(label: "Text", icon: "textformat") { addText() }
            Menu {
                ForEach(DesignShapeKind.allCases) { kind in
                    Button { addShape(kind) } label: { Label(kind.rawValue, systemImage: kind.icon) }
                }
            } label: {
                Label("Shape", systemImage: "square.on.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .background(BLTheme.bg2).clipShape(Capsule())
                    .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            GhostButton(label: "Image", icon: "photo.on.rectangle") { showImageImporter = true }
            GhostButton(label: "Logo", icon: "seal") { addLogo() }
            Spacer(minLength: 8)
            IconButton(system: "arrow.uturn.backward", tint: undoStack.isEmpty ? BLTheme.sub : BLTheme.gold,
                       accessibilityText: "Undo") { undo() }
            IconButton(system: "arrow.uturn.forward", tint: redoStack.isEmpty ? BLTheme.sub : BLTheme.gold,
                       accessibilityText: "Redo") { redo() }
            IconButton(system: "minus.magnifyingglass", accessibilityText: "Zoom out") { zoom = max(0.2, zoom / 1.25) }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.sub).frame(width: 44)
            IconButton(system: "plus.magnifyingglass", accessibilityText: "Zoom in") { zoom = min(8, zoom * 1.25) }
            IconButton(system: "rectangle.arrowtriangle.2.inward", accessibilityText: "Zoom to fit") { zoom = 1 }
            exportMenu
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var exportMenu: some View {
        Menu {
            Button("Export PNG (\(doc.format.width)×\(doc.format.height))") { exportSingle(asJPEG: false) }
            Button("Export JPEG (\(doc.format.width)×\(doc.format.height))") { exportSingle(asJPEG: true) }
            #if os(macOS)
            Divider()
            Button("Export ALL formats to folder…") { exportEveryFormat() }
            #endif
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12.5, weight: .bold))
                Text("Export")
            }
            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.inkOnGold)
            .padding(.vertical, 9).padding(.horizontal, 15)
            .background(BLTheme.goldGrad).clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private var statusLine: some View {
        if !toast.isEmpty || !errorMsg.isEmpty {
            HStack {
                if !errorMsg.isEmpty {
                    Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                } else {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                }
                Spacer()
                IconButton(system: "xmark", tint: BLTheme.sub, accessibilityText: "Dismiss") { toast = ""; errorMsg = "" }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        }
    }

    // MARK: canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let fit = fitScale(in: geo.size)
            let sc = max(0.02, fit * zoom)
            let w = CGFloat(doc.format.width) * sc
            let h = CGFloat(doc.format.height) * sc
            ScrollView([.horizontal, .vertical]) {
                canvasSurface(sc: sc)
                    .frame(width: w, height: h)
                    .padding(36)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(BLTheme.bg2.opacity(0.5))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if magStart == nil { magStart = zoom }
                        zoom = min(8, max(0.2, (magStart ?? 1) * value))
                    }
                    .onEnded { _ in magStart = nil }
            )
        }
    }

    private func fitScale(in size: CGSize) -> CGFloat {
        let availW = max(80, size.width - 72)
        let availH = max(80, size.height - 72)
        return max(0.02, min(availW / CGFloat(doc.format.width), availH / CGFloat(doc.format.height)))
    }

    private func canvasSurface(sc: CGFloat) -> some View {
        let w = CGFloat(doc.format.width) * sc
        let h = CGFloat(doc.format.height) * sc
        return ZStack(alignment: .topLeading) {
            // Document background (checker under a transparent background — honest "no pixels here").
            if doc.background.transparent {
                DesignCheckerboard().clipShape(Rectangle())
            } else {
                Color(hex: doc.background.colorHex)
            }

            ForEach(doc.sortedElements) { el in
                DesignElementLayerView(element: el, scale: sc)
                    .onTapGesture { selection = el.id }
                    .gesture(moveGesture(el.id, sc: sc))
            }

            // Snap guides.
            ForEach(activeGuides) { g in
                if g.vertical {
                    Rectangle().fill(BLTheme.holoCyan.opacity(0.85))
                        .frame(width: 1, height: h)
                        .position(x: g.position * sc, y: h / 2)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(BLTheme.holoCyan.opacity(0.85))
                        .frame(width: w, height: 1)
                        .position(x: w / 2, y: g.position * sc)
                        .allowsHitTesting(false)
                }
            }

            if let sel = selection, let el = doc.element(sel) {
                DesignSelectionOverlay(
                    element: el, scale: sc,
                    onBegin: { beginHandleChange(el.id) },
                    onResize: { handle, delta in applyResize(handle, delta: delta) },
                    onRotate: { degrees in applyRotation(degrees) },
                    onEnd: { resizeStart = nil; commit() })
            }

            if doc.elements.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        EmptyState(icon: "square.on.square.dashed", title: "A blank canvas",
                                   hint: "Add text, shapes, your own images, or your brand logo from the toolbar. Your own images and brand kit only — no stock assets.")
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
        .coordinateSpace(name: "blmDesignCanvas")
        // NOT .clipped(): layers may hang off the canvas edge (the export clips them for real),
        // and clipping here would also cut off the selection handles at the borders.
        .overlay(Rectangle().stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    // MARK: gestures

    private func moveGesture(_ id: UUID, sc: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard var el = doc.element(id), !el.locked else { return }
                if dragOrigin == nil {
                    pushUndo()
                    dragOrigin = el.frame.origin
                    selection = id
                }
                guard let start = dragOrigin else { return }
                var origin = CGPoint(x: start.x + value.translation.width / sc,
                                     y: start.y + value.translation.height / sc)
                let snap = snapped(origin: origin, size: el.frame.size, excluding: id, sc: sc)
                origin = snap.origin
                activeGuides = snap.guides
                el.frame.origin = origin
                doc.upsert(el)
            }
            .onEnded { _ in
                dragOrigin = nil
                activeGuides = []
                commit()
            }
    }

    /// Snap a dragged element's edges/center to the canvas edges/center and other layers'
    /// edges/centers. Returns the adjusted origin plus the guide lines to draw.
    private func snapped(origin: CGPoint, size: CGSize, excluding id: UUID, sc: CGFloat)
        -> (origin: CGPoint, guides: [DesignGuide]) {
        let tol = 8 / sc
        let W = CGFloat(doc.format.width), H = CGFloat(doc.format.height)
        var xTargets: [CGFloat] = [0, W / 2, W]
        var yTargets: [CGFloat] = [0, H / 2, H]
        for other in doc.elements where other.id != id {
            xTargets.append(contentsOf: [other.frame.minX, other.frame.midX, other.frame.maxX])
            yTargets.append(contentsOf: [other.frame.minY, other.frame.midY, other.frame.maxY])
        }
        var out = origin
        var guides: [DesignGuide] = []
        // Which of the element's own x lines (left/center/right) lands closest to a target?
        var bestX: (delta: CGFloat, target: CGFloat, offset: CGFloat)?
        for offset in [CGFloat(0), size.width / 2, size.width] {
            for target in xTargets {
                let delta = target - (origin.x + offset)
                if abs(delta) <= tol, abs(delta) < abs(bestX?.delta ?? .greatestFiniteMagnitude) {
                    bestX = (delta, target, offset)
                }
            }
        }
        if let s = bestX {
            out.x = s.target - s.offset
            guides.append(DesignGuide(vertical: true, position: s.target))
        }
        var bestY: (delta: CGFloat, target: CGFloat, offset: CGFloat)?
        for offset in [CGFloat(0), size.height / 2, size.height] {
            for target in yTargets {
                let delta = target - (origin.y + offset)
                if abs(delta) <= tol, abs(delta) < abs(bestY?.delta ?? .greatestFiniteMagnitude) {
                    bestY = (delta, target, offset)
                }
            }
        }
        if let s = bestY {
            out.y = s.target - s.offset
            guides.append(DesignGuide(vertical: false, position: s.target))
        }
        return (out, guides)
    }

    private func beginHandleChange(_ id: UUID) {
        guard let el = doc.element(id), !el.locked else { return }
        pushUndo()
        resizeStart = el.frame
    }

    private func applyResize(_ handle: DesignHandle, delta: CGSize) {
        guard let start = resizeStart, let sel = selection,
              var el = doc.element(sel), !el.locked else { return }
        var f = start
        if handle.affectsLeft { f.origin.x += delta.width; f.size.width -= delta.width }
        if handle.affectsRight { f.size.width += delta.width }
        if handle.affectsTop { f.origin.y += delta.height; f.size.height -= delta.height }
        if handle.affectsBottom { f.size.height += delta.height }
        // Never collapse below 8×8 doc pixels; keep the untouched edge pinned.
        if f.size.width < 8 {
            if handle.affectsLeft { f.origin.x = start.maxX - 8 }
            f.size.width = 8
        }
        if f.size.height < 8 {
            if handle.affectsTop { f.origin.y = start.maxY - 8 }
            f.size.height = 8
        }
        el.frame = f
        doc.upsert(el)
    }

    private func applyRotation(_ degrees: Double) {
        guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
        var deg = degrees.truncatingRemainder(dividingBy: 360)
        if deg > 180 { deg -= 360 }
        if deg < -180 { deg += 360 }
        // Gentle snap to the compass points.
        for anchor in [-180.0, -90, 0, 90, 180] where abs(deg - anchor) <= 3 { deg = anchor }
        el.rotation = deg
        doc.upsert(el)
    }

    // MARK: add layers

    private func addText() {
        pushUndo()
        var el = DesignElement.text("New text", on: doc.format, accentHex: prefs.brandAccentRGB)
        el.zIndex = doc.maxZ + 1
        doc.elements.append(el)
        doc.updated = Date()
        selection = el.id
        commit()
    }

    private func addShape(_ kind: DesignShapeKind) {
        pushUndo()
        var el = DesignElement.shape(kind, on: doc.format, accentHex: prefs.brandAccentRGB)
        el.zIndex = doc.maxZ + 1
        doc.elements.append(el)
        doc.updated = Date()
        selection = el.id
        commit()
    }

    private func addLogo() {
        guard let data = prefs.logoData, let size = ImageMagicEngine.pixelSize(of: data) else {
            errorMsg = "No brand logo yet — add your own logo in Settings first."
            toast = ""
            return
        }
        pushUndo()
        let el = DesignElement.image(data: data, pixelWidth: size.width, pixelHeight: size.height,
                                     on: doc.format, asLogo: true)
        doc.add(el)
        selection = el.id
        commit()
        toast = "Brand logo added."
        errorMsg = ""
    }

    private func importImage(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMsg = "Couldn't open that image — try a PNG or JPG. (\(error.localizedDescription))"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let size = ImageMagicEngine.pixelSize(of: data) else {
                    errorMsg = "That file is not a readable image."
                    return
                }
                let bookmark = try? url.bookmarkData()
                pushUndo()
                let el = DesignElement.image(data: data, pixelWidth: size.width, pixelHeight: size.height,
                                             on: doc.format, bookmark: bookmark)
                doc.add(el)
                selection = el.id
                commit()
                toast = "Image added."
                errorMsg = ""
            } catch {
                errorMsg = "Couldn't import that image — try a PNG or JPG. (\(error.localizedDescription))"
            }
        }
    }

    // MARK: selection ops

    private func duplicateSelection() {
        guard let sel = selection else { return }
        pushUndo()
        if let newID = doc.duplicate(sel) { selection = newID }
        commit()
    }

    private func deleteSelection() {
        guard let sel = selection, let el = doc.element(sel), !el.locked else { return }
        pushUndo()
        doc.remove(sel)
        selection = nil
        commit()
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
        el.frame.origin.x += dx
        el.frame.origin.y += dy
        doc.upsert(el)
        commit()
    }

    // MARK: undo / persistence

    private func pushUndo() {
        undoStack.append(doc)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = last
        if let sel = selection, doc.element(sel) == nil { selection = nil }
        commit()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
        if let sel = selection, doc.element(sel) == nil { selection = nil }
        commit()
    }

    private func commit() { store.update(doc) }

    /// Hidden buttons carry the keyboard map (same pattern as main.swift's ⌘K search button).
    private var keyboardShortcuts: some View {
        Group {
            Button("") { nudge(-1, 0) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { nudge(1, 0) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { nudge(0, -1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { nudge(0, 1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { nudge(-10, 0) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { nudge(10, 0) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { nudge(0, -10) }.keyboardShortcut(.upArrow, modifiers: .shift)
            Button("") { nudge(0, 10) }.keyboardShortcut(.downArrow, modifiers: .shift)
            Button("") { duplicateSelection() }.keyboardShortcut("d", modifiers: .command)
            Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .hidden()
    }

    // MARK: export actions

    private func exportSingle(asJPEG: Bool) {
        do {
            let data = try DesignExport.imageData(doc, asJPEG: asJPEG)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = DesignExport.safeFileName(doc.name) + (asJPEG ? ".jpg" : ".png")
            panel.allowedContentTypes = [asJPEG ? UTType.jpeg : UTType.png]
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                toast = "Exported \(doc.format.width)×\(doc.format.height) \(asJPEG ? "JPEG" : "PNG")."
                errorMsg = ""
            }
        } catch {
            errorMsg = "Couldn't export the design — \(error.localizedDescription) Try a different folder."
            toast = ""
        }
    }

    #if os(macOS)
    private func exportEveryFormat() {
        do {
            if let urls = try DesignExport.chooseFolderAndExportAll(doc) {
                toast = "Exported \(urls.count) formats (\(DesignFormat.presets.map { $0.name }.joined(separator: ", ")))."
                errorMsg = ""
            }
        } catch {
            errorMsg = "Couldn't export those formats — \(error.localizedDescription) Try a different folder."
            toast = ""
        }
    }
    #endif

    // MARK: magic (Vision cutout, looks, Apple Intelligence generation)

    private func removeBackground() {
        guard let sel = selection, let el = doc.element(sel),
              el.kind == .image || el.kind == .logo, let data = el.imageData else { return }
        magicBusy = true
        errorMsg = ""
        Task {
            let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                Result { try ImageMagicEngine.removeBackground(fromImageData: data) }
            }.value
            switch result {
            case .success(let cutout):
                pushUndo()
                if var e = doc.element(sel) {
                    e.imageData = cutout
                    doc.upsert(e)
                    commit()
                }
                toast = "Background removed."
            case .failure(let error):
                errorMsg = "Couldn't remove the background from this image — \(error.localizedDescription)"
                toast = ""
            }
            magicBusy = false
        }
    }

    private func applyLook(_ look: ImageMagicEngine.Look) {
        guard let sel = selection, let el = doc.element(sel),
              el.kind == .image || el.kind == .logo, let data = el.imageData else { return }
        magicBusy = true
        errorMsg = ""
        Task {
            let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                Result { try ImageMagicEngine.apply(look, toImageData: data) }
            }.value
            switch result {
            case .success(let filtered):
                pushUndo()
                if var e = doc.element(sel) {
                    e.imageData = filtered
                    doc.upsert(e)
                    commit()
                }
                toast = "\(look.rawValue) look applied (undo to revert)."
            case .failure(let error):
                errorMsg = "Couldn't apply that look — \(error.localizedDescription)"
                toast = ""
            }
            magicBusy = false
        }
    }

    private func generateImage() {
        generating = true
        errorMsg = ""
        let prompt = genPrompt
        let style = genStyle
        Task {
            do {
                let cg = try await ImageMagicEngine.generateImage(prompt: prompt, style: style)
                guard let png = ImageMagicEngine.pngData(cg) else { throw ImageMagicError.filterFailed }
                pushUndo()
                let el = DesignElement.image(data: png, pixelWidth: cg.width, pixelHeight: cg.height, on: doc.format)
                doc.add(el)
                selection = el.id
                commit()
                toast = "Generated image added."
            } catch {
                errorMsg = "Couldn't generate the image — \(error.localizedDescription)"
                toast = ""
            }
            generating = false
        }
    }

    // MARK: inspector

    @ViewBuilder private var inspector: some View {
        if let sel = selection, let el = doc.element(sel) {
            selectionInspector(el)
        } else {
            documentInspector
        }
        generatePanel
    }

    /// Brand-first palette: the buyer's live accent + extracted brand colors, then neutrals.
    private var brandPalette: [UInt32] {
        var seen = Set<UInt32>()
        var out: [UInt32] = []
        for hex in [prefs.brandAccentRGB] + prefs.brandColors
            + [0xFFFFFF, 0xEDEDED, 0x8C8C8C, 0x1A1A1E, 0x0B0B0D, 0x000000] {
            if seen.insert(hex).inserted { out.append(hex) }
        }
        return out
    }

    // ---- document (nothing selected)

    @ViewBuilder private var documentInspector: some View {
        Panel(title: "Canvas", icon: "square.dashed") {
            VStack(alignment: .leading, spacing: 12) {
                Text(doc.format.label)
                    .font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.gold)
                DesignColorRow(title: "BACKGROUND", hex: Binding(
                    get: { doc.background.colorHex },
                    set: { doc.background.colorHex = $0; doc.background.transparent = false; commit() }),
                    palette: brandPalette)
                Toggle(isOn: Binding(
                    get: { doc.background.transparent },
                    set: { doc.background.transparent = $0; commit() })) {
                    Text("Transparent background (PNG export keeps it)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                .tint(BLTheme.gold)
                Divider().overlay(BLTheme.stroke)
                Text("RESIZE FOR A FORMAT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                Text("Re-lays every layer proportionally, centered on the new canvas.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                LazyVGrid(columns: blGridColumns(minItemWidth: 120, spacing: 8, macColumns: 2), spacing: 8) {
                    ForEach(DesignFormat.presets) { format in
                        GhostButton(label: format.name, icon: "arrow.left.and.right.square") { resize(to: format) }
                    }
                }
                HStack(spacing: 8) {
                    Field(title: "W px", text: $customW, prompt: "\(doc.format.width)")
                    Field(title: "H px", text: $customH, prompt: "\(doc.format.height)")
                    GhostButton(label: "Apply", icon: "checkmark") { resizeCustom() }
                }
                Text("Select a layer on the canvas to edit it. \(AppBrand.tapVerb.capitalized) empty canvas to come back here.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resize(to format: DesignFormat) {
        guard format != doc.format else { return }
        pushUndo()
        let id = doc.id
        var resized = DesignExport.relayout(doc, to: format)
        resized.id = id
        doc = resized
        commit()
        toast = "Canvas is now \(format.label)."
    }

    private func resizeCustom() {
        guard let w = Int(customW.trimmingCharacters(in: .whitespaces)),
              let h = Int(customH.trimmingCharacters(in: .whitespaces)),
              w >= 64, h >= 64, w <= 8192, h <= 8192 else {
            errorMsg = "Enter a width and height between 64 and 8192 pixels."
            return
        }
        resize(to: .custom(width: w, height: h))
    }

    // ---- selection

    @ViewBuilder private func selectionInspector(_ el: DesignElement) -> some View {
        Panel(title: el.kind.label, icon: iconFor(el)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    GhostButton(label: el.locked ? "Unlock" : "Lock",
                                icon: el.locked ? "lock.fill" : "lock.open") { toggleLock() }
                    GhostButton(label: "Duplicate", icon: "doc.on.doc") { duplicateSelection() }
                    Spacer()
                    IconButton(system: "trash", tint: BLTheme.danger, accessibilityText: "Delete layer") { deleteSelection() }
                }
                if el.locked {
                    Label("Locked — position, size and style are frozen until unlocked.", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    arrangeControls
                    sliderRow("Opacity", value: bindDouble(\.opacity, fallback: 1), range: 0.05...1,
                              readout: "\(Int((el.opacity * 100).rounded()))%")
                    HStack {
                        sliderRow("Rotation", value: bindDouble(\.rotation, fallback: 0), range: -180...180,
                                  readout: "\(Int(el.rotation.rounded()))°")
                        GhostButton(label: "0°", icon: "gyroscope") {
                            modifySelection { $0.rotation = 0 }
                        }
                    }
                    positionSizeFields
                    Divider().overlay(BLTheme.stroke)
                    switch el.kind {
                    case .text: textControls(el)
                    case .shape: shapeControls(el)
                    case .image, .logo: imageControls(el)
                    }
                }
            }
        }
    }

    private func iconFor(_ el: DesignElement) -> String {
        switch el.kind {
        case .text: return "textformat"
        case .shape: return el.shape.icon
        case .image: return "photo"
        case .logo: return "seal"
        }
    }

    private func toggleLock() {
        guard let sel = selection, var el = doc.element(sel) else { return }
        pushUndo()
        el.locked.toggle()
        doc.upsert(el)
        commit()
    }

    private var arrangeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ARRANGE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 6) {
                IconButton(system: "square.3.layers.3d.top.filled", accessibilityText: "Bring to front") {
                    zChange { $0.bringToFront($1) }
                }
                IconButton(system: "square.2.layers.3d.top.filled", accessibilityText: "Bring forward") {
                    zChange { $0.bringForward($1) }
                }
                IconButton(system: "square.2.layers.3d.bottom.filled", accessibilityText: "Send backward") {
                    zChange { $0.sendBackward($1) }
                }
                IconButton(system: "square.3.layers.3d.bottom.filled", accessibilityText: "Send to back") {
                    zChange { $0.sendToBack($1) }
                }
            }
        }
    }

    private func zChange(_ op: (inout DesignDocument, UUID) -> Void) {
        guard let sel = selection else { return }
        pushUndo()
        op(&doc, sel)
        commit()
    }

    private var positionSizeFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("POSITION / SIZE (PX)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 8) {
                designNumberField("X", value: bindFrame(\.frame.origin.x))
                designNumberField("Y", value: bindFrame(\.frame.origin.y))
                designNumberField("W", value: bindFrame(\.frame.size.width, minimum: 8))
                designNumberField("H", value: bindFrame(\.frame.size.height, minimum: 8))
            }
        }
    }

    @ViewBuilder private func textControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEXT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            TextField("Your words", text: bind(\.text, fallback: ""), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6)
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
            Picker("Font", selection: bind(\.fontFamily, fallback: "")) {
                Text("System").tag("")
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu).tint(BLTheme.gold)
            sliderRow("Size", value: bindDouble(\.fontSize, fallback: 64), range: 8...400,
                      readout: "\(Int(el.fontSize.rounded())) px")
            Picker("", selection: bind(\.fontWeight, fallback: .semibold)) {
                ForEach(DesignFontWeight.allCases) { w in Text(w.rawValue).tag(w) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("", selection: bind(\.alignment, fallback: .center)) {
                ForEach(DesignTextAlignment.allCases) { a in Image(systemName: a.icon).tag(a) }
            }
            .pickerStyle(.segmented).labelsHidden()
            DesignColorRow(title: "TEXT COLOR", hex: bind(\.textColorHex, fallback: 0xEDEDED), palette: brandPalette)
        }
    }

    @ViewBuilder private func shapeControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHAPE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: bind(\.shape, fallback: .rectangle)) {
                ForEach(DesignShapeKind.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle(isOn: bind(\.fillEnabled, fallback: true)) {
                Text("Fill").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            .tint(BLTheme.gold)
            if el.fillEnabled {
                DesignColorRow(title: "FILL", hex: bind(\.fillHex, fallback: 0xD9B65C), palette: brandPalette)
            }
            if el.shape != .line {
                DesignColorRow(title: "STROKE", hex: bind(\.strokeHex, fallback: 0xEDEDED), palette: brandPalette)
            }
            sliderRow(el.shape == .line ? "Thickness" : "Stroke width",
                      value: bindDouble(\.strokeWidth, fallback: 0), range: 0...60,
                      readout: "\(Int(el.strokeWidth.rounded())) px")
            if el.shape == .rounded {
                sliderRow("Corner radius", value: bindDouble(\.cornerRadius, fallback: 0), range: 0...300,
                          readout: "\(Int(el.cornerRadius.rounded())) px")
            }
        }
    }

    @ViewBuilder private func imageControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IMAGE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            sliderRow("Corner radius", value: bindDouble(\.cornerRadius, fallback: 0), range: 0...300,
                      readout: "\(Int(el.cornerRadius.rounded())) px")
            Divider().overlay(BLTheme.stroke)
            photoCropControls(el)
            Divider().overlay(BLTheme.stroke)
            photoAdjustControls(el)
            Divider().overlay(BLTheme.stroke)
            photoEffectControls(el)
            Divider().overlay(BLTheme.stroke)
            Text("MAGIC").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            if ImageMagicEngine.backgroundRemovalAvailable {
                GoldButton(label: magicBusy ? "Working…" : "Remove background", fill: true,
                           icon: "person.and.background.dotted") {
                    if !magicBusy { removeBackground() }
                }
            } else {
                Label("Background removal needs macOS 14 or later.", systemImage: "info.circle")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Text("LOOKS (LOCAL FILTERS)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 6) {
                ForEach(ImageMagicEngine.Look.allCases) { look in
                    GhostButton(label: look.rawValue, icon: look.icon) {
                        if !magicBusy { applyLook(look) }
                    }
                }
            }
            Text("Filters bake into this layer's pixels — Undo (⌘Z) reverts.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
        }
    }

    // MARK: photo editing (non-destructive — see DesignPhotoEdit.swift)

    @ViewBuilder private func photoCropControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CROP & FLIP").font(BLFonts.mono(10, weight: .bold))
                    .foregroundColor(BLTheme.sub).tracking(0.8)
                Spacer()
                if el.photo.hasCrop {
                    GhostButton(label: "Clear", icon: "arrow.uturn.backward") {
                        modifySelection { $0.photo.clearCrop() }
                    }
                }
            }
            sliderRow("Trim top", value: bindPhoto(\.cropTop, fallback: 0),
                      range: 0...DesignPhotoEdit.maxCropPerAxis, readout: pct(el.photo.cropTop))
            sliderRow("Trim bottom", value: bindPhoto(\.cropBottom, fallback: 0),
                      range: 0...DesignPhotoEdit.maxCropPerAxis, readout: pct(el.photo.cropBottom))
            sliderRow("Trim left", value: bindPhoto(\.cropLeading, fallback: 0),
                      range: 0...DesignPhotoEdit.maxCropPerAxis, readout: pct(el.photo.cropLeading))
            sliderRow("Trim right", value: bindPhoto(\.cropTrailing, fallback: 0),
                      range: 0...DesignPhotoEdit.maxCropPerAxis, readout: pct(el.photo.cropTrailing))
            HStack(spacing: 6) {
                GhostButton(label: "Fill frame", icon: "aspectratio") { fitCropToFrame() }
                GhostButton(label: "Flip H", icon: "arrow.left.arrow.right",
                            tint: el.photo.flipHorizontal ? BLTheme.gold : BLTheme.text) {
                    modifySelection { $0.photo.flipHorizontal.toggle() }
                }
                GhostButton(label: "Flip V", icon: "arrow.up.arrow.down",
                            tint: el.photo.flipVertical ? BLTheme.gold : BLTheme.text) {
                    modifySelection { $0.photo.flipVertical.toggle() }
                }
            }
            Text("Crop trims the source image, not the layer box. “Fill frame” centre-crops to this layer's shape.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func photoAdjustControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADJUST").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            sliderRow("Exposure", value: bindPhoto(\.grade.exposure, fallback: 0), range: -1...1,
                      readout: String(format: "%+.2f EV", el.photo.grade.exposure))
            sliderRow("Contrast", value: bindPhoto(\.grade.contrast, fallback: 1), range: 0.6...1.4,
                      readout: String(format: "%.2f", el.photo.grade.contrast))
            sliderRow("Saturation", value: bindPhoto(\.grade.saturation, fallback: 1), range: 0...2,
                      readout: String(format: "%.2f", el.photo.grade.saturation))
            sliderRow("Warmth", value: bindPhoto(\.grade.temperature, fallback: 0), range: -100...100,
                      readout: String(format: "%+.0f", el.photo.grade.temperature))
            sliderRow("Tint", value: bindPhoto(\.grade.tint, fallback: 0), range: -100...100,
                      readout: String(format: "%+.0f", el.photo.grade.tint))
            sliderRow("Vibrance", value: bindPhoto(\.grade.vibrance, fallback: 0), range: -1...1,
                      readout: String(format: "%+.2f", el.photo.grade.vibrance))
        }
    }

    @ViewBuilder private func photoEffectControls(_ el: DesignElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EFFECTS").font(BLFonts.mono(10, weight: .bold))
                    .foregroundColor(BLTheme.sub).tracking(0.8)
                Spacer()
                if !el.photo.isNeutral {
                    GhostButton(label: "Reset photo", icon: "arrow.counterclockwise") {
                        modifySelection { $0.photo = DesignPhotoEdit() }
                    }
                }
            }
            sliderRow("Sharpen", value: bindPhoto(\.sharpen, fallback: 0), range: 0...2,
                      readout: String(format: "%.2f", el.photo.sharpen))
            sliderRow("Blur", value: bindPhoto(\.blur, fallback: 0), range: 0...24,
                      readout: "\(Int(el.photo.blur.rounded())) px")
            sliderRow("Vignette", value: bindPhoto(\.vignette, fallback: 0), range: 0...2,
                      readout: String(format: "%.2f", el.photo.vignette))
            Text("These are non-destructive — your imported file is never rewritten, and “Reset photo” restores it exactly.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// Centre-crop the source so its aspect matches this layer's box — i.e. show the whole
    /// subject the layer is actually displaying, with nothing spilling outside the aspect-fill.
    private func fitCropToFrame() {
        modifySelection { el in
            guard let data = el.imageData,
                  let size = ImageMagicEngine.pixelSize(of: data),
                  size.width > 0, size.height > 0,
                  el.frame.width > 0, el.frame.height > 0 else { return }
            el.photo.setCenterCrop(targetAspect: Double(el.frame.width / el.frame.height),
                                   sourceAspect: Double(size.width) / Double(size.height))
        }
    }

    private var generatePanel: some View {
        Panel(title: "Generate image", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                if ImageMagicEngine.imageGenerationAvailable {
                    Text("On-device Apple Intelligence image generation from your own prompt. The result is added to this canvas as a layer.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Field(title: "Prompt", text: $genPrompt, prompt: "A gold espresso machine on black marble")
                    Picker("", selection: $genStyle) {
                        ForEach(ImageMagicEngine.GenerationStyle.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    GoldButton(label: generating ? "Generating…" : "Generate & add to canvas", fill: true,
                               icon: "sparkles") {
                        if !generating { generateImage() }
                    }
                } else {
                    Label("Apple Intelligence image generation unavailable on this \(PlatformWords.device).",
                          systemImage: "info.circle")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Nothing is substituted in its place — import your own images instead.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
    }

    // MARK: bindings into the selected element

    private func bind<T>(_ keyPath: WritableKeyPath<DesignElement, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { doc.element(selection)?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
                el[keyPath: keyPath] = value
                doc.upsert(el)
                commit()
            })
    }

    private func bindDouble(_ keyPath: WritableKeyPath<DesignElement, Double>, fallback: Double) -> Binding<Double> {
        bind(keyPath, fallback: fallback)
    }

    /// Binding into the selected layer's non-destructive photo stack. Every write re-clamps the
    /// whole stack, so an out-of-range value can never reach the renderer or the saved document.
    private func bindPhoto(_ keyPath: WritableKeyPath<DesignPhotoEdit, Double>,
                           fallback: Double) -> Binding<Double> {
        Binding(
            get: { doc.element(selection)?.photo[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
                el.photo[keyPath: keyPath] = value
                el.photo.clamp()
                doc.upsert(el)
                commit()
            })
    }

    private func bindFrame(_ keyPath: WritableKeyPath<DesignElement, CGFloat>, minimum: CGFloat = -100_000) -> Binding<Double> {
        Binding(
            get: { Double(doc.element(selection)?[keyPath: keyPath] ?? 0) },
            set: { value in
                guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
                el[keyPath: keyPath] = max(minimum, CGFloat(value))
                doc.upsert(el)
                commit()
            })
    }

    private func modifySelection(_ mutate: (inout DesignElement) -> Void) {
        guard let sel = selection, var el = doc.element(sel), !el.locked else { return }
        pushUndo()
        mutate(&el)
        doc.upsert(el)
        commit()
    }

    @ViewBuilder private func sliderRow(_ title: String, value: Binding<Double>,
                                        range: ClosedRange<Double>, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Text(readout).font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.gold)
            }
            Slider(value: value, in: range).tint(BLTheme.gold)
                .accessibilityLabel(title).accessibilityValue(readout)
        }
    }

    @ViewBuilder private func designNumberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain)
                .font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.text)
                .padding(.vertical, 5).padding(.horizontal, 7)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Guides

private struct DesignGuide: Identifiable {
    let vertical: Bool
    let position: CGFloat
    var id: String { "\(vertical ? "v" : "h")-\(position)" }
}

// MARK: - Element layer view (the on-canvas rendering — mirrors DesignExport exactly)

private struct DesignElementLayerView: View {
    let element: DesignElement
    let scale: CGFloat

    var body: some View {
        let w = max(1, element.frame.width * scale)
        let h = max(1, element.frame.height * scale)
        content(w: w, h: h)
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .opacity(element.opacity)
            .rotationEffect(.degrees(element.rotation))
            .position(x: element.frame.midX * scale, y: element.frame.midY * scale)
    }

    @ViewBuilder private func content(w: CGFloat, h: CGFloat) -> some View {
        switch element.kind {
        case .text:
            Text(element.text)
                .font(elementFont)
                .foregroundColor(Color(hex: element.textColorHex))
                .multilineTextAlignment(element.alignment.textAlignment)
                .frame(width: w, height: h, alignment: element.alignment.frameAlignment)
                .clipped()
        case .shape:
            shapeView(w: w, h: h)
        case .image, .logo:
            if let data = element.imageData, let img = previewImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: element.cornerRadius * scale, style: .continuous))
            } else {
                // Honest broken-image state (bytes missing/unreadable) — never a placeholder photo.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BLTheme.panelHi)
                    .overlay(Image(systemName: "photo").font(.system(size: min(w, h) * 0.3)).foregroundColor(BLTheme.sub))
            }
        }
    }

    /// Photo edits preview at most this many pixels on the long side, so a slider drag stays
    /// interactive on a 40-megapixel import. Export (DesignExport) always renders full-resolution.
    private static let previewMaxPixel: CGFloat = 2048

    /// An UNEDITED layer takes the original decode path untouched — identical to the rendering
    /// before photo editing existed. Only a non-neutral stack goes through the CoreImage pipeline,
    /// and if that pipeline yields nothing we fall back to the buyer's original pixels rather than
    /// showing a broken layer.
    private func previewImage(data: Data) -> NSImage? {
        guard !element.photo.isNeutral else {
            return DesignImageCache.image(for: element.id, data: data)
        }
        guard let cg = DesignPhotoCache.image(for: element.id, data: data,
                                              edit: element.photo,
                                              maxPixel: Self.previewMaxPixel) else {
            return DesignImageCache.image(for: element.id, data: data)
        }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    private var elementFont: Font {
        let size = CGFloat(element.fontSize) * scale
        if element.fontFamily.isEmpty {
            return .system(size: size, weight: element.fontWeight.fontWeight)
        }
        return .custom(element.fontFamily, size: size).weight(element.fontWeight.fontWeight)
    }

    @ViewBuilder private func shapeView(w: CGFloat, h: CGFloat) -> some View {
        let fill = element.fillEnabled ? Color(hex: element.fillHex) : Color.clear
        let strokeColor = Color(hex: element.strokeHex)
        let sw = CGFloat(element.strokeWidth) * scale
        switch element.shape {
        case .rectangle:
            Rectangle().fill(fill)
                .overlay(Rectangle().stroke(strokeColor, lineWidth: sw).opacity(sw > 0 ? 1 : 0))
        case .rounded:
            let r = CGFloat(element.cornerRadius) * scale
            RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                    .stroke(strokeColor, lineWidth: sw).opacity(sw > 0 ? 1 : 0))
        case .ellipse:
            Ellipse().fill(fill)
                .overlay(Ellipse().stroke(strokeColor, lineWidth: sw).opacity(sw > 0 ? 1 : 0))
        case .line:
            let t = max(1, (element.strokeWidth > 0 ? CGFloat(element.strokeWidth) : element.frame.height) * scale)
            Capsule().fill(fill)
                .frame(width: w, height: min(t, h))
                .frame(width: w, height: h, alignment: .center)
        }
    }
}

/// Decoded platform-image cache so canvas drags never re-decode multi-MB image data per frame.
private enum DesignImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(for id: UUID, data: Data) -> NSImage? {
        let key = "\(id.uuidString)-\(data.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Selection overlay (border + 8 resize handles + rotate handle)

private enum DesignHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var affectsLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var affectsRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var affectsTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var affectsBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// Unit position within the selection rect (0…1).
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        }
    }
}

private struct DesignSelectionOverlay: View {
    let element: DesignElement
    let scale: CGFloat
    let onBegin: () -> Void
    let onResize: (DesignHandle, CGSize) -> Void   // delta in DOC pixels, element-local axes
    let onRotate: (Double) -> Void                 // absolute degrees
    let onEnd: () -> Void

    @State private var began = false

    var body: some View {
        let w = max(1, element.frame.width * scale)
        let h = max(1, element.frame.height * scale)
        ZStack {
            // The border is display-only — hits pass through to the element below so a selected
            // layer can still be dragged; only the handles capture gestures.
            Rectangle()
                .stroke(element.locked ? BLTheme.sub : BLTheme.gold, lineWidth: 1.2)
                .frame(width: w, height: h)
                .allowsHitTesting(false)
            if element.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
                    .position(x: w - 10, y: 10)
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
            } else {
                ForEach(Array(DesignHandle.allCases.enumerated()), id: \.offset) { _, handle in
                    handleDot
                        .position(x: handle.unit.x * w, y: handle.unit.y * h)
                        .gesture(resizeGesture(handle))
                }
                // Rotate handle floats above the top edge, tethered by a hairline.
                Rectangle().fill(BLTheme.gold.opacity(0.6)).frame(width: 1, height: 18)
                    .position(x: w / 2, y: -9)
                Circle()
                    .fill(BLTheme.bg2)
                    .overlay(Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(BLTheme.gold))
                    .overlay(Circle().stroke(BLTheme.gold, lineWidth: 1.2))
                    .frame(width: 16, height: 16)
                    .position(x: w / 2, y: -22)
                    .gesture(rotateGesture)
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(element.rotation))
        .position(x: element.frame.midX * scale, y: element.frame.midY * scale)
    }

    private var handleDot: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(BLTheme.gold, lineWidth: 1.2))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .contentShape(Circle().inset(by: -6))   // fatter hit target than the visible dot
    }

    private func resizeGesture(_ handle: DesignHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !began { began = true; onBegin() }
                // Local (rotated) axes align with the element's own axes, so the translation maps
                // straight onto width/height changes; divide by scale into DOC pixels.
                onResize(handle, CGSize(width: value.translation.width / scale,
                                        height: value.translation.height / scale))
            }
            .onEnded { _ in
                began = false
                onEnd()
            }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("blmDesignCanvas"))
            .onChanged { value in
                if !began { began = true; onBegin() }
                let center = CGPoint(x: element.frame.midX * scale, y: element.frame.midY * scale)
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
                // The handle sits above the center, so straight-up = 0°.
                let degrees = Double(atan2(dy, dx)) * 180 / .pi + 90
                onRotate(degrees)
            }
            .onEnded { _ in
                began = false
                onEnd()
            }
    }
}

// MARK: - Color row (brand palette swatches + free picker)

private struct DesignColorRow: View {
    let title: String
    @Binding var hex: UInt32
    let palette: [UInt32]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 8) {
                ForEach(palette.prefix(8), id: \.self) { swatch in
                    Button { hex = swatch } label: {
                        Circle().fill(Color(hex: swatch))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white.opacity(hex == swatch ? 0.95 : 0.18),
                                                     lineWidth: hex == swatch ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: "Color #%06X", swatch))
                    .accessibilityAddTraits(hex == swatch ? .isSelected : [])
                }
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(hex: hex) },
                    set: { hex = $0.holoHex }), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("\(title) custom color")
            }
        }
    }
}

// MARK: - Transparent-background checker

private struct DesignCheckerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 10
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(Color.white.opacity(0.07)))
                    }
                    x += cell; col += 1
                }
                y += cell; row += 1
            }
        }
        .background(BLTheme.bg2)
    }
}
#endif // circuit-convert
