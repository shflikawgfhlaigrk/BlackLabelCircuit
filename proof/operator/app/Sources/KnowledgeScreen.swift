#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Knowledge base: the buyer's private notes + imported documents, with honest
// RAG counts. Documents can be toggled on/off for grounding; the brain retrieves the most
// relevant chunks locally (keyword overlap). A configured external brain receives selected chunks.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

struct KnowledgeScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var activity: ActivityLog
    @State private var tab = 0
    @State private var selectedNote: Note?
    @State private var editingDoc: KnowledgeDoc?
    @State private var search = ""
    // Deep-link highlight: the document a RAG citation chip jumped to — briefly ringed + scrolled in.
    @State private var highlighted: UUID? = nil
    // "Add URL": pull a public web page into Knowledge so it grounds + cites like a file (web RAG).
    @State private var addingURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "Knowledge", subtitle: "Stored locally; selected grounding is sent to a configured external provider when used")
                Spacer()
                if tab == 0 {
                    GoldButton(label: "New note", icon: "plus") { let n = Note(); model.upsert(n); selectedNote = n }
                } else {
                    HStack(spacing: 8) {
                        GhostButton(label: "Add URL", icon: "globe", tint: BLTheme.gold) { addingURL = true }
                        GhostButton(label: "Import", icon: "square.and.arrow.down", tint: BLTheme.gold) { importDoc() }
                        GoldButton(label: "New document", icon: "plus") { let d = KnowledgeDoc(); store.upsertDoc(d); editingDoc = d }
                    }
                }
            }.padding(24).padding(.bottom, 4)

            Picker("", selection: $tab) {
                Text("Notes (\(model.notes.count))").tag(0)
                Text("Documents (\(store.documents.count))").tag(1)
            }.pickerStyle(.segmented).labelsHidden().segmentedWidth(360).padding(.horizontal, 24).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                TextField(tab == 0 ? "Search notes" : "Search documents", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }
            .padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1)).padding(.horizontal, 24).padding(.bottom, 10)

            if tab == 0 { notesList } else { docsList }
        }
        .sheet(item: $selectedNote) { n in NoteEditor(note: n).environmentObject(model).sheetCloseBar() }
        .sheet(item: $editingDoc) { d in DocEditor(doc: d).environmentObject(store).sheetCloseBar() }
        .sheet(isPresented: $addingURL) { AddURLSheet().environmentObject(store).environmentObject(activity).sheetCloseBar() }
        // A RAG citation chip deep-links here: switch to Documents, drop any filter that would
        // hide the cited doc, scroll it into view + ring it. Mirrors the Activity receipt deep-link.
        .onChange(of: nav.knowledgeTarget) { _ in consumeDeepLink() }
        .onAppear { consumeDeepLink() }
    }

    /// Resolve a deep-link target to the doc that should be highlighted, or nil. nonisolated +
    /// static so it is deterministically unit-testable headless (mirrors ChatScreen.citationsVisible).
    /// Returns the target only when it still exists among the buyer’s documents — a citation to a
    /// since-deleted doc must NOT switch tabs or fake a highlight.
    nonisolated static func resolveDeepLink(target: UUID?, docIDs: [UUID]) -> UUID? {
        guard let t = target, docIDs.contains(t) else { return nil }
        return t
    }
    private func consumeDeepLink() {
        guard let id = Self.resolveDeepLink(target: nav.knowledgeTarget, docIDs: store.documents.map { $0.id }) else {
            if nav.knowledgeTarget != nil { nav.knowledgeTarget = nil }  // deleted-doc citation: clear, no fake nav
            return
        }
        tab = 1          // citations are documents, not notes
        search = ""      // drop any filter that could hide the row
        highlighted = id
    }

    // MARK: Notes
    private var filteredNotes: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.notes }
        return model.notes.filter { $0.title.range(of: q, options: .caseInsensitive) != nil || $0.body.range(of: q, options: .caseInsensitive) != nil }
    }
    @ViewBuilder private var notesList: some View {
        if model.notes.isEmpty {
            Spacer(); EmptyState(icon: "note.text", title: "No notes yet", hint: "Capture a thought. Notes can ground the brain when Memory sources are on in Settings."); Spacer()
        } else {
            ScrollView { LazyVStack(spacing: 10) { ForEach(filteredNotes) { n in
                NoteRowView(note: n) { selectedNote = n }.contextMenu { Button("Delete", role: .destructive) { model.deleteNote(n) } }
            } }.padding(.horizontal, 24).padding(.bottom, 24) }
        }
    }

    // MARK: Documents
    private var filteredDocs: [KnowledgeDoc] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.documents }
        return store.documents.filter { $0.name.range(of: q, options: .caseInsensitive) != nil || $0.body.range(of: q, options: .caseInsensitive) != nil }
    }
    @ViewBuilder private var docsList: some View {
        if store.documents.isEmpty {
            Spacer()
            EmptyState(icon: "doc.text.magnifyingglass", title: "No documents yet",
                       hint: "Import or create a document. Enabled documents ground the brain via on-device retrieval — drop one into a chat or run a skill over it.")
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ragSummary
                        ForEach(filteredDocs) { d in docRow(d).id(d.id) }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
                .onChange(of: highlighted) { target in scrollToDoc(target, proxy: proxy) }
                .onAppear { scrollToDoc(highlighted, proxy: proxy) }
            }
        }
    }
    /// Scroll a deep-linked document into view, then fade its ring after a beat. Clears the nav
    /// target so re-entering Knowledge doesn’t re-trigger. Mirrors ActivityScreen.scrollTo.
    private func scrollToDoc(_ target: UUID?, proxy: ScrollViewProxy) {
        guard let id = target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(id, anchor: .center) }
        }
        nav.knowledgeTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.5)) { if highlighted == id { highlighted = nil } }
        }
    }
    private var ragSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile").foregroundColor(BLTheme.gold).font(.system(size: 12))
            Text("\(store.groundedDocCount) of \(store.documents.count) documents · \(store.totalKnowledgeWords) words feed retrieval")
                .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
        }.padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func docRow(_ d: KnowledgeDoc) -> some View {
        let isHot = highlighted == d.id
        HStack(spacing: 14) {
            Image(systemName: "doc.text.fill").font(.system(size: 13, weight: .bold)).foregroundColor(d.enabled ? BLTheme.ink : BLTheme.sub)
                .frame(width: 34, height: 34).background(d.enabled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                if let src = d.sourceURL, let host = URL(string: src)?.host {
                    HStack(spacing: 4) {
                        Image(systemName: "globe").font(.system(size: 9.5)).foregroundColor(BLTheme.gold)
                        Text(host).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    }
                } else {
                    Text(d.preview).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
            }
            Spacer()
            if let src = d.sourceURL, let u = URL(string: src) {
                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.accessibilityLabel("Open source link")
                    .buttonStyle(.plain).help("Open the original page")
            }
            Text("\(d.wordCount)w").font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
            Toggle("", isOn: Binding(get: { d.enabled }, set: { var x = d; x.enabled = $0; store.upsertDoc(x) })).labelsHidden().tint(BLTheme.gold).help("Include in retrieval")
            Button { editingDoc = d } label: { Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Edit document")
        }
        .padding(14).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isHot ? BLTheme.gold : BLTheme.stroke, lineWidth: isHot ? 2 : 1))
        .contextMenu { Button("Delete", role: .destructive) { store.deleteDoc(d) } }
    }

    private func importDoc() {
        let types: [UTType] = [.plainText, .text, .json, .commaSeparatedText, .sourceCode].compactMap { $0 }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        if panel.runModal() == .OK { for url in panel.urls { ingestDoc(url) } }
        #else
        iosImportFiles(contentTypes: types, allowsMultiple: true) { urls in
            for url in urls { ingestDoc(url) }
        }
        #endif
    }
    private func ingestDoc(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        store.upsertDoc(KnowledgeDoc(name: url.lastPathComponent, kind: "imported", body: text))
    }
}

struct DocEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var doc: KnowledgeDoc
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Document").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Name", text: $doc.name, prompt: "Document name")
            if let src = doc.sourceURL, let u = URL(string: src) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                    Text(src).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open original") { NSWorkspace.shared.open(u) }.buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
            }
            Toggle(isOn: $doc.enabled) { Text("Use for retrieval (RAG grounding)").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text("BODY (\(doc.wordCount) words · \(doc.chunks().count) chunks)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $doc.body).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 280).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            HStack {
                Button("Delete", role: .destructive) { store.deleteDoc(doc); dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.danger)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") { store.upsertDoc(doc); dismiss() }
            }
        }.padding(24).keyboardDismissable().sheetWidth(600).background(BLTheme.bg)
    }
}


// MARK: - Add a public web page to Knowledge (multi-source web RAG)
// Fetch a URL (confirmation-gated WebFetch, network.client) and store its readable text as a
// citable KnowledgeDoc(kind:"web"). HONEST: a doc is created ONLY on a real successful fetch;
// a blocked/failed fetch shows the real error and creates nothing. Demo Mode does NOT hit the
// network (ship-no-data / no fabricated page).
struct AddURLSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var activity: ActivityLog
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var demo = DemoMode.shared
    @State private var urlText = ""
    @State private var fetching = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a web page").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Sovereign fetches only the page you name and stores its readable text in local app data. Selected excerpts are sent to the active brain for grounding; a configured external provider processes those excerpts.")
                .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            Field(title: "Page URL", text: $urlText, prompt: "https://example.com/article")

            if demo.active {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(BLTheme.champagne)
                    Text("Live web fetch is off in Demo Mode — sign in to add real pages.").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
            if let e = errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(BLTheme.danger)
                    Text(e).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                if fetching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small).tint(BLTheme.gold); Text("Fetching…").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub) }
                } else {
                    GoldButton(label: "Add to Knowledge", icon: "globe") { add() }
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
        .opacity(demo.active ? 0.96 : 1)
    }

    private func add() {
        if demo.active { errorText = "Live web fetch is off in Demo Mode."; return }
        guard let url = WebKnowledge.normalize(urlText) else {
            errorText = "Enter a valid public web address (https://…)."; return
        }
        errorText = nil; fetching = true
        Task {
            do {
                let r = try await WebFetch.fetch(url)
                let doc = WebKnowledge.makeDoc(from: r)
                await MainActor.run {
                    store.upsertDoc(doc)
                    activity.record(kind: .connector, title: "Added web page to Knowledge",
                                    detail: "\(doc.name) — \(r.url) (\(doc.wordCount) words, \(doc.chunks().count) chunks)",
                                    outcome: .success)
                    fetching = false
                    dismiss()
                }
            } catch {
                let msg = (error as? WebFetch.FetchError)?.message ?? error.localizedDescription
                await MainActor.run {
                    errorText = msg
                    activity.record(kind: .connector, title: "Add web page", detail: "\(url) — \(msg)", outcome: .failure)
                    fetching = false
                }
            }
        }
    }
}
#endif // circuit-convert
