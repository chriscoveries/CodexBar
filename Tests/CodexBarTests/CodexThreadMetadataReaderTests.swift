import CodexBarCore
import Foundation
import SQLite3
import Testing

struct CodexThreadMetadataReaderTests {
    @Test
    func `reader loads titles and agent paths without writing to codex state`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state_5.sqlite")
        try Self.createDatabase(at: databaseURL)

        let metadata = CodexThreadMetadataReader(databaseURL: databaseURL).metadata(for: ["main", "subagent"])

        #expect(metadata["main"] == CodexThreadMetadata(title: "Fix Claude reauthorization", agentPath: nil))
        #expect(metadata["subagent"] == CodexThreadMetadata(
            title: "Inherited parent title",
            agentPath: "/root/neon_patch_review2"))
    }

    private static func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteError.open
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, agent_path TEXT);
        INSERT INTO threads VALUES ('main', 'Fix Claude reauthorization', NULL);
        INSERT INTO threads VALUES ('subagent', 'Inherited parent title', '/root/neon_patch_review2');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.exec
        }
    }

    private enum SQLiteError: Error {
        case open
        case exec
    }
}
