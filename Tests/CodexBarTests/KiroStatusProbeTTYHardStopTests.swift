import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if DEBUG
extension KiroStatusProbeTests {
    @Test
    func `tty runner bounds hard stop while cleaning a double forked PTY holder`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-double-fork-\(UUID().uuidString).pid")
        let termChildPIDFile = childPIDFile.appendingPathExtension("term-child")
        let lateChildPIDFile = childPIDFile.appendingPathExtension("late-child")
        let cliURL = try self.makeHardStopCLI()
        defer {
            for pidFile in [childPIDFile, termChildPIDFile, lateChildPIDFile] {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                   let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    _ = kill(childPID, SIGKILL)
                }
                try? FileManager.default.removeItem(at: pidFile)
            }
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
        }

        let start = Date()
        let result = try SpawnedProcessGroup.withOutputHolderDiscoveryDelayForTesting(4) {
            try SpawnedProcessGroup.withOutputHolderPreKillDelayForTesting(0.5) {
                try TTYCommandRunner().run(
                    binary: cliURL.path,
                    send: "",
                    options: .init(
                        timeout: 4,
                        idleTimeout: 0.1,
                        extraArgs: [childPIDFile.path, termChildPIDFile.path, lateChildPIDFile.path],
                        initialDelay: 0,
                        settleAfterStop: 0))
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("PTY hard-stop latency: \(String(format: "%.3f", elapsed))s")

        #expect(result.completion == .idleTimeout)
        let snapshot = try KiroStatusProbe().parse(output: result.text)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        #expect(elapsed < 3, "Delayed holder discovery should not extend the PTY hard stop, took \(elapsed)s")

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: termChildPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let termChildPIDText = try String(contentsOf: termChildPIDFile, encoding: .utf8)
        let termChildPID = try #require(pid_t(termChildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: lateChildPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lateChildPIDText = try String(contentsOf: lateChildPIDFile, encoding: .utf8)
        let lateChildPID = try #require(pid_t(lateChildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))

        let cleanupDeadline = Date().addingTimeInterval(20)
        while kill(childPID, 0) == 0 || kill(termChildPID, 0) == 0 || kill(lateChildPID, 0) == 0,
              Date() < cleanupDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1)
        #expect(kill(termChildPID, 0) == -1)
        #expect(kill(lateChildPID, 0) == -1)
    }

    private func makeHardStopCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-cli-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        let script = """
        #!/usr/bin/python3
        import os
        import signal
        import sys
        import time

        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        intermediate = os.fork()
        if intermediate == 0:
            child = os.fork()
            if child > 0:
                os._exit(0)
            os.setsid()
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            def handle_term(_signal, _frame):
                term_child = os.fork()
                if term_child == 0:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    with open(sys.argv[2], "w") as handle:
                        handle.write(str(os.getpid()))
                    time.sleep(0.35)
                    late_child = os.fork()
                    if late_child == 0:
                        with open(sys.argv[3], "w") as handle:
                            handle.write(str(os.getpid()))
                        time.sleep(30)
                        os._exit(0)
                    time.sleep(30)
                    os._exit(0)
                time.sleep(0.2)
                os._exit(0)
            signal.signal(signal.SIGTERM, handle_term)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)

        os.waitpid(intermediate, 0)
        while not os.path.exists(sys.argv[1]):
            time.sleep(0.01)
        print("Estimated Usage | resets on 2026-06-01 | KIRO FREE", flush=True)
        print("Credits (12.50 of 50 covered in plan)", flush=True)
        print("████████████████████ 25%", flush=True)
        time.sleep(30)
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }
}
#endif
