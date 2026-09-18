import Foundation

enum AppBrand {
    static var displayName: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value! : "Black Label Marketing"
    }

    static var authSubtitle: String {
        if Bundle.main.bundleIdentifier == "com.blacklabel.leads" {
            return "Lead database, CRM sync, outreach, and pipeline."
        }
        return "Promo reels, landing pages, email, and leads — from your own brand."
    }

    static var publishActivityType: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").publish"
    }

    /// Interaction verb for shared UI copy: pointer on the Mac, touch on iOS. Interpolate this
    /// instead of hardcoding "tap"/"click" in strings both platforms render.
    #if os(macOS)
    static let tapVerb = "click"
    #else
    static let tapVerb = "tap"
    #endif
}
