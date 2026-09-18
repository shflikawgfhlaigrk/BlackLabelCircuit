import Foundation

enum ArtifactReceiptState: Codable, Equatable, Sendable {
    case started
    case step(current: Int, total: Int, title: String)
    case done
    case failed(reason: String)
}

struct ArtifactReceipt: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let operationID: UUID
    let sequence: Int
    let timestamp: Date
    let artifactPath: String
    let sha256: String?
    let state: ArtifactReceiptState

    init(
        id: UUID = UUID(),
        operationID: UUID,
        sequence: Int,
        timestamp: Date = Date(),
        artifactPath: String,
        sha256: String?,
        state: ArtifactReceiptState
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.operationID = operationID
        self.sequence = sequence
        self.timestamp = Date(
            timeIntervalSince1970:
                floor(timestamp.timeIntervalSince1970)
        )
        self.artifactPath = URL(fileURLWithPath: artifactPath)
            .standardizedFileURL.path
        self.sha256 = sha256
        self.state = state
    }
}
