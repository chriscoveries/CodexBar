import Foundation

enum CostUsageJsonl {
    struct Line {
        let bytes: Data
        let wasTruncated: Bool
    }

    private struct JSONTailState {
        private var containerDepth = 0
        private var insideString = false
        private var escaping = false
        private var sawNonWhitespace = false

        mutating func reset() {
            self = Self()
        }

        var isStructurallyComplete: Bool {
            self.sawNonWhitespace && !self.insideString && self.containerDepth == 0
        }

        mutating func append(_ byte: UInt8) {
            if self.insideString {
                if self.escaping {
                    self.escaping = false
                } else if byte == 0x5C {
                    self.escaping = true
                } else if byte == 0x22 {
                    self.insideString = false
                }
                return
            }

            switch byte {
            case 0x20, 0x09, 0x0D:
                return
            case 0x22:
                self.sawNonWhitespace = true
                self.insideString = true
            case 0x7B, 0x5B:
                self.sawNonWhitespace = true
                self.containerDepth += 1
            case 0x7D, 0x5D:
                self.sawNonWhitespace = true
                self.containerDepth = max(0, self.containerDepth - 1)
            default:
                self.sawNonWhitespace = true
            }
        }
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scan(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            checkCancellation: nil,
            onLine: onLine)
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        checkCancellation: (() throws -> Void)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0
        var committedOffset = startOffset
        var jsonTailState = JSONTailState()

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < prefixBytes {
                let appendCount = min(prefixBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
            }
        }

        func flushLine() {
            guard lineBytes > 0 else { return }
            let line = Line(bytes: current, wasTruncated: truncated)
            onLine(line)
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
            jsonTailState.reset()
        }

        func hasCompleteJSONTail() -> Bool {
            if truncated {
                // The full record is intentionally not retained. Its structural state is enough
                // to keep a still-open object or string retriable without changing the old
                // behavior for complete records that exceed the safety limit.
                return jsonTailState.isStructurallyComplete
            }
            guard lineBytes == current.count else { return false }
            return (try? JSONSerialization.jsonObject(with: current, options: [.fragmentsAllowed])) != nil
        }

        while true {
            try checkCancellation?()
            let reachedEOF = try autoreleasepool {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    if hasCompleteJSONTail() {
                        flushLine()
                        committedOffset = startOffset + bytesRead
                    }
                    return true
                }

                try checkCancellation?()
                bytesRead += Int64(chunk.count)
                let chunkStartOffset = startOffset + bytesRead - Int64(chunk.count)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segmentStart = 0
                    var index = 0
                    while index < rawBuffer.count {
                        if base[index] == 0x0A {
                            appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                            flushLine()
                            committedOffset = chunkStartOffset + Int64(index + 1)
                            segmentStart = index + 1
                        } else {
                            jsonTailState.append(base[index])
                        }
                        index += 1
                    }
                    if segmentStart < rawBuffer.count {
                        appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                    }
                }
                return false
            }
            if reachedEOF { break }
            try checkCancellation?()
        }

        return committedOffset
    }
}
