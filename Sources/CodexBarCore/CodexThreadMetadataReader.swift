#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation

public struct CodexThreadMetadata: Equatable, Sendable {
    public let title: String?
    public let agentPath: String?

    public init(title: String?, agentPath: String?) {
        self.title = title
        self.agentPath = agentPath
    }
}

public struct CodexThreadMetadataReader: Sendable {
    public let databaseURL: URL

    public init(codexHomeDirectory: URL, fileManager: FileManager = .default) {
        let candidates = (try? fileManager.contentsOfDirectory(
            at: codexHomeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        self.databaseURL = candidates
            .filter { $0.pathExtension == "sqlite" && $0.deletingPathExtension().lastPathComponent.hasPrefix("state_") }
            .max { Self.stateVersion($0) < Self.stateVersion($1) }
            ?? codexHomeDirectory.appendingPathComponent("state_5.sqlite")
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func metadata(for sessionIDs: Set<String>) -> [String: CodexThreadMetadata] {
        guard !sessionIDs.isEmpty else { return [:] }
        #if canImport(SQLite3) || canImport(CSQLite3)
        var database: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        let queries = [
            "SELECT title, agent_path FROM threads WHERE id = ?1 LIMIT 1",
            "SELECT title, NULL FROM threads WHERE id = ?1 LIMIT 1",
        ]
        var statement: OpaquePointer?
        for query in queries where statement == nil {
            if sqlite3_prepare_v2(database, query, -1, &statement, nil) != SQLITE_OK {
                statement = nil
            }
        }
        guard let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result: [String: CodexThreadMetadata] = [:]
        for sessionID in sessionIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, sessionID, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            let title = Self.string(statement, column: 0)
            let agentPath = Self.string(statement, column: 1)
            if title != nil || agentPath != nil {
                result[sessionID] = CodexThreadMetadata(title: title, agentPath: agentPath)
            }
        }
        return result
        #else
        return [:]
        #endif
    }

    private static func stateVersion(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("state_".count)) ?? 0
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
    #endif
}
