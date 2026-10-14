import Darwin
import Foundation

/// Ten TCP ports of a session's own, so dev servers in parallel worktrees
/// don't fight over :3000.
///
/// A worktree isolates files, not the machine: two agents each running
/// `npm run dev` in their own checkout still collide on one port, and the
/// second one either fails or quietly moves somewhere nobody looks. Every
/// session's shell gets `WORTEL_PORT`, the first of a block of ten nobody else
/// in Wortel holds, plus `CONDUCTOR_PORT` with the same value: Conductor
/// reserves the same "first of ten" per workspace, so a repository whose
/// scripts already say `--port $CONDUCTOR_PORT` works here unchanged.
///
/// `PORT` itself is deliberately not set. Next, Express, Rails and Vite all
/// read it, so setting it would move every dev server in every session off
/// the port its README names, which is a worse surprise than a collision.
///
/// The block is chosen once, when the session is made, and kept with the
/// session from then on (`sessions.json`). It is never re-checked: after a
/// relaunch the session's own server may well be the thing listening there.
enum PortBlock {
    /// Where blocks come from: above the usual dev-server and database ports,
    /// below the ephemeral range macOS hands out (49152 up).
    static let range = 20_000..<30_000
    static let size = 10

    /// Well-known ports inside `range` a block must not include: Barrier and
    /// Synergy, Minecraft, Redis Sentinel, MongoDB and its HTTP console.
    static let avoided: Set<Int> = [24_800, 25_565, 26_379, 27_017, 27_018, 27_019, 28_017]

    static var blockCount: Int { range.count / size }

    /// The environment a session's shells get for the block starting at `base`.
    static func environment(base: Int?) -> [String: String] {
        guard let base else { return [:] }
        return ["WORTEL_PORT": String(base), "CONDUCTOR_PORT": String(base)]
    }

    /// The first port of a free block for session `id`, or nil when every
    /// block is taken.
    ///
    /// The search starts at a block derived from the id, so the same session
    /// asks for the same block first (stable, without having to be stored to
    /// be), and then walks forward, wrapping. A block is skipped when another
    /// session holds it (`taken`, block starts), when it contains an
    /// `avoided` port, or when `isFree` says any of its ports is in use.
    static func allocate(for id: UUID, taken: Set<Int>, isFree: (Int) -> Bool) -> Int? {
        let start = Int(digest(id) % UInt64(blockCount))
        for step in 0..<blockCount {
            let base = range.lowerBound + ((start + step) % blockCount) * size
            let ports = base..<(base + size)
            guard !taken.contains(base), avoided.isDisjoint(with: ports) else { continue }
            if ports.allSatisfy(isFree) { return base }
        }
        return nil
    }

    /// FNV-1a over the id's bytes. Not `hashValue`, which Swift seeds per
    /// process, so it would give a session a different first choice every
    /// launch.
    static func digest(_ id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    /// Whether nothing on this machine is listening on TCP `port`, asked the
    /// only way that answers for every user's processes: by trying to bind it,
    /// on IPv4 and IPv6. No `SO_REUSEADDR`, so a port a server let go of a
    /// moment ago still counts as taken, which is the cautious answer. Twenty
    /// binds a block.
    static func isFree(_ port: Int) -> Bool {
        canBind(port, family: AF_INET) && canBind(port, family: AF_INET6)
    }

    private static func canBind(_ port: Int, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return true } // no such stack here: nothing can hold it
        defer { close(fd) }
        let result: Int32
        if family == AF_INET6 {
            // Only the v6 side, so a v4 listener isn't counted twice and a
            // v6-only listener isn't missed.
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == 0 || errno != EADDRINUSE
    }
}
