#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Prompt Library screen. A searchable, category-filtered collection of reusable
// prompts. Click "Use" to drop a prompt straight into The Brain composer (also reachable from
// ⌘K). Built-ins ship as starters; the buyer adds, edits, pins, and organizes their own. Every
// value is the buyer's own — nothing fabricated, no personal data baked in.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct PromptsScreen: View {
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var category: PromptCategory? = nil
    @State private var editing: SavedPrompt?
    @State private var copiedID: UUID?

    private var results: [SavedPrompt] { prompts.view(query: query, category: category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Click/⌘K are pointer+keyboard affordances; the touch shell uses tap + Search.
                #if os(macOS)
                ScreenTitle(title: "Prompts", subtitle: "Your reusable prompt library — drop any into The Brain with one click or ⌘K")
                #else
                ScreenTitle(title: "Prompts", subtitle: "Your reusable prompt library — drop any into The Brain with one tap or Search")
                #endif
                Spacer()
                GoldButton(label: "New prompt", icon: "plus") {
                    editing = SavedPrompt(title: "", body: "", category: category ?? .custom)
                }
            }.padding(24).padding(.bottom, 4)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                TextField("Search prompts, tags…", text: $query).textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }
            .padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1)).padding(.horizontal, 24).padding(.bottom, 10)

            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    catChip("All", icon: "square.grid.2x2", on: category == nil) { category = nil }
                    ForEach(prompts.categoriesInUse) { c in
                        catChip(c.label, icon: c.icon, on: category == c) { category = (category == c ? nil : c) }
                    }
                }.padding(.horizontal, 24)
            }.padding(.bottom, 12)

            if results.isEmpty {
                Spacer()
                EmptyState(icon: "text.book.closed.fill",
                           title: query.isEmpty ? "No prompts in this view" : "No matches",
                           hint: query.isEmpty ? "Create a reusable prompt, or pick a built-in starter. Use any prompt to drop it into The Brain." : "Try a different search or clear the filter.")
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(results) { p in promptCard(p) }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .sheet(item: $editing) { p in PromptEditor(prompt: p).environmentObject(prompts).sheetCloseBar() }
    }

    @ViewBuilder private func catChip(_ label: String, icon: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundColor(on ? BLTheme.ink : BLTheme.sub)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func promptCard(_ p: SavedPrompt) -> some View {
        HoloCard(cornerRadius: 16, sweep: p.pinned, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: p.category.icon).font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 34, height: 34).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: BLTheme.goldGlow, radius: 5, y: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title.isEmpty ? "Untitled prompt" : p.title).font(.system(size: 14.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(p.category.label).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                            if p.useCount > 0 { Text("· used \(p.useCount)×").font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        }
                    }
                    Spacer()
                    if p.builtIn { FoilBadge(text: "Built-in") }
                }
                Text(p.body).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !p.tags.isEmpty {
                    HStack(spacing: 5) { ForEach(p.tags.prefix(4), id: \.self) { t in
                        Text("#\(t)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.sub)
                            .padding(.vertical, 2).padding(.horizontal, 6).background(BLTheme.bg2).clipShape(Capsule())
                    } }
                }
                HStack(spacing: 8) {
                    GoldButton(label: copiedID == p.id ? "Sent to Brain" : "Use", fill: true, icon: copiedID == p.id ? "checkmark" : "arrow.up.right") { use(p) }
                    Button { prompts.togglePin(p) } label: {
                        Image(systemName: p.pinned ? "pin.fill" : "pin").font(.system(size: 12)).foregroundColor(p.pinned ? BLTheme.gold : BLTheme.sub)
                    }.buttonStyle(.plain).help(p.pinned ? "Unpin" : "Pin")
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.body, forType: .string) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain).help("Copy prompt text")
                    if !p.builtIn {
                        Menu {
                            Button("Edit") { editing = p }
                            Button("Delete", role: .destructive) { prompts.delete(p) }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Prompt actions")
                    } else {
                        Button { editing = SavedPrompt(title: p.title + " (copy)", body: p.body, category: p.category, tags: p.tags) } label: {
                            Image(systemName: "square.on.square").font(.system(size: 12)).foregroundColor(BLTheme.sub)
                        }.buttonStyle(.plain).help("Duplicate to edit")
                    }
                }
            }
        }
    }

    private func use(_ p: SavedPrompt) {
        prompts.recordUse(p)
        store.ensureActiveConversation()
        NotificationCenter.default.post(name: .sovInsertPrompt, object: p.body)
        nav.go(.brain)
    }
}

// MARK: - Create / edit a prompt
struct PromptEditor: View {
    @EnvironmentObject var prompts: PromptLibrary
    @Environment(\.dismiss) var dismiss
    @State var prompt: SavedPrompt
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title.isEmpty ? "New prompt" : "Edit prompt").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Title", text: $prompt.title, prompt: "e.g. Draft a project update")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CATEGORY").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Picker("", selection: $prompt.category) { ForEach(PromptCategory.allCases) { Text($0.label).tag($0) } }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $prompt.body).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 150).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            // Tags
            VStack(alignment: .leading, spacing: 6) {
                Text("TAGS").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                HStack(spacing: 8) {
                    TextField("add a tag, press return", text: $tagText)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 7).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                        .onSubmit(addTag)
                    GhostButton(label: "Add", icon: "plus", tint: BLTheme.gold) { addTag() }
                }
                if !prompt.tags.isEmpty {
                    HStack(spacing: 6) { ForEach(prompt.tags, id: \.self) { t in
                        HStack(spacing: 4) {
                            Text("#\(t)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.text)
                            Button { prompt.tags.removeAll { $0 == t } } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Remove tag")
                        }.padding(.vertical, 3).padding(.horizontal, 8).background(BLTheme.bg2).clipShape(Capsule())
                    } }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save prompt", icon: "checkmark") {
                    guard !prompt.title.trimmingCharacters(in: .whitespaces).isEmpty,
                          !prompt.body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    if prompts.custom.contains(where: { $0.id == prompt.id }) { prompts.update(prompt) } else { prompts.add(prompt) }
                    dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }

    private func addTag() {
        let t = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "")
        guard !t.isEmpty, !prompt.tags.contains(t) else { tagText = ""; return }
        prompt.tags.append(t); tagText = ""
    }
}
#endif // circuit-convert
