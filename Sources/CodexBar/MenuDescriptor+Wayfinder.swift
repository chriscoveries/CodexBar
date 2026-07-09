import CodexBarCore

extension MenuDescriptor {
    static func appendWayfinderUsageSummary(
        entries: inout [Entry],
        usage: WayfinderUsageSnapshot)
    {
        if let routed = usage.routedSummary {
            entries.append(.text("Routed: \(routed)", .secondary))
        }
        if let saved = usage.savedSummary {
            entries.append(.text("Saved: \(saved)", .secondary))
        }
        if let avgDecision = usage.avgDecisionSummary {
            entries.append(.text("Avg decision: \(avgDecision)", .secondary))
        }
    }
}
