import Foundation

public struct ProviderCLIConfig: Sendable {
    public typealias BrowserSupportExemption = @Sendable (
        _ sourceMode: ProviderSourceMode,
        _ environment: [String: String]?,
        _ settings: ProviderSettingsSnapshot?) -> Bool

    public let name: String
    public let aliases: [String]
    public let binaryLocator: (@Sendable () -> String?)?
    public let versionDetector: (@Sendable (BrowserDetection) -> String?)?
    private let browserSupportExemption: BrowserSupportExemption

    public init(
        name: String,
        aliases: [String] = [],
        binaryLocator: (@Sendable () -> String?)? = nil,
        versionDetector: (@Sendable (BrowserDetection) -> String?)?,
        browserSupportExemption: @escaping BrowserSupportExemption = { _, _, _ in false })
    {
        self.name = name
        self.aliases = aliases
        self.binaryLocator = binaryLocator
        self.versionDetector = versionDetector
        self.browserSupportExemption = browserSupportExemption
    }

    public func isBrowserSupportExempt(
        sourceMode: ProviderSourceMode,
        environment: [String: String]?,
        settings: ProviderSettingsSnapshot?) -> Bool
    {
        self.browserSupportExemption(sourceMode, environment, settings)
    }
}
