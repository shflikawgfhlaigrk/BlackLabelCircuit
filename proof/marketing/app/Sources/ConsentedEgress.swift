// Black Label Marketing — THE outbound egress choke point.
//
// THE INVARIANT THIS FILE EXISTS TO MAKE TRUE:
//
//     EXACTLY ONE FILE IN Sources/ MAY CONSTRUCT OR USE A NETWORK TRANSPORT — THIS ONE.
//
// Not "one file may name a registered host next to a socket". Not "one file may own a socket
// unless it also mentions a URL we recognise". The socket ITSELF is the violation, everywhere
// else, unconditionally. Tests/outbound-host-registry-contract.sh enforces that by PARSING every
// Swift file in Sources/ (swiftc -dump-parse, not a regex) and failing any transport reference
// outside this file.
//
// WHY THE RULE HAD TO BECOME UNCONDITIONAL. Three arrangements were defeated by independent
// verification, each one a smaller version of the same mistake — asking a *conjunction* to hold a
// gate shut:
//
//   • SEMANTIC BYPASS — the gate was a line at every call site,
//     `if let refusal = TransmissionConsentStore.refusal(for: provider) { … }`, checked by a grep.
//     Changing it to `if false, let refusal = …` left the grepped string in place, in the right
//     position, with its `continue` intact. Everything stayed green while the buyer's typed search
//     went to both Overpass operators in defiance of an explicit refusal.
//   • REGISTRY ≠ GATING — a brand-new host added as a live URLSession POST, with a real provider
//     case, real hosts, a real disclosure and a ledger entry, but no consent check, also passed.
//   • THE SPLIT-FILE BYPASS (N1) — the guard then failed a file that owned a socket AND named a
//     registered host. Two files defeat it: `VendorTransport.swift` owns the socket and names no
//     host; `LeadExfilLane.swift` names api.hubapi.com and owns no socket, and calls the first.
//     Neither trips either half of the conjunction. Buyer lead records shipped, exit 0. The same
//     conjunction also lost to an interpolated host (`"https://\(a).\(b)"`), which no regex sees.
//
// Splitting a violation across files, or hiding a hostname behind interpolation, no longer helps:
// there is no host half of the rule left to dodge. A file that owns a socket fails, full stop.
//
// THE DEFAULTS ARE ALL REFUSALS. A caller that supplies no provider is refused. A caller whose URL
// points at a host the provider's registry entry does not authorise is refused. A provider with no
// current grant is refused. Nothing "falls through" to allowed.
//
// The socket lives behind `OutboundTransport` so the refusal path is provable at RUNTIME
// (Tests/EgressChokePointTests.swift drives the real finders with a recording transport and
// asserts zero requests were issued). That test — not a grep — is the primary defence.
//
// A NOTE ON `URLRequest`. Building a URLRequest is deliberately NOT treated as a transport
// reference. A URLRequest is an inert value: it cannot move a byte, and this file's entire API
// takes one as its parameter, so banning it outside this file would ban every caller of the choke
// point. What the guard bans is the thing that can actually transmit. A request built anywhere can
// only ever reach the wire through a door below.
import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - the socket, behind a seam

/// The only thing in this app that is allowed to actually move bytes for a consent-requiring lane.
/// A protocol rather than a direct `URLSession` call so a test can observe real behaviour — what
/// was sent, and whether anything was sent at all — instead of reading source text.
protocol OutboundTransport {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production transport. This is the ONLY `URLSession` in Sources/. `session` is injectable so the
/// lanes whose suites drive a stubbed URLSession keep working — a test constructs
/// `URLSessionTransport(session: stub)` from Tests/, where the sole-socket rule does not apply,
/// and the consent decision still happens above this line either way.
struct URLSessionTransport: OutboundTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - what kind of URL is being sent to

/// How the destination URL was obtained. This exists because two lanes legitimately POST to a URL
/// this app did not choose.
enum EgressDestination: Equatable {
    /// The normal case: the URL is a literal this app picked, so its host MUST appear in the
    /// provider's registry entry. An unrecognised host is refused, never allowed.
    case registeredHost
    /// The URL was issued BY the already-consented provider in a prior authorised response —
    /// YouTube's resumable-upload `Location` header and TikTok's `upload_url`, both of which point
    /// at a per-upload host this app cannot know in advance. Consent for the provider is still
    /// required; only the host-registry check is skipped, because there is no host to register.
    /// Tests/outbound-host-registry-contract.sh counts every use of this case.
    case providerIssuedUploadURL
}

// MARK: - the declared allowlist: egress that is genuinely not consent-bearing

/// THE ALLOWLIST. Not every byte this app sends is a transmission of buyer content to a partner
/// this app chose — an update check is not, and neither is the loopback socket that catches an
/// OAuth redirect. Those lanes must not be hidden by loosening the sole-socket rule, so they are
/// named here instead, one case each, with a written justification and the exact call sites they
/// are allowed to appear at.
///
/// EVERY PROPERTY BELOW IS READ BY THE GUARD. It asserts the exact number of cases, the exact
/// number of pinned sites, that every justification is real prose, that every pinned
/// `File.swift:symbol` exists in Sources/, and that a file which calls an ungated door is pinned
/// for the lane it passes. Growing this list is therefore impossible without the diff showing it.
///
/// AND THE DOOR ITSELF REFUSES. `sendUngated` throws if the destination host belongs to ANY
/// `TransmissionProvider` — so the ungated door can never be used to reach a registered host, no
/// matter which lane is claimed. That check runs at runtime, on the real URL, after interpolation.
enum UngatedEgressLane: String, CaseIterable {
    /// The buyer's OWN account at a service they connected, reached with their own credential to
    /// read or send their own data.
    case ownAccountAPI
    /// The identity/token endpoint of an account the buyer is connecting or disconnecting.
    case oauthTokenExchange
    /// A URL the buyer typed or pasted, fetched because they asked for it.
    case userDirectedFetch
    /// Black Label's own update feed and the signed archive it points at.
    case firstPartyUpdateFeed
    /// The mail host the buyer typed, over SMTP/IMAP, with the buyer's own credentials.
    case buyerMailServer
    /// The 127.0.0.1 listener that catches an OAuth redirect. Receives; transmits nothing.
    case loopbackOAuthCallback
    /// A DNS record lookup through the system resolver.
    case dnsRecordLookup

    /// Why this lane does not carry a consent decision. Written to be read by a reviewer who is
    /// deciding whether the exemption is honest, not to reassure them.
    var why: String {
        switch self {
        case .ownAccountAPI:
            return "The buyer's own account at a service they explicitly connected (Cloudflare, "
                 + "Gmail/Microsoft Graph, Google Analytics), reached with the credential they "
                 + "supplied, to read or send THEIR OWN data. The act of connecting the account is "
                 + "the authorization, and the destination is the account holder themselves — not a "
                 + "partner this app selected on their behalf. These hosts are classified "
                 + "'own-account-api' in Tests/outbound-hosts.json and declared in PrivacyInfo.xcprivacy."
        case .oauthTokenExchange:
            return "An authorization code, refresh token or revocation request going to the identity "
                 + "endpoint of the account being connected or disconnected. It carries the OAuth "
                 + "client id and a token that provider itself issued, and nothing else: no lead, "
                 + "contact, message, file or customer record. Gating it would also block "
                 + "DISCONNECTION, which must never be refused. What the resulting token is then "
                 + "used FOR is gated separately (searchConsole, youtube and the social providers "
                 + "all go through the consent door)."
        case .userDirectedFetch:
            return "A GET of a URL the buyer typed or pasted into the field that triggers it — their "
                 + "own site for the SEO audit and the brand-kit importer, a media link for the "
                 + "reference reel. The destination is the buyer's own instruction, and the only "
                 + "thing that leaves is the request for the page they asked to see. Classified "
                 + "'user-directed-fetch' in Tests/outbound-hosts.json."
        case .firstPartyUpdateFeed:
            return "Black Label's own update manifest and the signed archive it names, plus the "
                 + "public live.json this app's own site publishes. They send a build number and a "
                 + "user-agent; no buyer content, no credential, no identifier. Refusing an update "
                 + "check would leave a buyer stranded on a build with a known defect, which is a "
                 + "worse outcome for them than the check itself."
        case .buyerMailServer:
            return "SMTP/IMAP to the mail host the buyer typed, authenticated with the buyer's own "
                 + "mailbox credentials, at their explicit press of Send or Check. The message and "
                 + "its recipients are going to the buyer's own mail provider — the same place the "
                 + "message would go from Mail.app — not to a third party this app introduced. No "
                 + "host literal exists in Sources/ for these lanes; the buyer supplies it."
        case .loopbackOAuthCallback:
            return "A short-lived listener bound to 127.0.0.1 only, which ACCEPTS the browser's "
                 + "OAuth redirect and writes a local success page back to it. It is the receiving "
                 + "end of a socket, not a transmitting one: nothing leaves the device through it, "
                 + "and it is bound so it cannot accept traffic from the network at all."
        case .dnsRecordLookup:
            return "An MX/A record lookup through the system resolver, so the deliverability gate can "
                 + "tell the buyer whether a recipient domain actually accepts mail before they send "
                 + "to it. It is listed here rather than ignored because a resolver query IS egress: "
                 + "the recipient's DOMAIN (never the local part, never the message) reaches whichever "
                 + "resolver the machine is configured to use — the same lookup any mail client makes. "
                 + "It carries no credential and no buyer content, and it cannot address an arbitrary "
                 + "host: the API takes a domain and a record type, not a URL."
        }
    }

    /// `File.swift:symbol` — the exact declarations allowed to use this lane. The guard resolves
    /// every one against the parsed source, and fails any file that uses a door it is not pinned
    /// for. A new call site cannot appear without a line here.
    var pinnedSites: [String] {
        switch self {
        case .ownAccountAPI:
            return ["CloudflareAnalytics.swift:resolveZoneTag",
                    "CloudflareAnalytics.swift:pull",
                    "CloudflareEmail.swift:verifyCompatibility",
                    "CloudflareEmail.swift:send",
                    "EmailOAuth.swift:validate",
                    "EmailOAuth.swift:perform",
                    "GA4Analytics.swift:performPull",
                    "Shortlinks.swift:createOrFindNamespace",
                    "Shortlinks.swift:uploadWorker",
                    "Shortlinks.swift:enableWorkersDev",
                    "Shortlinks.swift:verifyHealth",
                    "Shortlinks.swift:listLinks",
                    "Shortlinks.swift:createLink",
                    "Shortlinks.swift:deleteLink",
                    "main.swift:validateEmailAPIToken",
                    "main.swift:connectEmailAPIFromJSON"]
        case .oauthTokenExchange:
            return ["AccountDeletionRunner.swift:revokeGoogleGrant",
                    "EmailOAuth.swift:exchange",
                    "GA4Analytics.swift:refreshCredential",
                    "GA4OAuth.swift:exchange",
                    "SocialAuth.swift:exchange",
                    "SocialAuth.swift:userInfo",
                    "main.swift:connectGoogleIdentityFromJSON"]
        case .userDirectedFetch:
            return ["BrandKitLive.swift:liveFetcher",
                    "BrandProfiler.swift:profileSite",
                    "ReferenceReelEngine.swift:embeddedVideoURL",
                    "ReferenceReelEngine.swift:loadRemote",
                    "RemoteMusicLoader.swift:load",
                    "SEOEngine.swift:audit"]
        // The two conditional lanes below name their slice-independent sites UNCONDITIONALLY and
        // let `#if` add to them. A case body made only of `#if`/`#else` reads fine but breaks both
        // things that check this list: the guard parses each `#if` branch as its own variant with
        // the other conditional regions blanked, which left these cases with an empty body and
        // failed the whole file to parse (taking the choke-point checks down with it); and the pin
        // COUNT is harvested from this text, so a site repeated across both branches was counted
        // twice. Neither slice's resulting set changes here — only the shape.
        case .firstPartyUpdateFeed:
            // Mac App Store slice ships no updater (2.4.5(vii)); only the site snapshot uses this lane.
            var updateFeedSites = ["WebsiteLiveSync.swift:fetch"]
            #if DIRECT_DISTRIBUTION
            updateFeedSites += ["Updater.swift:fetchManifest",
                                "Updater.swift:stage"]
            #endif
            return updateFeedSites
        case .buyerMailServer:
            return ["IMAPClient.swift:IMAPConnection",
                    "Outreach.swift:SMTPConnection"]
        case .loopbackOAuthCallback:
            // No loopback listener is compiled into the Mac App Store slice.
            var loopbackSites: [String] = []
            #if DIRECT_DISTRIBUTION
            loopbackSites.append("GA4OAuth.swift:connect")
            #endif
            return loopbackSites
        case .dnsRecordLookup:
            return ["DeliverabilityTools.swift:records",
                    "Outreach.swift:domainAcceptsMail"]
        }
    }
}

// MARK: - the refusals

enum ConsentedEgressError: LocalizedError, Equatable {
    /// No provider was named for a consent-requiring request. Deny, never allow.
    case providerNotSpecified(String)
    /// The request had no https URL to reason about.
    case malformedURL(String)
    /// The provider is consented but its registry entry does not cover this host.
    case hostNotRegistered(TransmissionProvider, String)
    /// The buyer has not granted (or has withdrawn / not re-read) consent for this provider.
    case consentRefused(TransmissionProvider, String)
    /// An ALLOWLISTED lane aimed at a host that belongs to a registered provider. The allowlist
    /// exists for traffic that is not consent-bearing; a registered host is consent-bearing by
    /// definition, so this is always a routing bug — and always a refusal, never a warning.
    case ungatedLaneMayNotReachRegisteredHost(UngatedEgressLane, TransmissionProvider, String)

    /// Text safe to show the buyer verbatim. Every branch states that nothing was sent.
    var errorDescription: String? {
        switch self {
        case .providerNotSpecified(let host):
            return "This app tried to send data to \(host.isEmpty ? "an unnamed destination" : host) "
                 + "without naming which service it belongs to, so it was refused. Nothing was sent."
        case .malformedURL(let raw):
            return "An outbound request had no usable https address (\(raw)), so it was refused. Nothing was sent."
        case .hostNotRegistered(let provider, let host):
            return "\(provider.displayName) is not authorised to receive data at \(host). "
                 + "That host is not part of what you allowed, so the request was refused. Nothing was sent."
        case .consentRefused(_, let refusal):
            return refusal
        case .ungatedLaneMayNotReachRegisteredHost(_, let provider, let host):
            return "An internal lane tried to reach \(host) without asking you first. "
                 + "\(provider.displayName) requires your explicit permission, so the request was "
                 + "refused. Nothing was sent."
        }
    }

    /// The provider this refusal is about, when there is one.
    var provider: TransmissionProvider? {
        switch self {
        case .hostNotRegistered(let p, _), .consentRefused(let p, _): return p
        case .ungatedLaneMayNotReachRegisteredHost(_, let p, _): return p
        case .providerNotSpecified, .malformedURL: return nil
        }
    }
}

/// Failures of the raw (non-HTTP) stream door. Kept separate from the HTTP refusals because the
/// mail lanes translate them into their own protocol errors.
enum RawEgressError: LocalizedError, Equatable {
    case connection(String)
    case timeout
    case closedByPeer
    case registeredHost(TransmissionProvider, String)

    var errorDescription: String? {
        switch self {
        case .connection(let detail): return detail
        case .timeout: return "The server did not respond in time."
        case .closedByPeer: return "server closed the connection"
        case .registeredHost(let p, let host):
            return "\(p.displayName) requires your explicit permission before anything is sent to "
                 + "\(host), so the connection was refused. Nothing was sent."
        }
    }
}

// MARK: - the choke point

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ConsentedEgress {
    /// The transport used when a caller does not pass one. Replaced by the runtime suite with a
    /// recorder; never replaced in shipping code.
    static var transport: OutboundTransport = URLSessionTransport()

    /// Where consent receipts are read from. `.standard` in the app; a scratch suite in tests, so a
    /// test run never reads or writes the buyer's real grants.
    static var consentDefaults: UserDefaults = .standard

    /// Which provider — if any — claims this host. Used to refuse the ungated door for anything
    /// consent-bearing, and it works on the URL that was actually built, so an interpolated or
    /// concatenated hostname is caught exactly like a literal one.
    static func registeredProvider(forHost host: String) -> TransmissionProvider? {
        let h = host.lowercased()
        guard !h.isEmpty else { return nil }
        return TransmissionProvider.allCases.first { $0.authorizes(h) }
    }

    /// THE one way a consent-requiring request leaves this device.
    ///
    /// The consent decision is made here, inside, after the caller has handed over the request and
    /// before any byte moves. There is no argument, flag or ordering a caller can choose that skips
    /// it, and no caller-side statement whose deletion would skip it either.
    @discardableResult
    static func send(_ request: URLRequest,
                     to provider: TransmissionProvider?,
                     destination: EgressDestination = .registeredHost,
                     via transport: OutboundTransport? = nil,
                     defaults: UserDefaults? = nil) async throws -> (Data, URLResponse) {
        let host = request.url?.host?.lowercased() ?? ""

        // 1. No provider named ⇒ refuse. An unattributed transmission is exactly the thing this
        //    file exists to prevent; it cannot be waved through as "probably fine".
        guard let provider else {
            throw ConsentedEgressError.providerNotSpecified(host)
        }

        // 2. No https URL ⇒ refuse.
        guard let url = request.url, url.scheme?.lowercased() == "https", !host.isEmpty else {
            throw ConsentedEgressError.malformedURL(request.url?.absoluteString ?? "<none>")
        }

        // 3. Unregistered host ⇒ refuse. The buyer consented to a disclosure that names hosts; a
        //    request to a host outside that list is not covered by what they read.
        if destination == .registeredHost, !provider.authorizes(host) {
            throw ConsentedEgressError.hostNotRegistered(provider, host)
        }

        // 4. THE GATE. Missing grant, withdrawn grant, or a grant taken under a superseded
        //    disclosure ⇒ refuse, with the buyer-facing text.
        if let refusal = TransmissionConsentStore.refusal(for: provider,
                                                          defaults: defaults ?? consentDefaults) {
            throw ConsentedEgressError.consentRefused(provider, refusal)
        }

        // 5. Only now does anything leave the machine.
        return try await (transport ?? Self.transport).perform(request)
    }

    // MARK: the declared-allowlist doors

    /// Egress for a lane on the declared allowlist. It still cannot reach a consent-bearing
    /// destination: if the host belongs to any `TransmissionProvider`, this refuses. The check is
    /// on the built URL, so obfuscating the hostname in source buys nothing.
    @discardableResult
    static func sendUngated(_ request: URLRequest,
                            lane: UngatedEgressLane,
                            via transport: OutboundTransport? = nil) async throws -> (Data, URLResponse) {
        try refuseIfRegistered(request.url?.host ?? "", lane: lane)
        return try await (transport ?? Self.transport).perform(request)
    }

    /// Completion-style variant, for the callback-shaped lanes (the OAuth exchanges, the brand-kit
    /// importer's semaphore-bounded fetch). Deliberately NOT a `Task` wrapper around the async
    /// door: two of these callers block a thread on a semaphore while they wait, and hopping onto
    /// the cooperative pool to do the work could deadlock a saturated pool. It is the same socket,
    /// in the same file, under the same allowlist and the same registered-host refusal.
    static func sendUngated(_ request: URLRequest,
                            lane: UngatedEgressLane,
                            completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        do { try refuseIfRegistered(request.url?.host ?? "", lane: lane) }
        catch { completion(nil, nil, error); return }
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }

    /// Download-to-file variant for the lanes that stage a media file (reference reel, remote
    /// music, the update archive) rather than parse a response body.
    static func downloadUngated(_ request: URLRequest,
                                lane: UngatedEgressLane) async throws -> (URL, URLResponse) {
        try refuseIfRegistered(request.url?.host ?? "", lane: lane)
        return try await URLSession.shared.download(for: request)
    }

    private static func refuseIfRegistered(_ host: String, lane: UngatedEgressLane) throws {
        if let provider = registeredProvider(forHost: host) {
            throw ConsentedEgressError.ungatedLaneMayNotReachRegisteredHost(lane, provider, host.lowercased())
        }
    }

    // MARK: the raw-stream door (SMTP / IMAP)

    /// Open a raw TCP/TLS stream for a declared allowlist lane. The mail lanes speak SMTP and IMAP,
    /// which no `URLRequest` can express, so the socket for them lives here too rather than in
    /// their own files. Same refusal: a registered host cannot be reached this way.
    static func openStream(host: String, port: UInt16, tls: Bool,
                           lane: UngatedEgressLane, label: String) throws -> RawEgressStream {
        if let provider = registeredProvider(forHost: host) {
            throw RawEgressError.registeredHost(provider, host.lowercased())
        }
        return RawEgressStream(host: host, port: port, tls: tls, label: label)
    }

    /// Open a stream that begins in the CLEAR and can be upgraded to TLS in place — the transport
    /// SMTP submission on port 587 requires (EHLO → STARTTLS → upgrade → EHLO). Separate door
    /// because it is a separate transport, not a flag: `RawEgressStream`'s `NWConnection` fixes its
    /// TLS options at creation and cannot upgrade a live socket. Same refusal as `openStream`.
    static func openStartTLSStream(host: String, port: UInt16,
                                   lane: UngatedEgressLane, label: String) throws -> StartTLSEgressStream {
        if let provider = registeredProvider(forHost: host) {
            throw RawEgressError.registeredHost(provider, host.lowercased())
        }
        return StartTLSEgressStream(host: host, port: port, label: label)
    }

    /// Bind the loopback OAuth callback listener. Nothing is transmitted through it.
    #if DIRECT_DISTRIBUTION
    static func openLoopbackCallbackListener(label: String) throws -> LoopbackCallbackListener {
        try LoopbackCallbackListener(label: label)
    }
    #endif

    // MARK: the resolver door

    /// The record types this app is allowed to ask for. A closed enum rather than a raw `UInt16`,
    /// so the resolver door cannot be turned into a general-purpose DNS tunnel by a caller passing
    /// TXT or NULL.
    enum DNSRecordType {
        case mailExchange
        case address
        case text
        case canonicalName
        case pointer
        fileprivate var rrType: UInt16 {
            switch self {
            case .mailExchange:  return UInt16(kDNSServiceType_MX)
            case .address:       return UInt16(kDNSServiceType_A)
            case .text:          return UInt16(kDNSServiceType_TXT)
            case .canonicalName: return UInt16(kDNSServiceType_CNAME)
            case .pointer:       return UInt16(kDNSServiceType_PTR)
            }
        }
        /// The answer's own record type, so a decoder never needs the dnssd constants (and so this
        /// file stays the only place in Sources/ that imports the resolver at all).
        fileprivate static func from(rrType: UInt16) -> DNSRecordType? {
            switch Int(rrType) {
            case kDNSServiceType_MX:    return .mailExchange
            case kDNSServiceType_A:     return .address
            case kDNSServiceType_TXT:   return .text
            case kDNSServiceType_CNAME: return .canonicalName
            case kDNSServiceType_PTR:   return .pointer
            default: return nil
            }
        }
    }

    /// Raw answers for `name`/`type` from the system resolver (dnssd) — in-house, no paid API.
    /// This is the ONLY resolver query in Sources/, on the declared `dnsRecordLookup` lane, because
    /// a DNS query is egress even though no socket is visible at the call site. Returns the raw
    /// rdata plus its record type (as this enum, never a raw dnssd constant); DECODING stays
    /// with the caller that understands the record.
    static func dnsAnswers(_ name: String, type: DNSRecordType,
                           timeout: Double = 5) async -> [(Data, DNSRecordType?)] {
        let host = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[(Data, DNSRecordType?)], Never>) in
            let box = DNSAnswerBox()
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var sdRef: DNSServiceRef?

            // NB: this is a C function pointer — it must NOT capture any context, so it only copies
            // the raw rdata into the box. Decoding happens in Swift land, at the caller.
            // Params: sdRef, flags, interfaceIndex, errorCode, fullname, rrtype, rrclass, rdlen, rdata, ttl, context.
            let callback: DNSServiceQueryRecordReply = { _, _, _, errorCode, _, rrtype, _, rdlen, rdata, _, ctxPtr in
                guard let ctxPtr else { return }
                let b = Unmanaged<DNSAnswerBox>.fromOpaque(ctxPtr).takeUnretainedValue()
                guard errorCode == kDNSServiceErr_NoError, rdlen > 0, let rdata else { return }
                b.raw.append((Data(bytes: rdata, count: Int(rdlen)), rrtype))
            }

            let err = DNSServiceQueryRecord(&sdRef, 0, 0, host, type.rrType,
                                            UInt16(kDNSServiceClass_IN), callback, ctx)
            guard err == kDNSServiceErr_NoError, let ref = sdRef else {
                Unmanaged<DNSAnswerBox>.fromOpaque(ctx).release()
                cont.resume(returning: []); return
            }
            let lifetime = DNSQueryLifetime(ref: ref, ctx: ctx)
            let queue = DispatchQueue(label: "bll.dns")
            DNSServiceSetDispatchQueue(ref, queue)
            // Hard timeout: give the resolver its window, then read whatever the callback set.
            queue.asyncAfter(deadline: .now() + max(1, timeout)) {
                guard !box.resumed else { return }
                box.resumed = true
                let out = box.raw.map { ($0.0, DNSRecordType.from(rrType: $0.1)) }
                lifetime.finish()
                cont.resume(returning: out)
            }
        }
    }

    /// Does `domain` publish any record of `type`? The deliverability gate's MX/A question.
    static func hasDNSRecord(_ domain: String, type: DNSRecordType) async -> Bool {
        !(await dnsAnswers(domain, type: type, timeout: 4)).isEmpty
    }
}
#endif // circuit-convert

/// Holds the resolver answers across the C callback boundary.
private final class DNSAnswerBox: @unchecked Sendable {
    var raw: [(Data, UInt16)] = []
    var resumed = false
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private final class DNSQueryLifetime: @unchecked Sendable {
    private let ref: DNSServiceRef
    private let ctx: UnsafeMutableRawPointer

    init(ref: DNSServiceRef, ctx: UnsafeMutableRawPointer) {
        self.ref = ref
        self.ctx = ctx
    }

    func finish() {
        DNSServiceRefDeallocate(ref)
        Unmanaged<DNSAnswerBox>.fromOpaque(ctx).release()
    }
}
#endif // circuit-convert

// MARK: - the raw stream itself

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A single TCP (optionally TLS) stream, owned by the choke point. Callers get `open/write/read/
/// close` and never touch `NWConnection`, so the SMTP and IMAP clients keep every line of their
/// protocol logic while owning no socket of their own.
final class RawEgressStream: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue

    fileprivate init(host: String, port: UInt16, tls: Bool, label: String) {
        let parameters: NWParameters = tls ? .tls : .tcp
        conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)
        queue = DispatchQueue(label: label)
    }

    /// Connect, or throw. A stream stuck in `.preparing` (DNS, TCP or TLS negotiation that never
    /// completes) is a timeout, never an infinite wait.
    func open(timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = EgressResumeGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() { cont.resume() }
                case .failed(let e), .waiting(let e):
                    if resumed.fire() { cont.resume(throwing: RawEgressError.connection(e.localizedDescription)) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + max(1, timeout)) { [weak self] in
                guard resumed.fire() else { return }
                self?.conn.cancel()
                cont.resume(throwing: RawEgressError.timeout)
            }
            conn.start(queue: queue)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: RawEgressError.connection(error.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    /// One read, bounded. A silent server (accepts the socket then never replies) would otherwise
    /// leave the receive callback pending forever, so the read races a hard deadline and the
    /// connection is cancelled on expiry.
    func read(maximumLength: Int, timeout: TimeInterval = 20) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let resumed = EgressResumeGuard()
            queue.asyncAfter(deadline: .now() + max(1, timeout)) { [weak self] in
                guard resumed.fire() else { return }
                self?.conn.cancel()
                cont.resume(throwing: RawEgressError.timeout)
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    if resumed.fire() { cont.resume(throwing: RawEgressError.connection(error.localizedDescription)) }
                    return
                }
                guard let data, !data.isEmpty else {
                    if resumed.fire() {
                        cont.resume(throwing: isComplete ? RawEgressError.closedByPeer : RawEgressError.timeout)
                    }
                    return
                }
                if resumed.fire() { cont.resume(returning: data) }
            }
        }
    }

    func close() { conn.cancel() }
}
#endif // circuit-convert

// MARK: - the STARTTLS stream (SMTP submission, port 587)

/// A stream that opens in the CLEAR and is upgraded to TLS in place on command. SMTP submission on
/// port 587 has no other shape: the session greets, EHLO's, issues STARTTLS, and only then is the
/// SAME socket encrypted — credentials never cross it before that.
///
/// WHY NOT `RawEgressStream`: `NWConnection` takes its TLS options at construction and cannot add
/// TLS to a live connection, which is why this app was 465-only. CFStream can: setting
/// `.socketSecurityLevelKey` to `negotiatedSSL` on an open socket pair performs exactly the
/// in-place handshake STARTTLS defines, with the system's normal certificate validation. So the
/// 587 lane is built on CFStream while 465 keeps using `NWConnection`, unchanged.
///
/// Callers get the same `open/write/read/close` shape and the same `RawEgressError` vocabulary as
/// `RawEgressStream`, so the SMTP protocol logic is identical on both transports.
final class StartTLSEgressStream: @unchecked Sendable {
    private let host: String, port: UInt16
    private let queue: DispatchQueue
    private var input: InputStream?
    private var output: OutputStream?
    private var upgraded = false

    fileprivate init(host: String, port: UInt16, label: String) {
        self.host = host; self.port = port
        queue = DispatchQueue(label: label)
    }

    /// True once the socket has been handed to TLS. The SMTP client asserts this before AUTH so an
    /// app password can never be written to a session that stayed in the clear.
    var isSecure: Bool { queue.sync { upgraded } }

    func open(timeout: TimeInterval = 20) async throws {
        try await onQueue {
            var ins: InputStream?
            var outs: OutputStream?
            Stream.getStreamsToHost(withName: self.host, port: Int(self.port), inputStream: &ins, outputStream: &outs)
            guard let ins, let outs else {
                throw RawEgressError.connection("could not open a socket to \(self.host):\(self.port)")
            }
            self.input = ins; self.output = outs
            ins.open(); outs.open()
            // A socket stuck in `.opening` (DNS or TCP that never completes) is a timeout, never an
            // infinite wait — the same rule the NWConnection stream follows.
            let deadline = Date().addingTimeInterval(max(1, timeout))
            while Date() < deadline {
                if let e = ins.streamError ?? outs.streamError {
                    throw RawEgressError.connection(e.localizedDescription)
                }
                if ins.streamStatus != .opening && outs.streamStatus != .opening { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw RawEgressError.timeout
        }
    }

    /// Hand the LIVE socket to TLS. Called only after the server answered STARTTLS with 220.
    /// The handshake itself completes on the next read/write; if it fails, that read/write throws
    /// and the session dies rather than continuing in the clear.
    func upgradeToTLS() async throws {
        try await onQueue {
            guard let ins = self.input, let outs = self.output else {
                throw RawEgressError.connection("the connection was closed before TLS could start")
            }
            let level = StreamSocketSecurityLevel.negotiatedSSL
            guard ins.setProperty(level, forKey: .socketSecurityLevelKey),
                  outs.setProperty(level, forKey: .socketSecurityLevelKey) else {
                throw RawEgressError.connection("the server offered STARTTLS but this Mac refused the TLS upgrade")
            }
            self.upgraded = true
        }
    }

    func write(_ data: Data) async throws {
        try await onQueue {
            guard let outs = self.output else { throw RawEgressError.connection("server closed the connection") }
            let bytes = [UInt8](data)
            var sent = 0
            let deadline = Date().addingTimeInterval(20)
            while sent < bytes.count {
                if Date() >= deadline { throw RawEgressError.timeout }
                if let e = outs.streamError { throw RawEgressError.connection(e.localizedDescription) }
                guard outs.hasSpaceAvailable else { Thread.sleep(forTimeInterval: 0.005); continue }
                let n = bytes.withUnsafeBufferPointer { outs.write($0.baseAddress! + sent, maxLength: bytes.count - sent) }
                guard n > 0 else {
                    throw RawEgressError.connection(outs.streamError?.localizedDescription ?? "the write was refused")
                }
                sent += n
            }
        }
    }

    /// One read, bounded. A silent server (accepts the socket then never replies) times out instead
    /// of leaving the caller waiting forever.
    func read(maximumLength: Int, timeout: TimeInterval = 20) async throws -> Data {
        try await onQueue {
            guard let ins = self.input else { throw RawEgressError.connection("server closed the connection") }
            let deadline = Date().addingTimeInterval(max(1, timeout))
            while Date() < deadline {
                if let e = ins.streamError { throw RawEgressError.connection(e.localizedDescription) }
                if ins.hasBytesAvailable {
                    var buf = [UInt8](repeating: 0, count: max(1, maximumLength))
                    let n = ins.read(&buf, maxLength: buf.count)
                    if n > 0 { return Data(buf[0..<n]) }
                    if n == 0 { throw RawEgressError.closedByPeer }
                    throw RawEgressError.connection(ins.streamError?.localizedDescription ?? "the read failed")
                }
                if ins.streamStatus == .atEnd { throw RawEgressError.closedByPeer }
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw RawEgressError.timeout
        }
    }

    func close() {
        queue.async {
            self.input?.close(); self.output?.close()
            self.input = nil; self.output = nil
        }
    }

    /// CFStream is poll-driven, so every operation runs on this stream's own serial queue and the
    /// async surface is a continuation over it. Serialization also means `input`/`output`/
    /// `upgraded` are only ever touched from one place.
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}

/// Ensures a continuation resumes EXACTLY once across a receive callback and its timeout timer
/// (resuming a CheckedContinuation twice traps). `fire()` returns true only for the first caller.
final class EgressResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: - the loopback OAuth callback listener

/// The 127.0.0.1 listener that catches an OAuth redirect. It is bound to IPv4 loopback only, so it
/// cannot accept traffic arriving over Wi-Fi or Ethernet while the consent window is open. It
/// hands the caller the callback URL and writes a local success page back to the browser; nothing
/// leaves the device through it.
// Binds a 127.0.0.1 listening socket, which requires com.apple.security.network.server — an
// entitlement the Mac App Store slice deliberately does not ship (2.4.5(i)).
#if DIRECT_DISTRIBUTION
final class LoopbackCallbackListener {
    private let listener: NWListener
    private let queue: DispatchQueue

    /// Called with the full callback URL the browser requested. Returns the HTML body to answer with.
    var onCallback: ((URL) -> String)?
    /// Called when the listener cannot bind, or fails afterwards.
    var onFailure: ((String) -> Void)?
    /// Called once the listener is bound, with the port it landed on.
    var onReady: ((UInt16) -> Void)?

    fileprivate init(label: String) throws {
        queue = DispatchQueue(label: label)
        let parameters = NWParameters.tcp
        // Bind only IPv4 loopback. State + PKCE protect the grant, and this prevents the short-lived
        // callback socket from accepting traffic on Wi-Fi/Ethernet while consent is open.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else { self.onFailure?("no callback port"); return }
                self.onReady?(port.rawValue)
            case .failed(let error):
                self.onFailure?(error.localizedDescription)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func cancel() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else {
                connection.cancel(); return
            }
            let pieces = firstLine.split(separator: " ")
            guard pieces.count >= 2, pieces[0] == "GET",
                  let callback = URL(string: "http://127.0.0.1\(pieces[1])") else {
                connection.cancel(); return
            }
            let body = self.onCallback?(callback) ?? ""
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif

extension TransmissionProvider {
    /// Does this provider's disclosed host list cover `host`? Sub-domains of a declared suffix count
    /// (the Salesforce and Pipedrive lanes target the buyer's own instance host under those
    /// suffixes); anything else does not.
    func authorizes(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        return hosts.contains { declared in
            let d = declared.lowercased()
            return h == d || h.hasSuffix("." + d)
        }
    }
}
