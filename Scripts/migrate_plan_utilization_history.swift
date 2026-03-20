#!/usr/bin/env swift

import Darwin
import Foundation

private struct ProviderHistoryFile: Codable {
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
}

private struct LegacyPlanUtilizationHistoryFile: Codable {
    let version: Int
    let providers: [String: ProviderHistoryFile]
}

private struct ProviderHistoryDocument: Codable {
    let version: Int
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
}

private struct PlanUtilizationSeriesHistory: Codable {
    let name: String
    let windowMinutes: Int
    let entries: [PlanUtilizationHistoryEntry]
}

private struct PlanUtilizationHistoryEntry: Codable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

private enum MigrationError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case unsupportedLegacyVersion(Int)
    case providerFilesAlreadyExist(URL)

    var description: String {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .unsupportedLegacyVersion(version):
            return "Unsupported legacy history schema version \(version)."
        case let .providerFilesAlreadyExist(url):
            return "Provider history files already exist in \(url.path). Re-run with --force to overwrite."
        }
    }
}

private struct Arguments {
    let rootURL: URL
    let force: Bool

    static func parse() throws -> Arguments {
        var rootURL = Self.defaultRootURL()
        var force = false
        var index = 1

        while index < CommandLine.arguments.count {
            let argument = CommandLine.arguments[index]
            switch argument {
            case "--root":
                let nextIndex = index + 1
                guard nextIndex < CommandLine.arguments.count else {
                    throw MigrationError.invalidArguments("Missing path after --root.")
                }
                rootURL = URL(fileURLWithPath: CommandLine.arguments[nextIndex], isDirectory: true)
                index += 2
            case "--force":
                force = true
                index += 1
            case "--help", "-h":
                Self.printUsage()
                exit(0)
            default:
                throw MigrationError.invalidArguments("Unknown argument: \(argument)")
            }
        }

        return Arguments(rootURL: rootURL, force: force)
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
    }

    private static func printUsage() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("Usage: \(executable) [--root <app-support-dir>] [--force]")
    }
}

private let legacySchemaVersion = 6
private let providerSchemaVersion = 1

private func loadLegacyHistory(from legacyURL: URL) throws -> LegacyPlanUtilizationHistoryFile {
    let data = try Data(contentsOf: legacyURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(LegacyPlanUtilizationHistoryFile.self, from: data)
    guard decoded.version == legacySchemaVersion else {
        throw MigrationError.unsupportedLegacyVersion(decoded.version)
    }
    return decoded
}

private func providerHistoryURLs(in directoryURL: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    else {
        return []
    }

    return contents.filter { $0.pathExtension == "json" }
}

private func archiveURL(for legacyURL: URL) -> URL {
    let directoryURL = legacyURL.deletingLastPathComponent()
    let basename = legacyURL.deletingPathExtension().lastPathComponent
    let archiveBaseURL = directoryURL.appendingPathComponent("\(basename).legacy", isDirectory: false)
    let archiveURL = archiveBaseURL.appendingPathExtension("json")
    if !FileManager.default.fileExists(atPath: archiveURL.path) {
        return archiveURL
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let timestamp = formatter.string(from: Date())
    return directoryURL
        .appendingPathComponent("\(basename).legacy-\(timestamp)", isDirectory: false)
        .appendingPathExtension("json")
}

private func migrate(arguments: Arguments) throws {
    let rootURL = arguments.rootURL
    let legacyURL = rootURL.appendingPathComponent("plan-utilization-history.json", isDirectory: false)
    let historyDirectoryURL = rootURL.appendingPathComponent("history", isDirectory: true)

    guard FileManager.default.fileExists(atPath: legacyURL.path) else {
        print("No legacy plan utilization history found at \(legacyURL.path).")
        return
    }

    let existingProviderFiles = providerHistoryURLs(in: historyDirectoryURL)
    if !existingProviderFiles.isEmpty, !arguments.force {
        throw MigrationError.providerFilesAlreadyExist(historyDirectoryURL)
    }

    let legacy = try loadLegacyHistory(from: legacyURL)
    try FileManager.default.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
    if arguments.force {
        for url in existingProviderFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    var migratedProviders: [String] = []
    for (provider, history) in legacy.providers.sorted(by: { $0.key < $1.key }) {
        let payload = ProviderHistoryDocument(
            version: providerSchemaVersion,
            preferredAccountKey: history.preferredAccountKey,
            unscoped: history.unscoped,
            accounts: history.accounts)
        let data = try encoder.encode(payload)
        let providerURL = historyDirectoryURL.appendingPathComponent("\(provider).json", isDirectory: false)
        try data.write(to: providerURL, options: [.atomic])
        migratedProviders.append(provider)
    }

    let archivedLegacyURL = archiveURL(for: legacyURL)
    try FileManager.default.moveItem(at: legacyURL, to: archivedLegacyURL)

    if migratedProviders.isEmpty {
        print("Migrated empty legacy history. Archived legacy file to \(archivedLegacyURL.path).")
    } else {
        print("Migrated providers: \(migratedProviders.joined(separator: ", ")).")
        print("Archived legacy file to \(archivedLegacyURL.path).")
        print("Provider history directory: \(historyDirectoryURL.path)")
    }
}

do {
    let arguments = try Arguments.parse()
    try migrate(arguments: arguments)
} catch let error as MigrationError {
    fputs("ERROR: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
