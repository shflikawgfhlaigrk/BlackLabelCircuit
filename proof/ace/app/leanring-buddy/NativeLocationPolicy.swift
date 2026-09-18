//
//  NativeLocationPolicy.swift
//  Ace
//
//  Pure, Foundation-only location intent, state, and session-context policy.
//  The live CLLocationManager bridge is isolated in NativeLocationManager.swift.
//

import Foundation

enum NativeLocationIntent: Equatable, Sendable {
    case requestAccess
    case weather(explicitLocality: String?)
    case none
}

enum NativeLocationIntentPolicy {
    private static let requestAccessExpressions = [
        #"^(?:please\s+)?(?:request|ask\s+for|enable)\s+(?:my\s+)?location\s+(?:access|permission)$"#,
        #"^(?:please\s+)?give\s+(?:ace\s+)?location\s+access$"#,
    ]

    static func classify(_ rawUtterance: String) -> NativeLocationIntent {
        let utterance = rawUtterance
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, utterance.count <= 240 else { return .none }

        let normalized = normalizedForMatching(utterance)
        if requestAccessExpressions.contains(where: {
            normalized.range(of: $0, options: .regularExpression) != nil
        }) {
            return .requestAccess
        }

        if let locality = explicitWeatherLocality(in: utterance) {
            return .weather(explicitLocality: locality)
        }

        if isCurrentLocalWeatherQuestion(normalized) {
            return .weather(explicitLocality: nil)
        }

        return .none
    }

    private static var trailingSentencePunctuation: CharacterSet {
        CharacterSet(charactersIn: "?.!").union(.whitespacesAndNewlines)
    }

    private static func normalizedForMatching(_ text: String) -> String {
        var value = text.lowercased()
            .trimmingCharacters(in: trailingSentencePunctuation)
        value = value.replacingOccurrences(of: "’", with: "'")
        value = value.replacingOccurrences(of: "what's", with: "what is")
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value
    }

    // Spoken weather questions arrive in many shapes ("what's the weather
    // like today?", "how is it outside", "weather in Pensacola, FL"). These
    // grammars are anchored to the whole utterance: a longer instruction
    // ("search the web for today's weather in Denver") keeps its own route
    // and a knowledge question ("difference between weather and climate")
    // stays with Gold.
    private static let weatherOpener =
        #"(?:(?:hey|hi|ok|okay|so|please|ace|yo)[\s,]+)*"#
        + #"(?:(?:what|how)(?:['’]s|s|\s+is)?|tell\s+me|give\s+me|check|show\s+me|get|read|look\s+up|do\s+you\s+know)?[\s,]*"#
        + #"(?:(?:the|my|our|current|local|today['’]?s)\s+)*"#
    private static let weatherNoun =
        #"(?:weather|forecast|temperature|temp)(?:\s+(?:like|report|forecast|conditions))*"#
    private static let weatherWhen =
        #"(?:\s+(?:today|tonight|right\s+now|now|currently|at\s+the\s+moment|this\s+morning|this\s+afternoon|this\s+evening))*"#
    private static let weatherPoliteness = #"(?:[\s,]+(?:please|ace))?"#

    private static let explicitWeatherExpression = try? NSRegularExpression(
        pattern: "(?i)^" + weatherOpener + weatherNoun
            + #"\s+(?:in|for|at|around|near|over\s+in|out\s+in)\s+"#
            + #"(?!(?:today|tonight|tomorrow|now|right\s+now|currently|later|this\s+(?:morning|afternoon|evening|week|weekend)|the\s+(?:day|week|weekend|morning|afternoon|evening))\b)(.+?)"#
            + weatherWhen + weatherPoliteness + #"\s*[?.!]*$"#
    )

    private static let localWeatherExpressions: [NSRegularExpression] = [
        "^" + weatherOpener + weatherNoun
            + #"(?:\s+(?:for\s+)?(?:here|outside|out\s+there|out|where\s+i\s+am|today|tonight|right\s+now|now|currently|at\s+the\s+moment|this\s+morning|this\s+afternoon|this\s+evening))*"#
            + weatherPoliteness + "$",
        #"^(?:(?:hey|hi|ok|okay|so|please|ace)[\s,]+)*is\s+it\s+(?:raining|rainy|sunny|cloudy|snowing|windy|foggy|hot|cold|warm|cool|humid|nice|clear|stormy)(?:\s+(?:outside|out|out\s+there|today|right\s+now|now|tonight|here))*"#
            + weatherPoliteness + "$",
        #"^(?:(?:hey|hi|ok|okay|so|please|ace)[\s,]+)*how\s+(?:hot|cold|warm|cool|humid|windy)\s+is\s+it(?:\s+(?:outside|out|out\s+there|today|right\s+now|now|tonight|here))*"#
            + weatherPoliteness + "$",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// A whole-utterance question about the weather where the owner is now.
    static func isCurrentLocalWeatherQuestion(_ normalized: String) -> Bool {
        let range = NSRange(normalized.startIndex..., in: normalized)
        return localWeatherExpressions.contains {
            $0.firstMatch(in: normalized, range: range) != nil
        }
    }

    private static func explicitWeatherLocality(in utterance: String) -> String? {
        guard let expression = explicitWeatherExpression,
              let match = expression.firstMatch(
                in: utterance,
                range: NSRange(utterance.startIndex..., in: utterance)
              ),
              let range = Range(match.range(at: 1), in: utterance) else {
            return nil
        }
        let locality = String(utterance[range])
            .trimmingCharacters(in: trailingSentencePunctuation)
        guard locality.count >= 2,
              locality.count <= 120,
              locality.rangeOfCharacter(from: .newlines) == nil,
              locality.range(
                of: #"(?i)^(?:the\s+)?(?:app|browser|web|internet|background|window|screen|panel)\b"#,
                options: .regularExpression
              ) == nil else {
            return nil
        }
        return locality
    }

}

struct NativeLocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let observedAt: Date

    init?(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        observedAt: Date
    ) {
        guard latitude.isFinite,
              longitude.isFinite,
              horizontalAccuracy.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              horizontalAccuracy >= 0 else {
            return nil
        }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.observedAt = observedAt
    }

    var weatherQuery: String {
        String(format: "%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }
}

enum LocalWeatherResolution: Equatable, Sendable {
    case spokenLocality(String)
    case deviceLocation(String)
    case needsDeviceLocationRecovery
    case needsSpokenLocality

    var wrapperArguments: [String]? {
        switch self {
        case let .spokenLocality(locality), let .deviceLocation(locality):
            return [locality]
        case .needsDeviceLocationRecovery, .needsSpokenLocality:
            return nil
        }
    }
}

struct LocalWeatherSessionContext: Sendable {
    static let maximumDeviceFixAge: TimeInterval = 5 * 60

    private var sessionID: UUID?
    private var deviceFix: NativeLocationFix?
    private var deviceLocationIsUnavailable = false

    mutating func rememberDeviceFix(_ fix: NativeLocationFix, sessionID: UUID) {
        resetIfNeeded(for: sessionID)
        deviceFix = fix
        deviceLocationIsUnavailable = false
    }

    mutating func rememberDeviceLocationUnavailable(sessionID: UUID) {
        resetIfNeeded(for: sessionID)
        deviceFix = nil
        deviceLocationIsUnavailable = true
    }

    mutating func weatherResolution(
        explicitLocality: String?,
        sessionID: UUID,
        now: Date = Date()
    ) -> LocalWeatherResolution {
        if let explicitLocality {
            return .spokenLocality(explicitLocality)
        }
        guard self.sessionID == sessionID else {
            return .needsDeviceLocationRecovery
        }
        if let deviceFix,
           now.timeIntervalSince(deviceFix.observedAt) >= 0,
           now.timeIntervalSince(deviceFix.observedAt) <= Self.maximumDeviceFixAge {
            return .deviceLocation(deviceFix.weatherQuery)
        }
        return deviceLocationIsUnavailable
            ? .needsSpokenLocality
            : .needsDeviceLocationRecovery
    }

    mutating func clear() {
        sessionID = nil
        deviceFix = nil
        deviceLocationIsUnavailable = false
    }

    private mutating func resetIfNeeded(for newSessionID: UUID) {
        guard sessionID != newSessionID else { return }
        sessionID = newSessionID
        deviceFix = nil
        deviceLocationIsUnavailable = false
    }
}

enum NativeLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum NativeLocationRequestState: Equatable, Sendable {
    case idle
    case requestingAuthorization
    case requestingLocation
    case completed
}

enum NativeLocationRequestOutcome: Equatable, Sendable {
    case ready(NativeLocationFix)
    case denied
    case restricted
    case servicesUnavailable
    case locationUnavailable
    case authorizationTimedOut
    case locationTimedOut

    var ownerFacingLine: String {
        switch self {
        case let .ready(fix):
            return "location access is on. i read one current Mac location fix with about \(Int(fix.horizontalAccuracy.rounded())) meters of reported accuracy."
        case .denied:
            return "location access is off for Ace, so i did not read or retain your location. turn Ace on in System Settings, Privacy and Security, Location Services, then ask again."
        case .restricted:
            return "location access is restricted on this Mac, so i did not read or retain your location."
        case .servicesUnavailable:
            return "Location Services are unavailable on this Mac, so i did not read or retain your location."
        case .locationUnavailable:
            return "i did not get a valid current location fix, so i did not retain a location."
        case .authorizationTimedOut:
            return "the location permission request timed out, so i did not read or retain your location."
        case .locationTimedOut:
            return "location access is on, but the current fix timed out, so i did not retain a location."
        }
    }

    var spokenLocalityRecoveryLine: String? {
        switch self {
        case .ready:
            return nil
        case .denied, .restricted, .servicesUnavailable,
             .locationUnavailable, .authorizationTimedOut,
             .locationTimedOut:
            return "I couldn't read a current Mac location. Which city and state should I use for this weather request?"
        }
    }
}

@MainActor
protocol NativeLocationEffectProviding: AnyObject {
    func requestWhenInUseAuthorization()
    func requestSingleLocation()
}

@MainActor
final class NativeLocationRequestCoordinator {
    static let maximumAcceptedFixAge: TimeInterval = 2 * 60
    static let maximumAcceptedFutureSkew: TimeInterval = 5

    private let provider: NativeLocationEffectProviding
    private let now: () -> Date
    private var completion: ((NativeLocationRequestOutcome) -> Void)?

    private(set) var state: NativeLocationRequestState = .idle

    init(
        provider: NativeLocationEffectProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.now = now
    }

    func start(
        servicesAvailable: Bool,
        authorization: NativeLocationAuthorization,
        completion: @escaping (NativeLocationRequestOutcome) -> Void
    ) {
        guard state == .idle else { return }
        self.completion = completion
        guard servicesAvailable else {
            finish(.servicesUnavailable)
            return
        }
        authorizationDidChange(authorization)
    }

    func authorizationDidChange(_ authorization: NativeLocationAuthorization) {
        guard state != .completed else { return }
        switch authorization {
        case .notDetermined:
            guard state == .idle else { return }
            state = .requestingAuthorization
            provider.requestWhenInUseAuthorization()
        case .authorized:
            guard state == .idle || state == .requestingAuthorization else { return }
            state = .requestingLocation
            provider.requestSingleLocation()
        case .denied:
            finish(.denied)
        case .restricted:
            finish(.restricted)
        }
    }

    func didReceiveLocation(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        observedAt: Date? = nil
    ) {
        guard state == .requestingLocation else { return }
        let receivedAt = now()
        let fixDate = observedAt ?? receivedAt
        let age = receivedAt.timeIntervalSince(fixDate)
        guard age >= -Self.maximumAcceptedFutureSkew,
              age <= Self.maximumAcceptedFixAge else {
            finish(.locationUnavailable)
            return
        }
        guard let fix = NativeLocationFix(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            observedAt: fixDate
        ) else {
            finish(.locationUnavailable)
            return
        }
        finish(.ready(fix))
    }

    func didFail() {
        guard state == .requestingLocation else { return }
        finish(.locationUnavailable)
    }

    func timeout() {
        switch state {
        case .requestingAuthorization:
            finish(.authorizationTimedOut)
        case .requestingLocation:
            finish(.locationTimedOut)
        case .idle, .completed:
            return
        }
    }

    private func finish(_ outcome: NativeLocationRequestOutcome) {
        guard state != .completed else { return }
        state = .completed
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
