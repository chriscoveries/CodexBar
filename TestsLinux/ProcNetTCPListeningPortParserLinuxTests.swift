import CodexBarCore
import Foundation
import Testing

/// Tests for the `/proc/net/tcp` listening-port parser used on Linux as a
/// fallback for Antigravity CLI port detection when `lsof` is unavailable.
@Suite
struct ProcNetTCPListeningPortParserLinuxTests {
    // Two loopback LISTEN sockets (inodes 111111, 222222) and one established
    // connection (inode 333333, st 01) that must be ignored.
    private static let sample = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111111 1 0000000000000000 100 0 0 10 0
           1: 0100007F:C000 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222222 1 0000000000000000 100 0 0 10 0
           2: 0100007F:1F91 0100007F:E1F0 01 00000000:00000000 00:00000000 00000000  1000        0 333333 1 0000000000000000 100 0 0 10 0
        """

    @Test
    func returnsListeningPortsForOwnedSocketInodes() {
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["111111", "222222"])
        #expect(ports == [8080, 49152])
    }

    @Test
    func ignoresListeningSocketsOwnedByOtherProcesses() {
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["999999"])
        #expect(ports.isEmpty)
    }

    @Test
    func ignoresNonListeningSockets() {
        // inode 333333 is an established (st 01) socket, not LISTEN.
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["333333"])
        #expect(ports.isEmpty)
    }

    @Test
    func parsesSocketInodeFromFDSymlinkDestination() {
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "socket:[12345]") == "12345")
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "/dev/pts/0") == nil)
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "anon_inode:[eventpoll]") == nil)
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "socket:[]") == nil)
    }
}
