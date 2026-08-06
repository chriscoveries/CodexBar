import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
struct ProviderArchitectureGatekeeperTests {
    @Test
    func `every provider has descriptor and implementation manifest entries`() {
        let expected = Set(UsageProvider.allCases)
        let descriptors = Set(ProviderDescriptorRegistry.all.map(\.id))
        let implementations = Set(ProviderImplementationRegistry.all.map(\.id))
        let missingDescriptors = expected.subtracting(descriptors).map(\.rawValue).sorted()
        let missingImplementations = expected.subtracting(implementations).map(\.rawValue).sorted()

        #expect(
            missingDescriptors.isEmpty,
            "Missing descriptor manifest entries: \(missingDescriptors.joined(separator: ", "))")
        #expect(
            missingImplementations.isEmpty,
            "Missing implementation manifest entries: \(missingImplementations.joined(separator: ", "))")
    }

    @Test
    func `credential adapters self report capabilities through descriptors`() {
        for descriptor in ProviderDescriptorRegistry.all {
            guard let adapter = descriptor.credentials else { continue }

            #expect(
                ProviderConfigEnvironment.supportsAPIKeyOverride(for: descriptor.id) ==
                    adapter.supportsAPIKeyOverride,
                "API-key capability drifted for \(descriptor.id.rawValue).")
            #expect(
                (TokenAccountSupportCatalog.support(for: descriptor.id) != nil) ==
                    (adapter.tokenAccountSupport != nil),
                "Token-account capability drifted for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `every provider can produce and read its registered settings section`() {
        let settings = testSettingsStore(suiteName: "ProviderArchitectureGatekeeperTests-settings-sections")
        let context = ProviderSettingsSnapshotContext(settings: settings, tokenOverride: nil)
        var builder = ProviderSettingsSnapshotBuilder()

        for implementation in ProviderImplementationRegistry.all {
            let providerName = implementation.id.rawValue
            let registration = ProviderDescriptorRegistry.descriptor(for: implementation.id).settingsSection
            guard let contribution = implementation.settingsSnapshot(context: context) else {
                Issue.record("Missing settings-section contribution for provider '\(providerName)'.")
                continue
            }
            #expect(
                registration.accepts(contribution),
                "Settings-section registration does not match provider '\(providerName)'.")
            builder.apply(contribution)
        }

        let snapshot = builder.build()
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                descriptor.settingsSection.canRead(from: snapshot),
                "Could not read settings section for provider '\(descriptor.id.rawValue)'.")
        }
    }

    @Test
    func `empty settings snapshot factory has no provider sections`() {
        let snapshot = ProviderSettingsSnapshot.make()

        #expect(snapshot.abacus == nil)
        #expect(!snapshot.debugMenuEnabled)
        #expect(!snapshot.debugKeepCLISessionsAlive)
    }

    @Test
    func `every provider descriptor has a loadable SVG resource`() throws {
        let resources = try Self.repoRoot()
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        for descriptor in ProviderDescriptorRegistry.all {
            let resourceName = descriptor.branding.iconResourceName
            let url = resources.appending(path: "\(resourceName).svg")
            #expect(
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "Missing SVG for \(descriptor.id.rawValue): \(resourceName).svg")
            #expect(NSImage(contentsOf: url) != nil, "Could not load \(resourceName).svg as NSImage")
        }
    }

    @Test
    func `widget provider choices match selectable descriptor metadata`() {
        let selectable = Set(ProviderDescriptorRegistry.all.filter(\.metadata.widgetSelectable).map(\.id))
        let choices = Set(ProviderChoice.allCases.map(\.provider))
        let missing = selectable.subtracting(choices).map(\.rawValue).sorted()
        let unexpected = choices.subtracting(selectable).map(\.rawValue).sorted()

        #expect(
            missing.isEmpty,
            "Missing ProviderChoice cases for widget-selectable providers: \(missing.joined(separator: ", "))")
        #expect(
            unexpected.isEmpty,
            "ProviderChoice cases marked non-selectable in descriptor metadata: \(unexpected.joined(separator: ", "))")
    }

    @Test
    func `widget short labels preserve compact provider names`() {
        let overrides: [UsageProvider: String] = [
            .antigravity: "Anti",
            .alibabatokenplan: "Token Plan",
            .vertexai: "Vertex",
            .perplexity: "Pplx",
            .mimo: "MiMo",
            .sakana: "Sakana",
            .abacus: "Abacus",
            .bedrock: "Bedrock",
            .jetbrains: "JetBrains",
            .moonshot: "Moonshot",
        ]
        for descriptor in ProviderDescriptorRegistry.all {
            let expected = overrides[descriptor.id] ?? descriptor.metadata.displayName
            #expect(
                descriptor.metadata.shortDisplayName == expected,
                "Unexpected widget short label for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `descriptor widget colors preserve the pre-derivation literals`() {
        var widgetFingerprint: UInt64 = 1_469_598_103_934_665_603
        var burnDownFingerprint = widgetFingerprint
        for descriptor in ProviderDescriptorRegistry.all {
            Self.hash(descriptor.id.rawValue.utf8, into: &widgetFingerprint)
            Self.hash(descriptor.branding.widgetColor, into: &widgetFingerprint)
            Self.hash(descriptor.id.rawValue.utf8, into: &burnDownFingerprint)
            Self.hash(descriptor.branding.burnDownWidgetColor, into: &burnDownFingerprint)
        }

        #expect(widgetFingerprint == 8_322_639_844_029_602_741)
        #expect(burnDownFingerprint == 3_478_078_203_311_670_951)
    }

    @Test
    func `descriptor unavailable debug messages preserve the legacy table`() throws {
        let descriptors = ProviderDescriptorRegistry.all.filter { $0.metadata.debugLogUnavailableMessage != nil }
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for descriptor in descriptors {
            Self.hash(descriptor.id.rawValue.utf8, into: &fingerprint)
            try Self.hash(#require(descriptor.metadata.debugLogUnavailableMessage?.utf8), into: &fingerprint)
        }

        #expect(descriptors.count == 38)
        #expect(fingerprint == 2_208_147_801_202_684_136)
    }

    @Test
    func `debug pane provider curation preserves legacy membership and order`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ordered: ((ProviderDebugPaneCapabilities) -> Int?) -> [UsageProvider] = { rank in
            descriptors.compactMap { descriptor -> (UsageProvider, Int)? in
                guard let value = rank(descriptor.metadata.debugPane) else { return nil }
                return (descriptor.id, value)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        }

        #expect(ordered { $0.probeLogOrder } == [.codex, .claude, .cursor, .augment, .amp, .ollama])
        #expect(ordered { $0.notificationSimulationOrder } == [.codex, .claude])
        #expect(ordered { $0.errorSimulationOrder } == [
            .codex, .claude, .gemini, .antigravity, .augment, .amp, .t3chat, .zoommate, .ollama,
        ])
    }

    @Test
    func `small provider capabilities preserve legacy registries`() {
        let descriptors = ProviderDescriptorRegistry.all
        #expect(Set(descriptors.filter(\.metadata.balanceOnly).map(\.id)) == [
            .deepseek, .deepinfra, .mistral, .moonshot, .poe,
        ])
        #expect(Set(descriptors.filter(\.metadata.usesDetailBackedWindow).map(\.id)) == [
            .warp, .kilo, .mistral, .deepseek, .deepinfra, .qoder, .crof, .chutes,
        ])
        #if os(macOS)
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .cursor, .vertexai, .bedrock,
        ])
        #else
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .vertexai, .bedrock,
        ])
        #endif
        #expect(Set(descriptors.filter { $0.cli.binaryLocator != nil }.map(\.id)) == [
            .codex, .claude, .gemini,
        ])

        #expect(CodexProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("codex_api_estimate_hint")])
        #expect(ClaudeProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(CursorProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(VertexAIProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("cost_estimate_hint")])
        #expect(BedrockProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("AWS Cost Explorer billing can lag."),
        ])
        #expect(OpenAIAPIProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by OpenAI Admin API organization usage."),
        ])
        #expect(MistralProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by Mistral billing usage."),
        ])
    }

    @Test
    func `cross provider case clusters are derived or specifically justified`() throws {
        let root = try Self.repoRoot()
        let files = try Self.shippedSwiftSources(root: root)
        let providerIDs = Set(UsageProvider.allCases.map(\.rawValue))
        let providerFolderNames = Set(providerIDs.map { $0.lowercased() })
        var failures: [String] = []
        var constructsByPath: [String: [AllowedProviderConstruct]] = [:]

        for construct in Self.allowedProviderConstructs {
            constructsByPath[construct.path, default: []].append(construct)
        }

        for file in files {
            if Self.isProviderImplementationPath(file.path, providerFolderNames: providerFolderNames) {
                continue
            }
            let result = Self.analyze(
                file: file,
                providerIDs: providerIDs,
                allowedConstructs: constructsByPath.removeValue(forKey: file.path) ?? [])
            failures.append(contentsOf: result)
        }

        for constructs in constructsByPath.values.flatMap(\.self) {
            failures.append("\(constructs.path): allowlisted construct file does not exist in a shipped Swift target")
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test
    func `provider reference scanner catches raw ID policy fallbacks`() {
        let source = #"let command = sender.representedObject as? String ?? "claude""#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude"])
    }

    @Test
    func `provider reference scanner ignores generic URLs and log categories`() {
        let source = #"""
        let url = "https://example.com/claude/status"
        let category = "codex"
        logger.info("claude request completed")
        """#

        #expect(Self.providerReferences(in: source, providerIDs: ["claude", "codex"]).isEmpty)
    }

    @Test
    func `provider implementation path requires a real provider folder`() {
        let folders: Set = ["claude", "codex"]

        #expect(Self.isProviderImplementationPath(
            "Sources/CodexBar/Providers/Claude/ClaudeSettings.swift",
            providerFolderNames: folders))
        #expect(!Self.isProviderImplementationPath(
            "Sources/CodexBar/Providers/Shared/ProviderHelpers.swift",
            providerFolderNames: folders))
        #expect(!Self.isProviderImplementationPath(
            "Sources/CodexBar/NotProviders/ClaudeSettings.swift",
            providerFolderNames: folders))
    }

    @Test
    func `provider clusters cannot chain beyond the fixed window`() {
        let references = [0, 10, 20, 30, 39, 40, 50, 60].map {
            ProviderReference(line: $0, providerIDs: ["codex"])
        }

        #expect(Self.providerReferenceClusters(references).map(\.lineRange) == [0...39, 40...60])
    }

    @Test
    func `one marker cannot justify two provider clusters`() {
        let source = """
        // Provider-specific by design: first fallback.
        let first = .codex













        let second = .claude
        """
        let failures = Self.analyze(
            file: SourceFile(path: "Sources/App/Shared.swift", source: source),
            providerIDs: ["claude", "codex"],
            allowedConstructs: [])

        #expect(failures.count == 1)
        #expect(failures.first?.contains(":16 ") == true)
    }

    @Test
    func `allowlisted constructs are unique and fingerprinted`() {
        let source = """
        let fallback = .codex
        """
        let construct = AllowedProviderConstruct(
            path: "Sources/App/Shared.swift",
            anchor: "let fallback = .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "The fixture verifies exact construct matching.")

        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty)
        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source + "\nlet other = .codex"),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty == false)
    }

    private struct SourceFile {
        let path: String
        let source: String
    }

    private struct ProviderReference: Equatable {
        let line: Int
        let providerIDs: Set<String>
    }

    private struct ProviderReferenceCluster {
        let references: [ProviderReference]

        var lineRange: ClosedRange<Int> {
            self.references[0].line...self.references[self.references.count - 1].line
        }

        var providerIDs: Set<String> {
            self.references.reduce(into: []) { $0.formUnion($1.providerIDs) }
        }

        var referenceCount: Int {
            self.references.reduce(0) { $0 + $1.providerIDs.count }
        }
    }

    private struct AllowedProviderConstruct {
        let path: String
        let anchor: String
        let expectedProviderIDs: Set<String>
        let expectedReferenceCount: Int
        let reason: String
    }

    private static let providerCaseMarker = "Provider-specific by design:"
    private static let providerCaseMarkerWindow = 40
    private static let providerCaseClusterGap = 12
    private static let providerCaseClusterWindow = 40

    /// Each entry names one uniquely anchored construct and pins its complete provider-reference fingerprint.
    /// Adding or removing a reference invalidates the entry instead of silently expanding an exemption.
    private static let allowedProviderConstructs: [AllowedProviderConstruct] = []

    private static func shippedSwiftSources(root: URL) throws -> [SourceFile] {
        var files: [SourceFile] = []
        for directoryName in ["Sources", "WidgetExtension"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
            let enumerator = try #require(FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                try files.append(SourceFile(path: path, source: String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func isProviderImplementationPath(
        _ path: String,
        providerFolderNames: Set<String>) -> Bool
    {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 5,
              components[0] == "Sources",
              components[2] == "Providers"
        else { return false }
        return providerFolderNames.contains(components[3].lowercased())
    }

    private static func analyze(
        file: SourceFile,
        providerIDs: Set<String>,
        allowedConstructs: [AllowedProviderConstruct]) -> [String]
    {
        let lines = file.source.components(separatedBy: .newlines)
        let references = self.providerReferences(in: file.source, providerIDs: providerIDs)
        let clusters = self.providerReferenceClusters(references)
        let markerLines = lines.indices.filter { lines[$0].contains(self.providerCaseMarker) }
        var failures: [String] = []
        var allowedClusterIndices: Set<Int> = []

        for construct in allowedConstructs {
            guard construct.path == file.path else {
                failures.append("\(construct.path): allowlisted construct was assigned to the wrong file")
                continue
            }
            guard !construct.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(file.path): allowlisted construct '\(construct.anchor)' has no written reason")
                continue
            }
            let anchorLines = lines.indices.filter { lines[$0].contains(construct.anchor) }
            guard anchorLines.count == 1, let anchorLine = anchorLines.first else {
                failures.append(
                    "\(file.path): allowlisted construct anchor '\(construct.anchor)' matched \(anchorLines.count) lines")
                continue
            }
            let candidateIndices = clusters.indices.filter { index in
                let range = clusters[index].lineRange
                return range
                    .contains(anchorLine) || (anchorLine < range.lowerBound && range.lowerBound - anchorLine < 12)
            }
            guard candidateIndices.count == 1, let clusterIndex = candidateIndices.first else {
                failures.append(
                    "\(file.path):\(anchorLine + 1) allowlisted construct anchor did not identify exactly one cluster")
                continue
            }
            let cluster = clusters[clusterIndex]
            guard cluster.providerIDs == construct.expectedProviderIDs,
                  cluster.referenceCount == construct.expectedReferenceCount
            else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) allowlisted construct fingerprint changed; " +
                        "expected \(construct.expectedProviderIDs.sorted())/\(construct.expectedReferenceCount), " +
                        "found \(cluster.providerIDs.sorted())/\(cluster.referenceCount)")
                continue
            }
            guard allowedClusterIndices.insert(clusterIndex).inserted else {
                failures.append("\(file.path):\(anchorLine + 1) multiple allowlist entries target the same construct")
                continue
            }
        }

        var usedMarkers: Set<Int> = []
        var previousClusterEnd = -1
        for (index, cluster) in clusters.enumerated() where !allowedClusterIndices.contains(index) {
            let lowerBound = max(previousClusterEnd + 1, cluster.lineRange.lowerBound - self.providerCaseMarkerWindow)
            let marker = markerLines.last { line in
                lowerBound...cluster.lineRange.lowerBound ~= line && !usedMarkers.contains(line)
            }
            if let marker {
                usedMarkers.insert(marker)
            } else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) has an unjustified provider-specific " +
                        "construct (\(cluster.providerIDs.sorted().joined(separator: ", "))); derive it or add " +
                        "'// Provider-specific by design: <specific reason>' immediately before this cluster.")
            }
            previousClusterEnd = cluster.lineRange.upperBound
        }

        return failures
    }

    private static func providerReferenceClusters(
        _ references: [ProviderReference]) -> [ProviderReferenceCluster]
    {
        guard let first = references.first else { return [] }
        var clusters: [ProviderReferenceCluster] = []
        var current = [first]
        var clusterStart = first.line
        var previous = first.line

        for reference in references.dropFirst() {
            if reference.line - previous > self.providerCaseClusterGap ||
                reference.line - clusterStart >= self.providerCaseClusterWindow
            {
                clusters.append(ProviderReferenceCluster(references: current))
                current = [reference]
                clusterStart = reference.line
            } else {
                current.append(reference)
            }
            previous = reference.line
        }
        clusters.append(ProviderReferenceCluster(references: current))
        return clusters
    }

    private static func providerReferences(in source: String, providerIDs: Set<String>) -> [ProviderReference] {
        source.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let code = self.codeBeforeLineComment(line)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var matches = Set(providerIDs.filter { self.containsDottedProviderCase($0, in: code) })
            for literal in self.quotedStringLiterals(in: code) {
                for providerID in providerIDs where self.isProviderIDLiteral(
                    providerID,
                    literal: literal,
                    line: code)
                {
                    matches.insert(providerID)
                }
            }
            return matches.isEmpty ? nil : ProviderReference(line: index, providerIDs: matches)
        }
    }

    private static func containsDottedProviderCase(_ rawValue: String, in line: String) -> Bool {
        let needle = ".\(rawValue)"
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            if range.upperBound == line.endIndex || !Self.isIdentifierCharacter(line[range.upperBound]),
               self.isProviderPolicyPosition(rawValue, range: range, line: line)
            {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isProviderPolicyPosition(
        _ rawValue: String,
        range: Range<String.Index>,
        line: String) -> Bool
    {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("case ") || trimmed.hasPrefix("switch ") ||
            trimmed.hasPrefix("if ") || trimmed.hasPrefix("guard ") ||
            trimmed.hasPrefix("else if ") || trimmed.hasPrefix("return .\(rawValue)")
        {
            return true
        }
        if ["==", "!=", "??", " ? ", ".contains(", ".filter", "rawValue"]
            .contains(where: line.contains)
        {
            return true
        }
        if prefix.isEmpty, suffix.hasPrefix(":") || suffix.hasPrefix(",") || suffix.isEmpty {
            return true
        }
        if prefix.hasSuffix("=") || prefix.hasSuffix("[") || prefix.hasSuffix(",") {
            return true
        }
        return suffix.hasPrefix(":")
    }

    private static func isProviderIDLiteral(_ providerID: String, literal: String, line: String) -> Bool {
        let lowercasedLiteral = literal.lowercased()
        guard self.containsWord(providerID, in: lowercasedLiteral) else { return false }
        let lowercasedLine = line.lowercased()
        if ["http://", "https://", "logger", "log.", "category"].contains(where: lowercasedLine.contains) {
            return false
        }
        if lowercasedLiteral == providerID {
            return true
        }
        return ["provider", "rawvalue", "representedobject", "command", "fallback", "default", "selected"]
            .contains(where: lowercasedLine.contains)
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let hasLeftBoundary = range.lowerBound == text.startIndex ||
                !self.isIdentifierCharacter(text[text.index(before: range.lowerBound)])
            let hasRightBoundary = range.upperBound == text.endIndex ||
                !self.isIdentifierCharacter(text[range.upperBound])
            if hasLeftBoundary, hasRightBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func quotedStringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var isInsideString = false
        var isEscaped = false
        for character in line {
            if isInsideString {
                if isEscaped {
                    current.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    literals.append(current)
                    current = ""
                    isInsideString = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                isInsideString = true
            }
        }
        return literals
    }

    private static func codeBeforeLineComment(_ line: String) -> String {
        var previous: Character?
        var isInsideString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if character == "/", !isInsideString {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[..<index])
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path(percentEncoded: false))
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func hash(_ color: ProviderColor, into fingerprint: inout UInt64) {
        for component in [color.red, color.green, color.blue] {
            var bits = component.bitPattern
            for _ in 0..<MemoryLayout<UInt64>.size {
                fingerprint = (fingerprint ^ UInt64(UInt8(truncatingIfNeeded: bits))) &* 1_099_511_628_211
                bits >>= 8
            }
        }
    }

    private static func hash(_ bytes: String.UTF8View, into fingerprint: inout UInt64) {
        for byte in bytes {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
