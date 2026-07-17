import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runCookieRefresh(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let rawProvider = values.options["provider"]?.last
        let refreshAll = values.flags.contains("all")

        guard rawProvider != nil || refreshAll else {
            Self.exit(
                code: .failure,
                message: "Specify --provider <name> or --all.",
                output: output,
                kind: .args)
        }

        #if os(macOS)
        let browserDetection = BrowserDetection()

        if refreshAll {
            // Only refresh providers with dedicated browser-cookie importers
            let supported: [UsageProvider] = [.opencodego, .opencode]
            var results: [CookieRefreshResult] = []
            for provider in supported {
                let result = Self.refreshCookie(provider: provider, browserDetection: browserDetection)
                results.append(result)
            }
            Self.printCookieRefreshResults(results, format: output.format, pretty: output.pretty)
            let hasErrors = results.contains(where: { $0.error != nil })
            Self.exit(code: hasErrors ? .failure : .success, output: output, kind: .runtime)
        } else if let rawProvider {
            guard let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()] else {
                Self.exit(
                    code: .failure,
                    message: "Unknown provider: \(rawProvider)",
                    output: output,
                    kind: .args)
            }
            guard let descriptor = ProviderDescriptorRegistry.all.first(where: { $0.id == provider }),
                  descriptor.metadata.browserCookieOrder != nil else {
                Self.exit(
                    code: .failure,
                    message: "\(rawProvider) does not use browser cookie authentication.",
                    output: output,
                    kind: .args)
            }
            let result = Self.refreshCookie(provider: provider, browserDetection: browserDetection)
            Self.printCookieRefreshResults([result], format: output.format, pretty: output.pretty)
            Self.exit(code: result.error != nil ? .failure : .success, output: output, kind: .runtime)
        }
        #else
        Self.exit(
            code: .failure,
            message: "Cookie refresh is only supported on macOS.",
            output: output,
            kind: .args)
        #endif
    }

    #if os(macOS)
    private static func refreshCookie(provider: UsageProvider, browserDetection: BrowserDetection) -> CookieRefreshResult {
        let clearSummary = CookieHeaderCache.clearAllScopesDetailed(provider: provider)
        if clearSummary.failedCount > 0, clearSummary.clearedCount == 0 {
            return CookieRefreshResult(
                provider: provider.rawValue,
                status: "failed",
                source: nil,
                error: "Failed to clear cookie cache.")
        }

        do {
            let session = try Self.importSession(for: provider, browserDetection: browserDetection)
            CookieHeaderCache.store(
                provider: provider,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return CookieRefreshResult(
                provider: provider.rawValue,
                status: "refreshed",
                source: session.sourceLabel,
                error: nil)
        } catch {
            let detail = error.localizedDescription
            return CookieRefreshResult(
                provider: provider.rawValue,
                status: "cleared",
                source: nil,
                error: "Cache cleared. \(detail) CodexBar will re-import from your browser on next refresh (or click the menu bar). Verify with: security find-generic-password -a \"cookie.\(provider.rawValue)\" -s \"com.steipete.codexbar.cache\" -w | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[\"storedAt\"])'")
        }
    }

    private static func importSession(for provider: UsageProvider, browserDetection: BrowserDetection) throws -> OpenCodeCookieImporter.SessionInfo {
        switch provider {
        case .opencodego, .opencode:
            return try OpenCodeCookieImporter.importSession(
                browserDetection: browserDetection,
                preferredBrowsers: [])
        default:
            throw CookieRefreshError.noImporterForProvider(provider.rawValue)
        }
    }

    private static func printCookieRefreshResults(_ results: [CookieRefreshResult], format: OutputFormat, pretty: Bool) {
        switch format {
        case .text:
            for result in results {
                if let error = result.error {
                    if result.status == "cleared" {
                        print("\(result.provider): ⚠️ cache cleared, re-import pending — \(error)")
                    } else {
                        print("\(result.provider): ❌ \(error)")
                    }
                } else if let source = result.source {
                    print("\(result.provider): ✅ refreshed from \(source)")
                }
            }
        case .json:
            Self.printJSON(results, pretty: pretty)
        }
    }
    #endif
}

private struct CookieRefreshResult: Encodable {
    let provider: String
    let status: String
    let source: String?
    let error: String?
}

private enum CookieRefreshError: LocalizedError {
    case noImporterForProvider(String)

    var errorDescription: String? {
        switch self {
        case let .noImporterForProvider(provider):
            "No browser cookie importer available for \(provider). Cache cleared; next fetch will re-import."
        }
    }
}

struct CookieOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Flag(name: .long("json"), help: "Output as JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Output as JSON only (no text)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: String?

    @Flag(name: .long("all"), help: "Refresh cookies for OpenCode and OpenCode Go providers")
    var all: Bool = false

    @Option(name: .long("provider"), help: "Refresh cookie for a specific provider (e.g. opencodego)")
    var provider: String?
}
