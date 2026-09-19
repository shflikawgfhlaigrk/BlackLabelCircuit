import Foundation

/// A verified, durably committed lease grants local entitlement. Website
/// delivery remains pending until its acknowledgement is verified and saved;
/// that later proof alone publishes linked and device_delivery_attested.
nonisolated enum DeviceLinkPublicationPolicy {
    enum Phase: Equatable, Sendable {
        case none
        case finishingDeliveryVerification
        case linked
    }

    struct Decision: Equatable, Sendable {
        let mayPublishLicensed: Bool
        let mayPublishLinked: Bool
        let mayEmitDeliveryAttestedProof: Bool
        let visiblePhase: Phase
    }

    static func decide(
        credentialCommitted: Bool,
        acknowledgementVerified: Bool,
        deliveryAttestedDurably: Bool
    ) -> Decision {
        guard credentialCommitted else {
            // Nothing committed — including the incoherent case of an
            // acknowledgement without a credential — publishes nothing.
            return Decision(
                mayPublishLicensed: false,
                mayPublishLinked: false,
                mayEmitDeliveryAttestedProof: false,
                visiblePhase: .none
            )
        }
        guard acknowledgementVerified, deliveryAttestedDurably else {
            return Decision(
                mayPublishLicensed: true,
                mayPublishLinked: false,
                mayEmitDeliveryAttestedProof: false,
                visiblePhase: .finishingDeliveryVerification
            )
        }
        return Decision(
            mayPublishLicensed: true,
            mayPublishLinked: true,
            mayEmitDeliveryAttestedProof: true,
            visiblePhase: .linked
        )
    }
}
