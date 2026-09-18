import Foundation

nonisolated enum OverlayActivityPhase: Equatable, Sendable {
    case hidden
    case idle
    case listening
    case processing
    case responding
    case partner(PartnerSessionPhase)
    case trailingLane
}

nonisolated struct OverlayActivityPresentation: Equatable, Sendable {
    let facetAnimationRate: Double
    let tracksCursor: Bool
    let rendersWaveform: Bool
    let waveformAnimates: Bool
    let rendersSpinner: Bool
    let spinnerAnimates: Bool
    let rendersDeafnessCue: Bool
    let deafnessCueAnimates: Bool

    var rendersFacetTimeline: Bool {
        facetAnimationRate > 0
    }

    var hasActiveAnimation: Bool {
        rendersFacetTimeline
            || (rendersWaveform && waveformAnimates)
            || (rendersSpinner && spinnerAnimates)
            || (rendersDeafnessCue && deafnessCueAnimates)
    }
}

nonisolated enum OverlayActivityPolicy {
    static func presentation(
        for phase: OverlayActivityPhase,
        reduceMotion: Bool,
        deafnessActive: Bool
    ) -> OverlayActivityPresentation {
        let visible = phase != .hidden
        let facetAnimationRate: Double
        switch phase {
        case .hidden, .idle, .listening, .processing:
            facetAnimationRate = 0
        case .responding:
            facetAnimationRate = 0.36
        case .trailingLane:
            facetAnimationRate = 0.28
        case .partner(let partnerPhase):
            facetAnimationRate = PartnerGemPresentation.forPhase(
                partnerPhase,
                reduceMotion: reduceMotion
            ).animationRate
        }

        let rendersWaveform = phase == .listening
        let rendersSpinner = phase == .processing
        return OverlayActivityPresentation(
            facetAnimationRate: reduceMotion ? 0 : facetAnimationRate,
            tracksCursor: visible,
            rendersWaveform: rendersWaveform,
            waveformAnimates: rendersWaveform && !reduceMotion,
            rendersSpinner: rendersSpinner,
            spinnerAnimates: rendersSpinner && !reduceMotion,
            rendersDeafnessCue: visible && deafnessActive,
            deafnessCueAnimates:
                visible && deafnessActive && !reduceMotion
        )
    }
}
