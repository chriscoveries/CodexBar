import Foundation

/// A user-configured hook: when `event` fires (optionally scoped to `provider`
/// and, for `quotaLow`, gated by `threshold`), run `executable` with `arguments`.
public struct HookRule: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity for SwiftUI list editing; defaults to a fresh UUID string.
    public var id: String
    public var enabled: Bool
    public var event: HookEventType
    /// Provider raw value (e.g. "codex"). Nil matches any provider.
    public var provider: String?
    /// For `quotaLow`: fire only when `usagePercent >= threshold` (0...1). Ignored otherwise.
    public var threshold: Double?
    public var executable: String
    public var arguments: [String]
    public var timeoutSeconds: Double

    public static let defaultTimeoutSeconds: Double = 10

    public init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        event: HookEventType,
        provider: String? = nil,
        threshold: Double? = nil,
        executable: String,
        arguments: [String] = [],
        timeoutSeconds: Double = HookRule.defaultTimeoutSeconds)
    {
        self.id = id
        self.enabled = enabled
        self.event = event
        self.provider = provider
        self.threshold = threshold
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.event = try container.decode(HookEventType.self, forKey: .event)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.threshold = try container.decodeIfPresent(Double.self, forKey: .threshold)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? Self.defaultTimeoutSeconds
    }

    /// True when this rule should run for the given event.
    ///
    /// Requires an absolute executable path: hook commands are never resolved via
    /// PATH or a shell, so a relative path can never match.
    public func matches(_ event: HookEvent) -> Bool {
        guard self.enabled else { return false }
        guard self.event == event.event else { return false }
        guard (self.executable as NSString).isAbsolutePath else { return false }
        if let provider = self.provider, provider != event.provider { return false }
        if self.event == .quotaLow, let threshold = self.threshold {
            guard let usage = event.usagePercent, usage >= threshold else { return false }
        }
        return true
    }
}

/// The top-level `hooks` section of the shared CodexBar config. Absent or
/// `enabled == false` means hooks never run.
public struct HooksConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var events: [HookRule]

    public init(enabled: Bool = false, events: [HookRule] = []) {
        self.enabled = enabled
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.events = try container.decodeIfPresent([HookRule].self, forKey: .events) ?? []
    }

    /// Enabled rules that match the event. Returns nothing when hooks are disabled.
    public func matchingRules(for event: HookEvent) -> [HookRule] {
        guard self.enabled else { return [] }
        return self.events.filter { $0.matches(event) }
    }
}
