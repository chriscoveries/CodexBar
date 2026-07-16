import Foundation

extension UsageStore {
    struct LimitResetDetectorState: Codable, Equatable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
        let sourceRawValue: String?
        var resetBoundary: Date?
        /// Identity-less Claude CLI samples share one detector key and can be transient.
        /// Require a second low sample before celebrating an apparent reset from that key.
        var pendingLowConfirmation: Bool

        init(
            wasAboveThreshold: Bool,
            lastObservedAt: Date,
            sourceRawValue: String?,
            resetBoundary: Date? = nil,
            pendingLowConfirmation: Bool = false)
        {
            self.wasAboveThreshold = wasAboveThreshold
            self.lastObservedAt = lastObservedAt
            self.sourceRawValue = sourceRawValue
            self.resetBoundary = resetBoundary
            self.pendingLowConfirmation = pendingLowConfirmation
        }

        private enum CodingKeys: String, CodingKey {
            case wasAboveThreshold
            case lastObservedAt
            case sourceRawValue
            case resetBoundary
            case pendingLowConfirmation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.wasAboveThreshold = try container.decode(Bool.self, forKey: .wasAboveThreshold)
            self.lastObservedAt = try container.decode(Date.self, forKey: .lastObservedAt)
            self.sourceRawValue = try container.decodeIfPresent(String.self, forKey: .sourceRawValue)
            self.resetBoundary = try container.decodeIfPresent(Date.self, forKey: .resetBoundary)
            self.pendingLowConfirmation = try container.decodeIfPresent(
                Bool.self,
                forKey: .pendingLowConfirmation) ?? false
        }
    }
}
