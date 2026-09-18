// Black Label Marketing — Delivery dashboard (MK-21).
//
// The honest-metrics panel. EVERY number here is a real count over the on-device activity log (the
// send-of-record) via DeliveryMetrics — sends, replies, and bounces the app actually recorded. There
// is no open-rate: Marketing carries no open/click pixel tracking (the MK-14 floor), so an open is
// not something we can honestly measure, and we say so in plain language instead of painting a
// fabricated number. Nothing is estimated, projected, or sampled.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct DeliveryDashboard: View {
    @EnvironmentObject var model: AppModel

    private var metrics: DeliveryMetrics { DeliveryMetrics.from(activities: model.activities) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The explicit honesty frame — the whole point of this panel.
                Panel(title: "Delivery", icon: "paperplane.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("We only show what actually happened.")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                        Text("Every number below is a real count from this device's send log — emails your app actually sent, and the replies and bounces it recorded from your own mailbox. Nothing here is estimated or projected.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if metrics.isEmpty {
                    // Honest empty state — no zeros dressed up as performance.
                    Panel(title: "No sends yet", icon: "tray") {
                        Text("Once you send your first campaign from your own mailbox, your real delivery numbers appear here — sent, replied, and bounced. Until then there's nothing to report, and we won't invent it.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Panel(title: "What actually happened", icon: "chart.bar.fill") {
                        VStack(spacing: 0) {
                            ForEach(metrics.rows) { row in
                                HStack {
                                    Text(row.label)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.sub)
                                    Spacer()
                                    Text(row.value)
                                        .font(BLFonts.mono(18, weight: .bold))
                                        .foregroundStyle(BLTheme.goldText)
                                }
                                .padding(.vertical, 9)
                                if row.id != metrics.rows.last?.id {
                                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                }
                            }
                        }
                    }
                }

                // Opens are deliberately not shown — the honest note that replaces a fake open-rate.
                Panel(title: "About opens", icon: "eye.slash") {
                    Text("We don't track email opens. Open tracking works by embedding an invisible tracking pixel in every message — it hurts deliverability and quietly reports your recipients' behavior. We don't do it, so we don't show an open rate. Replies are the honest signal, and those are counted above.")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif // circuit-convert
