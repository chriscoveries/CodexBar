import CodexBarCore
import Foundation
import Testing

struct TailscaleSessionTests {
    @Test
    func `online mac and linux peers become hosts`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-sessions-tailscale", extension: "json")
        let hosts = try TailscaleStatusParser.hosts(
            from: Data(contentsOf: url),
            excludingLocalHost: "local-mac")

        #expect(hosts == ["clawmac", "linuxbox"])
    }

    @Test
    func `binary candidates prefer the CLI wrapper over the app binary`() throws {
        // A GUI-launched app inherits a minimal PATH that omits the CLI locations.
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/usr/bin:/bin")

        // The standard wrapper locations are still probed, ahead of the app binary…
        #expect(candidates.contains("/usr/local/bin/tailscale"))
        #expect(candidates.contains("/opt/homebrew/bin/tailscale"))
        // …and the dual-mode app binary is the last resort.
        #expect(candidates.last == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(try #require(candidates.firstIndex(of: "/usr/local/bin/tailscale")) < candidates.count - 1)
    }

    @Test
    func `binary candidates keep PATH entries first and dedupe well-known dirs`() {
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/opt/homebrew/bin:/usr/bin")

        #expect(candidates.first == "/opt/homebrew/bin/tailscale")
        #expect(candidates.count(where: { $0 == "/opt/homebrew/bin/tailscale" }) == 1)
    }

    @Test
    func `cli environment injects a shell marker for the app-binary fallback`() {
        // Without a marker the dual-mode binary launches the GUI instead of the CLI.
        let env = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["PATH": "/usr/bin"])

        #expect(env["SHLVL"] == "1")
    }

    @Test
    func `cli environment preserves an existing terminal context`() {
        // Already CLI-safe: leave TERM alone and don't fabricate a SHLVL…
        let withTerm = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["TERM": "xterm-256color"])
        #expect(withTerm["SHLVL"] == nil)

        // …and never clobber a caller-provided SHLVL.
        let withShlvl = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["SHLVL": "3"])
        #expect(withShlvl["SHLVL"] == "3")
    }

    @Test
    func `ssh destinations reject options whitespace and controls`() {
        let hosts = RemoteSessionFetcher.sanitizedHosts([
            "user@clawmac",
            "USER@CLAWMAC",
            "-oProxyCommand=touch /tmp/unsafe",
            "host with-space",
            "host\nother",
            "linuxbox",
        ])

        #expect(hosts == ["user@clawmac", "linuxbox"])
    }
}
