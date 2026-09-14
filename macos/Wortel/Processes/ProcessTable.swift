import Darwin
import Foundation

/// One process, as the kernel describes it in a single `sysctl` sweep.
///
/// `pgid` is the load-bearing field. A job — `bun dev:web`, `npm run dev`, an
/// agent — is not a subtree, it is a **process group**: an interactive shell
/// puts each job it starts into its own group, and so does every `zsh -c` an
/// agent spawns for its own shell tool. Measured on a real session, `zsh -c`
/// (15614) led `bun → bun → node → workerd` all at pgid 15614, while the agent
/// sat at 37616 and the session's own shell at 37499. That separation is what
/// makes `kill(-pgid, …)` a safe thing to offer: it provably cannot reach the
/// agent or the shell, because they are not in the group.
struct ProcessEntry: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    /// `p_comm`, which the kernel truncates to `MAXCOMLEN`. Useless as a label
    /// (a real tree here read `2.1.267`, `bun`, `bun`, `node`, `node`,
    /// `workerd`) but fine for the name matching `AgentLiveness` does.
    let name: String
    let startedAt: Date
}

/// Everything this app asks the kernel about other processes, in one place.
///
/// All of it is `sysctl` and `libproc`: no `ps`, no `lsof`, no helper tool, and
/// no entitlement beyond being unsandboxed. A full table plus argv, footprint
/// and listening ports for a fourteen-process tree measured 2.8 ms, which is why
/// nothing here is cached and callers are free to ask again.
///
/// The split from `RunningJobs` is deliberate: this file is untestable by
/// construction (it asks the machine what is true), so it holds *only* the
/// syscalls. Every decision made from the answers lives next door, where it can
/// be fed a fixture.
enum ProcessTable {
    /// `p_comm` is truncated to `MAXCOMLEN`, so name comparisons must be too.
    static let maxCommandNameLength = 16

    /// Every process visible to this user, in one `sysctl`.
    ///
    /// Empty when the table can't be read, which callers must treat as "no
    /// claim" rather than "nothing is running" — the same fail-open rule
    /// `AgentLiveness` already applies to its own question.
    static func snapshot() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between sizing and reading; over-allocate a little
        // so a process spawned in that window doesn't truncate the result.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).map { proc in
            var proc = proc
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let started = proc.kp_proc.p_un.__p_starttime
            return ProcessEntry(
                pid: proc.kp_proc.p_pid,
                ppid: proc.kp_eproc.e_ppid,
                pgid: proc.kp_eproc.e_pgid,
                uid: proc.kp_eproc.e_ucred.cr_uid,
                name: name,
                startedAt: Date(timeIntervalSince1970:
                    Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000))
        }
    }

    /// The process's argument vector via `KERN_PROCARGS2`, executable path first.
    ///
    /// This is where a job's *meaning* lives — `p_comm` says `bun`, the argv says
    /// `bun dev:web` — so the label reader depends on it entirely.
    ///
    /// Empty when it can't be read (another user's process, or one that exited
    /// between the table and this call), which callers treat as "nothing known",
    /// never as an error.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // Layout: argc (Int32), the executable path, NUL padding, then argc
        // NUL-terminated arguments (followed by the environment, not wanted).
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var strings: [String] = []
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let s = String(decoding: buffer[start..<index], as: UTF8.self)
            while index < size, buffer[index] == 0 { index += 1 } // NUL(s) after
            return s
        }
        guard let executable = readString() else { return [] }
        strings.append(executable)
        for _ in 0..<argc {
            guard let arg = readString() else { break }
            strings.append(arg)
        }
        return strings
    }

    /// Physical footprint in bytes: the number Activity Monitor calls "Memory",
    /// and the only one worth showing.
    ///
    /// **Not RSS.** On a machine with memory pressure the two diverge wildly
    /// because compressed and swapped pages leave the resident set: `ps` reported
    /// a real vite process here at 30 MB while its footprint was 572 MB, a 19x
    /// gap. Reporting RSS is precisely why "why is my memory gone" is invisible
    /// to every tool you would otherwise reach for.
    ///
    /// nil when the process is gone or belongs to someone else.
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// TCP ports this process is listening on, unfiltered and in no order.
    ///
    /// Walks the process's open descriptors and asks each socket for its state,
    /// which is what `lsof -iTCP -sTCP:LISTEN` does and needs no more privilege
    /// than `lsof` does for your own processes.
    ///
    /// "Unfiltered" matters: a single dev server here held `:3000` alongside
    /// `:9231` and `:49748`, and only the first means anything to a person.
    /// Deciding which to show is `RunningJobs`' job, not this one's.
    static func listeningPorts(of pid: pid_t) -> [Int] {
        let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeNeeded > 0 else { return [] }
        // Over-allocate for the same reason the table does: descriptors open
        // between the sizing call and the read.
        let capacity = Int(sizeNeeded) / MemoryLayout<proc_fdinfo>.stride + 8
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return [] }

        var ports: [Int] = []
        for descriptor in descriptors.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                      Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // `insi_lport` is in network byte order, and is only ever a uint16.
            let raw = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
            let port = Int(UInt16(truncatingIfNeeded: raw).byteSwapped)
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    /// The process's current working directory.
    ///
    /// This is the whole of orphan attribution. A dev server that outlived its
    /// session reparents to `launchd` and loses every link back to the terminal
    /// that started it — except this, which still reads
    /// `…/gielcobben-2026/workers/images` four days later. It means no marker
    /// has to be written at spawn time, and so the shell integration (three
    /// copies, one of them untestable here) is left alone entirely.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let read = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                                Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard read == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Walk up the parent chain, bounded so a cycle in a torn process table
    /// can't spin here — this runs on the main thread during termination.
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t,
                             parentOf: [pid_t: pid_t]) -> Bool {
        var current = pid
        for _ in 0..<64 {
            guard let parent = parentOf[current], parent > 0 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
