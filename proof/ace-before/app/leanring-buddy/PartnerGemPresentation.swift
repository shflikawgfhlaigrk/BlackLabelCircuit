import Foundation

nonisolated enum PartnerGemAppearance:
    Equatable,
    Sendable
{
    case gold
    case obsidian
}

nonisolated enum PartnerGemBadge:
    Equatable,
    Sendable
{
    case none
    case muted
    case error
}

nonisolated struct PartnerGemPresentation:
    Equatable,
    Sendable
{
    let appearance: PartnerGemAppearance
    let animationRate: Double
    let goldRimOpacity: Double
    let badge: PartnerGemBadge

    static let normal = PartnerGemPresentation(
        appearance: .gold,
        animationRate: 0,
        goldRimOpacity: 0,
        badge: .none
    )

    static func forPhase(
        _ phase: PartnerSessionPhase,
        reduceMotion: Bool
    ) -> PartnerGemPresentation {
        guard phase != .inactive else {
            return reduceMotion
                ? PartnerGemPresentation(
                    appearance: .gold,
                    animationRate: 0,
                    goldRimOpacity: 0,
                    badge: .none
                )
                : .normal
        }

        let animationRate: Double
        let rimOpacity: Double
        let badge: PartnerGemBadge
        switch phase {
        case .inactive:
            return .normal
        case .ready:
            animationRate = 0
            rimOpacity = 0.92
            badge = .none
        case .listening:
            animationRate = 0.7
            rimOpacity = 0.96
            badge = .none
        case .processing:
            animationRate = 1.1
            rimOpacity = 0.94
            badge = .none
        case .speaking:
            animationRate = 0.62
            rimOpacity = 1
            badge = .none
        case .waiting:
            animationRate = 0
            rimOpacity = 0.7
            badge = .none
        case .muted:
            animationRate = 0
            rimOpacity = 0.62
            badge = .muted
        case .error:
            animationRate = 0
            rimOpacity = 0.75
            badge = .error
        }

        return PartnerGemPresentation(
            appearance: .obsidian,
            animationRate: reduceMotion ? 0 : animationRate,
            goldRimOpacity: rimOpacity,
            badge: badge
        )
    }
}
