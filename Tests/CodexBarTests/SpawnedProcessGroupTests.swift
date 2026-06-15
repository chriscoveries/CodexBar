import Foundation
import Testing
@testable import CodexBarCore

struct SpawnedProcessGroupTests {
    @Test
    func `pipe cleanup preserves standard descriptors`() {
        let descriptors = SpawnedProcessGroup.pipeDescriptorsToClose([0, 1, 2, 3, 4, 3])

        #expect(descriptors == [3, 4])
    }

    @Test
    func `launch captures child output`() async throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCapture = ProcessPipeCapture(pipe: stdoutPipe)
        let stderrCapture = ProcessPipeCapture(pipe: stderrPipe)
        stdoutCapture.start()
        stderrCapture.start()

        let process = try SpawnedProcessGroup.launch(
            binary: "/bin/sh",
            arguments: ["-c", "printf stdout-value; printf stderr-value >&2"],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        await process.terminateResidualGroup()

        async let stdout = stdoutCapture.finish(timeout: .seconds(1))
        async let stderr = stderrCapture.finish(timeout: .seconds(1))
        let output = await (stdout, stderr)

        #expect(process.terminationStatus == 0)
        #expect(String(data: output.0, encoding: .utf8) == "stdout-value")
        #expect(String(data: output.1, encoding: .utf8) == "stderr-value")
    }
}
