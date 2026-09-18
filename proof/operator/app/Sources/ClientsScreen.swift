#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Clients screen: the buyer's structured CLIENT HISTORY and DEAL PIPELINE.
//
// Where Memory holds free-text standing facts, this surfaces the structured records the website
// promises the vault "stores and retrieves": real clients (contacts + notes) and deals that move
// through an explicit pipeline (lead → qualified → proposal → won/lost), every stage change kept
// as real history. HONEST: ships EMPTY, no bundled or invented records — the buyer adds clients
// and deals; the agent can save them on instruction. Everything stays on this device.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct ClientsScreen: View {
    @EnvironmentObject var crm: ClientStore
    @State private var editingClient: Client?       // nil = sheet closed
    @State private var detailClient: Client?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "Clients",
                            subtitle: "Your client history and deal pipeline — stored locally, on your device")
                Spacer()
                StatusPill(text: crm.openDealCount > 0 ? "\(crm.openDealCount) open · \(ClientStore.formatValue(crm.openPipelineValue))" : "No open deals",
                           tint: crm.openDealCount > 0 ? BLTheme.green : BLTheme.sub)
            }.padding(24).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Pipeline snapshot (only when there's something real to show)
                    if !crm.deals.isEmpty {
                        Panel(title: "Pipeline", icon: "chart.line.uptrend.xyaxis") {
                            HStack(spacing: 10) {
                                ForEach(DealStage.allCases) { stage in
                                    stageChip(stage, count: crm.count(in: stage))
                                }
                            }
                        }
                    }

                    // Add a client
                    Panel(title: "Add a client", icon: "person.crop.circle.badge.plus") {
                        HStack {
                            Text("Create a contact, then track deals through your pipeline. Nothing is auto-collected — you enter what you want to remember.")
                                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            GoldButton(label: "New client", icon: "plus") { editingClient = Client() }
                        }
                    }

                    // The roster
                    if crm.clients.isEmpty {
                        EmptyState(icon: "person.crop.rectangle.stack.fill", title: "No clients yet",
                                   hint: "Add a client above to start tracking their history and deal pipeline. The assistant can also look them up when you ask “what's the status of <client>?”")
                            .padding(.top, 30)
                    } else {
                        HStack {
                            Text("\(crm.clients.count) client\(crm.clients.count == 1 ? "" : "s") · \(crm.deals.count) deal\(crm.deals.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                        }
                        VStack(spacing: 10) {
                            ForEach(crm.clients) { c in clientRow(c) }
                        }
                    }
                }.padding(24)
            }
        }
        .sheet(item: $editingClient) { c in
            ClientEditor(client: c).environmentObject(crm).sheetCloseBar()
        }
        .sheet(item: $detailClient) { c in
            ClientDetail(clientID: c.id).environmentObject(crm).sheetCloseBar()
        }
    }

    @ViewBuilder private func stageChip(_ stage: DealStage, count: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(count)").font(BLTheme.mono(18, weight: .bold)).foregroundColor(count > 0 ? stage.tint : BLTheme.sub)
            Text(stage.label.uppercased()).font(BLTheme.mono(8.5, weight: .medium)).foregroundColor(BLTheme.sub).tracking(0.5)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func clientRow(_ c: Client) -> some View {
        let ds = crm.deals(for: c.id)
        let openValue = ds.filter { $0.stage.isOpen }.reduce(0) { $0 + $1.value }
        Button { detailClient = c } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 34, height: 34).background(BLTheme.goldGrad)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.displayName).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    Text(ds.isEmpty ? "No deals yet"
                         : "\(ds.count) deal\(ds.count == 1 ? "" : "s")" + (openValue > 0 ? " · \(ClientStore.formatValue(openValue)) open" : ""))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                if let top = ds.first { StatusPill(text: top.stage.label, tint: top.stage.tint) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
            }
            .padding(14).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Client editor (create / edit a contact)
struct ClientEditor: View {
    @EnvironmentObject var crm: ClientStore
    @Environment(\.dismiss) var dismiss
    @State var client: Client
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(crm.clients.contains(where: { $0.id == client.id }) ? "Edit client" : "New client")
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                field("NAME", text: $client.name, placeholder: "Jane Rivera")
                field("COMPANY", text: $client.org, placeholder: "Harborlight Studios")
                field("EMAIL", text: $client.email, placeholder: "jane@harborlight.com")
                field("PHONE", text: $client.phone, placeholder: "+1 555 0100")
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOTES").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextEditor(text: $client.notes).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).padding(8).frame(height: 90).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
                HStack {
                    if crm.clients.contains(where: { $0.id == client.id }) {
                        Button("Delete", role: .destructive) { crm.deleteClient(client); dismiss() }
                            .buttonStyle(.plain).foregroundColor(BLTheme.danger)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                    GoldButton(label: "Save", icon: "checkmark") {
                        guard client.isValid else { return }
                        crm.upsertClient(client); dismiss()
                    }
                }
            }.padding(24)
        }.keyboardDismissable().sheetWidth(520).background(BLTheme.bg)
    }
    @ViewBuilder private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                .foregroundColor(BLTheme.text).padding(.vertical, 9).padding(.horizontal, 12)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Client detail (profile + deal pipeline; move deals through stages)
struct ClientDetail: View {
    @EnvironmentObject var crm: ClientStore
    let clientID: UUID
    @State private var editing = false
    @State private var addingDeal = false

    private var client: Client? { crm.client(id: clientID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = client {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.displayName).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                            let contact = [c.email, c.phone].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                            if !contact.isEmpty { Text(contact).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        }
                        Spacer()
                        GhostButton(label: "Edit", icon: "pencil") { editing = true }
                    }
                    if !c.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(c.notes).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("DEAL PIPELINE").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Spacer()
                        GoldButton(label: "Add deal", icon: "plus") { addingDeal = true }
                    }

                    let ds = crm.deals(for: c.id)
                    if ds.isEmpty {
                        Text("No deals yet. Add one to start tracking it through the pipeline.")
                            .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    } else {
                        VStack(spacing: 10) { ForEach(ds) { d in dealRow(d) } }
                    }
                } else {
                    Text("This client was removed.").font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }.padding(24)
        }
        .keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
        .sheet(isPresented: $editing) { if let c = client { ClientEditor(client: c).environmentObject(crm).sheetCloseBar() } }
        .sheet(isPresented: $addingDeal) { DealEditor(deal: Deal(clientID: clientID)).environmentObject(crm).sheetCloseBar() }
    }

    @ViewBuilder private func dealRow(_ d: Deal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.displayTitle).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    if d.value > 0 { Text(ClientStore.formatValue(d.value)).font(BLTheme.mono(11, weight: .medium)).foregroundColor(BLTheme.gold) }
                }
                Spacer()
                // Move through the pipeline — every choice writes a real stage-change + audit receipt.
                Menu {
                    ForEach(DealStage.allCases) { s in
                        Button { crm.move(d, to: s) } label: {
                            Label(s.label, systemImage: d.stage == s ? "checkmark" : "")
                        }
                    }
                } label: {
                    StatusPill(text: d.stage.label, tint: d.stage.tint)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if !d.nextAction.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Next: \(d.nextAction)").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            // Stage history trail (real receipts of every move)
            if d.history.count > 1 {
                Text(d.history.compactMap { sc in sc.from.map { "\($0.label)→\(sc.to.label)" } }.joined(separator: "  ·  "))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            HStack {
                Spacer()
                Button(role: .destructive) { crm.deleteDeal(d) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain)
            }
        }
        .padding(14).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// MARK: - Deal editor (create a pipeline opportunity)
struct DealEditor: View {
    @EnvironmentObject var crm: ClientStore
    @Environment(\.dismiss) var dismiss
    @State var deal: Deal
    @State private var valueText = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("New deal").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TITLE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextField("Annual renewal", text: $deal.title).textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                        .foregroundColor(BLTheme.text).padding(.vertical, 9).padding(.horizontal, 12)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("STAGE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Picker("", selection: $deal.stage) {
                        ForEach(DealStage.allCases) { s in Text(s.label).tag(s) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("VALUE (optional)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextField("0", text: $valueText).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .foregroundColor(BLTheme.text).padding(.vertical, 9).padding(.horizontal, 12)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT ACTION (optional)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextField("Send proposal Friday", text: $deal.nextAction).textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                        .foregroundColor(BLTheme.text).padding(.vertical, 9).padding(.horizontal, 12)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                    GoldButton(label: "Save", icon: "checkmark") {
                        guard deal.isValid else { return }
                        deal.value = Double(valueText.filter { $0.isNumber || $0 == "." }) ?? 0
                        crm.upsertDeal(deal); dismiss()
                    }
                }
            }.padding(24)
        }.keyboardDismissable().sheetWidth(520).background(BLTheme.bg)
    }
}
#endif // circuit-convert
