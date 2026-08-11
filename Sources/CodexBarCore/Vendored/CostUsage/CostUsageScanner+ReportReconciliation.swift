import Foundation

extension CostUsageScanner {
    struct CodexDayModelKey: Hashable {
        let day: String
        let model: String
    }

    struct CodexCanonicalPricingRows {
        let rows: [CodexUsageRow]
        let unresolvedGroups: Set<CodexDayModelKey>
    }

    static func codexCanonicalPricingRows(_ usage: CostUsageFileUsage) -> CodexCanonicalPricingRows {
        let persistedRows = usage.codexRows ?? []
        let rowsByGroup = Dictionary(grouping: persistedRows) {
            CodexDayModelKey(day: $0.day, model: $0.model)
        }
        var canonicalRows: [CodexUsageRow] = []
        var unresolvedGroups = Set<CodexDayModelKey>()

        for day in usage.days.keys.sorted() {
            guard let models = usage.days[day] else { continue }
            for model in models.keys.sorted() {
                let key = CodexDayModelKey(day: day, model: model)
                let packed = models[model] ?? []
                let target = CodexRowTokenTotals(
                    input: max(0, packed[safe: 0] ?? 0),
                    cached: max(0, packed[safe: 1] ?? 0),
                    output: max(0, packed[safe: 2] ?? 0))
                guard let rows = self.reconciledCodexPricingRows(
                    rowsByGroup[key] ?? [],
                    target: target)
                else {
                    unresolvedGroups.insert(key)
                    continue
                }
                canonicalRows.append(contentsOf: rows)
            }
        }

        return CodexCanonicalPricingRows(rows: canonicalRows, unresolvedGroups: unresolvedGroups)
    }

    private struct CodexRowTokenTotals: Equatable {
        var input: Int = 0
        var cached: Int = 0
        var output: Int = 0

        mutating func add(_ row: CodexUsageRow) -> Bool {
            guard let input = Self.sum(self.input, max(0, row.input)),
                  let cached = Self.sum(self.cached, max(0, row.cached)),
                  let output = Self.sum(self.output, max(0, row.output))
            else { return false }
            self = CodexRowTokenTotals(input: input, cached: cached, output: output)
            return true
        }

        func exceeds(_ other: CodexRowTokenTotals) -> Bool {
            self.input > other.input || self.cached > other.cached || self.output > other.output
        }

        private static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : sum
        }
    }

    private static func reconciledCodexPricingRows(
        _ rows: [CodexUsageRow],
        target: CodexRowTokenTotals) -> [CodexUsageRow]?
    {
        var allRowsTotal = CodexRowTokenTotals()
        guard rows.allSatisfy({ allRowsTotal.add($0) }) else { return nil }
        if allRowsTotal == target {
            return rows
        }
        guard allRowsTotal.exceeds(target) else { return nil }
        let timestampPresence = Set(rows.map { $0.timestampUnixMs != nil })
        guard timestampPresence.count <= 1 else { return nil }

        let chronological = rows.enumerated().sorted { lhs, rhs in
            let lhsTimestamp = lhs.element.timestampUnixMs ?? Int64.min
            let rhsTimestamp = rhs.element.timestampUnixMs ?? Int64.min
            if lhsTimestamp != rhsTimestamp {
                return lhsTimestamp < rhsTimestamp
            }
            let lhsEventIndex = lhs.element.eventIndex ?? Int.min
            let rhsEventIndex = rhs.element.eventIndex ?? Int.min
            if lhsEventIndex != rhsEventIndex {
                return lhsEventIndex < rhsEventIndex
            }
            return lhs.offset < rhs.offset
        }
        var suffixTotal = CodexRowTokenTotals()
        for index in chronological.indices.reversed() {
            guard suffixTotal.add(chronological[index].element) else { return nil }
            if suffixTotal == target {
                return chronological[index...].map(\.element)
            }
            if suffixTotal.exceeds(target) {
                return nil
            }
        }
        return nil
    }
}
