// Black Label Marketing — the social-platform identity + its CONSENT MAPPING.
//
// WHY THIS IS ITS OWN FILE: `SocialPlatform.transmissionProvider` is the mapping that decides
// which recorded consent the publish chokepoint checks before a caption, an image or a video
// leaves the device. It used to live inside Social.swift, which pulls in SwiftUI/AppKit and so
// cannot be compiled by the headless suite — the test therefore compiled a HAND-COPIED duplicate
// of the mapping in Tests/_posting_shim.swift. A copy proves nothing: the real mapping could have
// been re-pointed (x → .linkedin, or a platform → a provider with no disclosure) and every suite
// would still have passed.
//
// The declaration now lives here, Foundation-only, so Tests/SocialPostingClientTests.swift
// compiles the SHIPPED enum and the SHIPPED mapping. There is no second copy to keep in sync.
// Presentation-layer extensions (SwiftUI colors, the connect sheet, tokens) stay in Social.swift.
import Foundation

// MARK: - Platforms

enum SocialPlatform: String, CaseIterable, Identifiable, Codable {
    case instagram = "Instagram", x = "X", tiktok = "TikTok",
         linkedin = "LinkedIn", facebook = "Facebook", threads = "Threads", youtube = "YouTube",
         pinterest = "Pinterest"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .instagram: return "camera.fill"
        case .x:         return "xmark"
        case .tiktok:    return "music.note"
        case .linkedin:  return "briefcase.fill"
        case .facebook:  return "f.cursive.circle.fill"
        case .threads:   return "at"
        case .youtube:   return "play.rectangle.fill"
        case .pinterest: return "pin.fill"
        }
    }
    /// The consent identity for this platform (see Sources/ProviderConsent.swift). Lives here so
    /// adding a platform is a compile error until its transmission disclosure exists.
    var transmissionProvider: TransmissionProvider {
        switch self {
        case .x:         return .x
        case .linkedin:  return .linkedin
        case .facebook:  return .facebook
        case .instagram: return .instagram
        case .threads:   return .threads
        case .youtube:   return .youtube
        case .tiktok:    return .tiktok
        case .pinterest: return .pinterest
        }
    }
    /// Real, documented public bio character limits.
    var bioLimit: Int {
        switch self {
        case .instagram: return 150
        case .x:         return 160
        case .tiktok:    return 80
        case .linkedin:  return 220
        case .facebook:  return 101
        case .threads:   return 150
        case .youtube:   return 1000
        case .pinterest: return 500
        }
    }
    var likesHashtags: Bool {
        switch self { case .instagram, .tiktok, .threads: return true; default: return false }
    }
    /// Where the buyer creates their own API credential, shown honestly in the connect sheet.
    var devPortal: String {
        switch self {
        case .instagram, .facebook, .threads: return "developers.facebook.com"
        case .x:        return "developer.x.com"
        case .tiktok:   return "developers.tiktok.com"
        // developer.linkedin.com is documentation only — the apps themselves live on linkedin.com.
        case .linkedin: return "linkedin.com/developers"
        case .youtube:  return "console.cloud.google.com"
        case .pinterest: return "developers.pinterest.com"
        }
    }

    /// The EXACT page where this network's API credential is created.
    ///
    /// WHY THIS IS NOT `https://<devPortal>`: every one of these portals answers its bare domain
    /// with a marketing/documentation home that has no path to an App ID — the buyer is dropped on
    /// "build with our platform" and has to go hunting. developer.linkedin.com is the worst case:
    /// it is a docs site, and the apps live on a different host entirely. So the connect sheet
    /// links HERE, at the app list / credential surface itself.
    ///
    /// Signed-out these resolve to the provider's own sign-in with a return link back to this page
    /// (Meta, X, Google) or straight to the surface (LinkedIn, Pinterest); TikTok answers 401 until
    /// you are signed in. Verified 2026-08-12 — none is a 404 and none is a marketing page.
    var credentialURL: URL {
        switch self {
        // Meta family (Instagram/Threads publish through a Facebook app): the App ID + secret live
        // on an app's Basic Settings, which only exists once an app does — so this lands on the app
        // LIST, which carries the Create button and every existing app's settings.
        case .instagram, .facebook, .threads: return URL(string: "https://developers.facebook.com/apps/")!
        case .x:         return URL(string: "https://developer.x.com/en/portal/dashboard")!
        case .tiktok:    return URL(string: "https://developers.tiktok.com/apps/")!
        case .linkedin:  return URL(string: "https://www.linkedin.com/developers/apps")!
        // YouTube publishes through a Google Cloud OAuth client — the credentials page, not the
        // console root, which opens on whatever project dashboard was last viewed.
        case .youtube:   return URL(string: "https://console.cloud.google.com/apis/credentials")!
        case .pinterest: return URL(string: "https://developers.pinterest.com/apps/")!
        }
    }

    /// What the buyer is looking for once `credentialURL` opens — named in the button and the note
    /// so the destination is not a mystery before they click.
    var credentialPageName: String {
        switch self {
        case .instagram, .facebook, .threads: return "Meta app list (My Apps)"
        case .x:         return "X developer portal dashboard"
        case .tiktok:    return "TikTok Manage apps"
        case .linkedin:  return "LinkedIn My apps"
        case .youtube:   return "Google Cloud → APIs & Services → Credentials"
        case .pinterest: return "Pinterest developer apps"
        }
    }
    var accountHomeURL: URL {
        switch self {
        case .instagram: return URL(string: "https://instagram.com")!
        case .x:         return URL(string: "https://x.com")!
        case .tiktok:    return URL(string: "https://tiktok.com")!
        case .linkedin:  return URL(string: "https://linkedin.com")!
        case .facebook:  return URL(string: "https://facebook.com")!
        case .threads:   return URL(string: "https://threads.net")!
        case .youtube:   return URL(string: "https://youtube.com")!
        case .pinterest: return URL(string: "https://pinterest.com")!
        }
    }
    /// The public profile URL prefix (handle appended) — used to open/verify the real profile.
    func profileURL(handle: String) -> String? {
        let h = handle.trimmingCharacters(in: CharacterSet(charactersIn: " @"))
        guard !h.isEmpty else { return nil }
        switch self {
        case .instagram: return "https://instagram.com/\(h)"
        case .x:         return "https://x.com/\(h)"
        case .tiktok:    return "https://tiktok.com/@\(h)"
        case .linkedin:  return "https://linkedin.com/in/\(h)"
        case .facebook:  return "https://facebook.com/\(h)"
        case .threads:   return "https://threads.net/@\(h)"
        case .youtube:   return "https://youtube.com/@\(h)"
        case .pinterest: return "https://pinterest.com/\(h)"
        }
    }
}
