import CodexBarCore
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

struct ShellCommandLocatorCleanupTests {
    @Test
    func `normal completion escalates stuck helper cleanup`() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-shell-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pidFile = tempDirectory.appendingPathComponent("helper.pid")
        let shellScript = tempDirectory.appendingPathComponent("shell-with-stuck-helper")
        let quotedPidFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        (trap '' TERM; while :; do sleep 5; done) &
        printf '%s\\n' "$!" > '\(quotedPidFile)'
        printf '/bin/sh\\n'
        """
        try script.write(to: shellScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellScript.path)

        let resolved = ShellCommandLocator.commandV("codex", shellScript.path, 2.0, FileManager.default)
        #expect(resolved == "/bin/sh")

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let helperPid = try #require(pid_t(pidText))
        defer { kill(helperPid, SIGKILL) }

        #expect(self.waitUntilProcessExits(helperPid), "Expected TERM-resistant shell-init helper to be SIGKILLed")
    }

    private func waitUntilProcessExits(_ pid: pid_t) -> Bool {
        for _ in 0..<20 {
            if !self.processExists(pid) {
                return true
            }
            usleep(50000)
        }
        return false
    }

    private func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
