#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Short Links screen (the UI over Sources/Shortlinks.swift).
//
// Branded short links on the buyer's OWN Cloudflare account (free tier) — no link-shortener
// subscription, no Black Label server. This screen is a thin surface over the engine:
//   • unconfigured → an honest setup card that says exactly what one click will create on the
//     buyer's account (Worker + KV namespace + workers.dev URL), then CloudflareShortlinks.provision
//   • provisioned  → create-link form (destination hint: paste from the Campaign Links UTM builder),
//     the link list with copy-short-URL / delete-with-confirm, and a refresh that re-pulls from the
//     buyer's own Worker.
//
// §5.1 HONESTY: every number here is a real pull from the buyer's Worker (or its cached last REAL
// list, labeled with its fetch time). Click counts are surfaced as APPROXIMATE — the Worker's KV
// counters have no atomic increment and can under-count; we say so instead of dressing them up as
// analytics. Empty states never fabricate ("Connect Cloudflare to create short links").
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ShortlinksScreen: View {
    // Connection state — re-read from the engine after every provision/restore/disconnect so the
    // screen and the CRUD paths always agree.
    @State private var provisioned = CloudflareShortlinksConfig.isProvisioned

    // Setup card.
    @State private var accountID = CloudflareShortlinksConfig.accountID
    @State private var apiToken = ""
    @State private var provisioning = false
    @State private var provisionNote = ""

    // Connected card.
    @State private var customDomain = CloudflareShortlinksConfig.customDomain
    @State private var domainNote = ""
    @State private var checkingHealth = false
    @State private var healthNote = ""

    // Create form.
    @State private var destination = ""
    @State private var slug = ""
    @State private var creating = false
    @State private var createNote = ""

    // Links list — seeded from the cached last REAL pull, labeled with its age.
    @State private var cache: ShortlinksCache? = CloudflareShortlinksConfig.lastList
    @State private var refreshing = false
    @State private var listNote = ""
    @State private var pendingDelete: ShortLink? = nil
    @State private var deletingSlug = ""
    @State private var copiedSlug = ""

    private var displayBase: String {
        CloudflareShortlinks.displayBase(workerURL: CloudflareShortlinksConfig.workerURL,
                                         customDomain: CloudflareShortlinksConfig.customDomain)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Short Links",
                             subtitle: "Branded short links that run on your own Cloudflare account (free tier). One click deploys a tiny redirect Worker you own — every link and click counter lives in your account, never on ours.")

                if provisioned {
                    connectionPanel
                    createPanel
                    linksPanel
                } else {
                    setupPanel
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // First visit while connected: pull the real list once (the cache covers relaunches).
            if provisioned && cache == nil { await refreshLinks() }
        }
        .alert("Delete /\(pendingDelete?.slug ?? "")?", isPresented: deleteAlertShown) {
            Button("Delete", role: .destructive) {
                if let link = pendingDelete { pendingDelete = nil; Task { await deleteNow(link) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes the link and its click counter from your Worker — the short URL stops redirecting. The destination page itself is untouched.")
        }
    }

    // MARK: - setup (unconfigured — honest empty state + one-click provision)

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Connect Cloudflare", icon: "link.badge.plus") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect Cloudflare to create short links.")
                        .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("One click provisions two things on YOUR Cloudflare account — both visible (and yours to keep or delete) in your own dashboard:")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    provisionItem(icon: "bolt.horizontal.circle",
                                  name: "Worker “\(CloudflareShortlinksConfig.scriptName)”",
                                  detail: "a tiny redirect script served at https://\(CloudflareShortlinksConfig.scriptName).<your-subdomain>.workers.dev")
                    provisionItem(icon: "externaldrive",
                                  name: "KV namespace “\(CloudflareShortlinksConfig.namespaceTitle)”",
                                  detail: "stores your links and their click counters — your data, in your account")

                    Field(title: "Cloudflare Account ID", text: $accountID,
                          prompt: "32-character hex ID — dashboard → Workers & Pages, right column")
                    SecureRow(title: "Cloudflare API token",
                              prompt: "Paste a token from the “Edit Cloudflare Workers” template") { apiToken = $0 }
                    Text("Create the token at dash.cloudflare.com → My Profile → API Tokens → use the “Edit Cloudflare Workers” template (Workers Scripts: Edit + Workers KV Storage: Edit). Both secrets are stored only in this device's Keychain — never in any file we ship.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        GoldButton(label: provisioning ? "Provisioning…" : "Provision on my Cloudflare", icon: "bolt.fill") {
                            Task { await provisionNow() }
                        }
                        .disabled(provisioning || !canProvision)
                        .opacity((provisioning || !canProvision) ? 0.55 : 1)
                        if provisioning { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                    }
                    if provisioning {
                        Text("Creating the KV namespace, deploying the Worker, enabling the workers.dev route, then waiting for a live health answer — usually 10–30 seconds.")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !provisionNote.isEmpty {
                        Text(provisionNote)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(provisionNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if CloudflareShortlinksConfig.adminNeedsReconnect {
                        Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
                        Text("A saved connection exists, but its Keychain items couldn't be read (this can happen after an app signing change).")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        GhostButton(label: "Restore saved connection", icon: "key") { restoreSavedSecrets() }
                    }
                }
            }

            Panel(title: "Use your own domain", icon: "globe") {
                Text("Links start on your free workers.dev URL. To brand them (e.g. go.acme.com), attach a domain you own in the Cloudflare dashboard — Workers & Pages → \(CloudflareShortlinksConfig.scriptName) → Settings → Domains & Routes → Add custom domain — then enter it here after connecting, and copied links will use it.")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EmptyState(icon: "link",
                       title: "Connect Cloudflare to create short links",
                       hint: "No links exist yet — and we won't invent any. Provision above, then shorten your UTM-tagged campaign URLs into clean branded links.")
                .frame(maxWidth: .infinity)
        }
    }

    private func provisionItem(icon: String, name: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.gold)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(detail).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - connected (worker status + custom domain + local disconnect)

    private var connectionPanel: some View {
        Panel(title: "Your short-link Worker", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    StatusPill(text: "CONNECTED", tint: BLTheme.green)
                    Text(CloudflareShortlinksConfig.workerURL)
                        .font(BLFonts.mono(11.5, weight: .semibold)).foregroundColor(BLTheme.sub)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    GhostButton(label: checkingHealth ? "Checking…" : "Re-check", icon: "arrow.clockwise") {
                        Task { await recheckHealth() }
                    }
                }
                if !healthNote.isEmpty {
                    Text(healthNote)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(healthNote.hasPrefix("Worker live") ? BLTheme.green : BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Copied links start with \(displayBase) — running on your own Cloudflare account.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
                HStack(alignment: .bottom, spacing: 10) {
                    Field(title: "Custom domain (optional)", text: $customDomain, prompt: "go.yourdomain.com")
                    GhostButton(label: "Save domain", icon: "checkmark.circle") { saveDomain() }
                }
                Text("Attach the domain in your Cloudflare dashboard first (Workers & Pages → \(CloudflareShortlinksConfig.scriptName) → Settings → Domains & Routes), then save it here so copied links use it. Saving here changes only which base this app copies — it can't attach the domain for you.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                if !domainNote.isEmpty {
                    Text(domainNote)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
                HStack(spacing: 10) {
                    GhostButton(label: "Disconnect", icon: "xmark.circle", tint: BLTheme.danger) { disconnect() }
                    Text("Removes the token, secret, and cached list from this device only — the Worker, KV data, and your live links stay exactly where they are, on your Cloudflare account.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - create form

    private var slugTyped: String { slug.trimmingCharacters(in: .whitespaces) }
    private var slugInvalid: Bool { !slugTyped.isEmpty && !CloudflareShortlinks.isValidSlug(slugTyped) }
    private var canCreate: Bool {
        !destination.trimmingCharacters(in: .whitespaces).isEmpty && !slugInvalid && !creating
    }

    private var createPanel: some View {
        Panel(title: "Create a short link", icon: "plus.circle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Field(title: "Destination URL", text: $destination,
                      prompt: "https://… — paste a tracked link from the Campaign Links UTM builder",
                      onSubmit: { if canCreate { Task { await createNow() } } })
                Text("Tip: build the destination in Campaign Links first (UTM source/medium/campaign), then shorten it here so every post carries one clean branded link.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .bottom, spacing: 10) {
                    Field(title: "Custom slug (optional)", text: $slug,
                          prompt: "leave blank for a random slug",
                          onSubmit: { if canCreate { Task { await createNow() } } })
                    GoldButton(label: creating ? "Creating…" : "Create short link", icon: "link.badge.plus") {
                        Task { await createNow() }
                    }
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.55)
                }
                if slugInvalid {
                    Text("Slugs are 1–64 characters of a-z, 0-9, - or _, starting with a letter or digit (and not “api”).")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !createNote.isEmpty {
                    Text(createNote)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(createNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - links list

    private var linksPanel: some View {
        Panel(title: "Your links", icon: "list.bullet") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let cache {
                        Text("Last real pull \(cache.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                    if refreshing { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                    GhostButton(label: refreshing ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") {
                        Task { await refreshLinks() }
                    }
                }
                if !listNote.isEmpty {
                    Text(listNote)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(listNote.hasPrefix("Pulled") || listNote.hasPrefix("Deleted") ? BLTheme.green : BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let links = cache?.links, !links.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(links) { link in
                            linkRow(link)
                            if link.id != links.last?.id {
                                Rectangle().fill(BLTheme.stroke).frame(height: 1)
                            }
                        }
                    }
                    Text("Click counts are approximate — the Worker's KV counters are eventually consistent and can under-count simultaneous clicks, and 301 redirects may be cached by browsers. Treat them as a directional signal, not analytics.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyState(icon: "link",
                               title: "No short links yet",
                               hint: "Create your first link above — paste a UTM-tagged URL from the Campaign Links builder and it becomes \(displayBase)/your-slug.")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func linkRow(_ link: ShortLink) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("/" + link.slug)
                    .font(BLFonts.mono(13, weight: .bold)).foregroundStyle(BLTheme.goldText)
                Text(link.url)
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("≈ \(link.clicks) click\(link.clicks == 1 ? "" : "s")")
                .font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.sub)
                .help("Approximate — KV counters are eventually consistent and can under-count.")
            if copiedSlug == link.slug {
                Text("Copied")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                    .frame(width: 56)
            } else {
                IconButton(system: "doc.on.doc", accessibilityText: "Copy short URL") { copyShortURL(link) }
            }
            if deletingSlug == link.slug {
                ProgressView().controlSize(.small).tint(BLTheme.gold).frame(width: 28)
            } else {
                IconButton(system: "trash", tint: BLTheme.danger, accessibilityText: "Delete link") {
                    pendingDelete = link
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - actions (thin wrappers over the engine; every note is the engine's own detail)

    private var canProvision: Bool {
        !accountID.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var deleteAlertShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func provisionNow() async {
        provisioning = true
        provisionNote = ""
        let result = await CloudflareShortlinks.provision(token: apiToken, accountID: accountID)
        provisioning = false
        provisioned = CloudflareShortlinksConfig.isProvisioned
        provisionNote = (result.ok ? "✓ " : "") + result.detail
        if result.ok {
            apiToken = ""
            accountID = CloudflareShortlinksConfig.accountID
            healthNote = ""
            await refreshLinks()
        }
    }

    private func restoreSavedSecrets() {
        if CloudflareShortlinksConfig.migrateSavedSecrets() {
            provisioned = CloudflareShortlinksConfig.isProvisioned
            provisionNote = provisioned
                ? "✓ Saved connection restored from the Keychain."
                : "Secrets migrated, but the connection still isn't complete — provision again."
        } else {
            provisionNote = "Couldn't read the saved secrets — provision again to rotate them (existing links keep working)."
        }
    }

    private func recheckHealth() async {
        checkingHealth = true
        healthNote = ""
        let result = await CloudflareShortlinks.verifyHealth(workerURL: CloudflareShortlinksConfig.workerURL,
                                                             secret: CloudflareShortlinksConfig.adminSecret ?? "")
        checkingHealth = false
        healthNote = result.detail
    }

    private func saveDomain() {
        CloudflareShortlinksConfig.customDomain = customDomain
        customDomain = CloudflareShortlinksConfig.customDomain
        domainNote = customDomain.isEmpty
            ? "Custom domain cleared — copied links use the workers.dev URL."
            : "Saved — copied links now start with \(displayBase)."
    }

    private func disconnect() {
        CloudflareShortlinksConfig.clearLocal()
        provisioned = CloudflareShortlinksConfig.isProvisioned
        cache = nil
        customDomain = ""
        apiToken = ""
        provisionNote = ""
        healthNote = ""
        domainNote = ""
        createNote = ""
        listNote = ""
    }

    private func refreshLinks() async {
        refreshing = true
        listNote = ""
        let result = await CloudflareShortlinks.listLinks()
        refreshing = false
        // listLinks caches the REAL list on success; re-read so the screen shows exactly what it saved.
        if result.links != nil { cache = CloudflareShortlinksConfig.lastList }
        listNote = result.detail
    }

    private func createNow() async {
        creating = true
        createNote = ""
        let chosen = slugTyped.isEmpty ? CloudflareShortlinks.randomSlug() : slugTyped
        let result = await CloudflareShortlinks.createLink(slug: chosen, destination: destination)
        creating = false
        if let link = result.link {
            // Merge the Worker-confirmed link into the cached list ourselves — KV list reads are
            // eventually consistent, so an immediate re-pull could honestly miss the new link.
            var links = cache?.links ?? []
            links.removeAll { $0.slug == link.slug }
            links.insert(link, at: 0)
            CloudflareShortlinksConfig.saveList(links)
            cache = CloudflareShortlinksConfig.lastList
            let short = CloudflareShortlinks.shortURL(base: displayBase, slug: link.slug)
            copyToClipboard(short)
            createNote = "✓ \(result.detail) Copied \(short) to the clipboard."
            destination = ""
            slug = ""
        } else {
            createNote = result.detail
        }
    }

    private func deleteNow(_ link: ShortLink) async {
        deletingSlug = link.slug
        let result = await CloudflareShortlinks.deleteLink(slug: link.slug)
        deletingSlug = ""
        if result.ok {
            var links = cache?.links ?? []
            links.removeAll { $0.slug == link.slug }
            CloudflareShortlinksConfig.saveList(links)
            cache = CloudflareShortlinksConfig.lastList
        }
        listNote = result.detail
    }

    private func copyShortURL(_ link: ShortLink) {
        let short = CloudflareShortlinks.shortURL(base: displayBase, slug: link.slug)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(short, forType: .string)
        copiedSlug = link.slug
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedSlug == link.slug { copiedSlug = "" }
        }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
#endif // circuit-convert
