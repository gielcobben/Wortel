import Foundation

/// Throwaway git repos for the tests to read, plus the `git` queries used as an
/// oracle.
///
/// The graph and ordering code exists to reproduce what `git log --graph` and
/// `git log --topo-order` show, only windowed and fast. That makes git itself
/// the right thing to assert against: these tests build a repo, run both, and
/// compare. Hand-written expectations would only encode what we already believe.
enum GitFixture {
    /// Run a shell command in `dir`, returning trimmed stdout.
    @discardableResult
    static func sh(_ command: String, in dir: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir

        // Pin identity and dates so fixtures are byte-for-byte reproducible, and
        // keep the developer's own git config out of the results.
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test User"
        env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test User"
        env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = env

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try? process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fresh, empty repo in a temp directory. Callers must `destroy` it.
    static func newRepo(_ label: String = "repo") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-tests-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh("git init -q -b main", in: dir)
        return dir
    }

    static func destroy(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// An empty commit on the current branch.
    static func commit(_ subject: String, in dir: URL) {
        sh("git commit -q --allow-empty -m \(shellQuoted(subject))", in: dir)
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Oracles

    /// `git log --topo-order` — the ordering CommitOrder must reproduce.
    static func topoOrderSHAs(in dir: URL) -> [String] {
        sh("git log --topo-order --format=%H", in: dir)
            .split(separator: "\n").map(String.init)
    }

    /// Widest gutter `git log --graph` draws, in columns — the width
    /// CommitGraph must match. git pads each column with two characters.
    static func graphWidth(in dir: URL, limit: Int? = nil) -> Int {
        let max_ = limit.map { "--max-count=\($0)" } ?? ""
        let out = sh("git log --graph --oneline \(max_)", in: dir)
        var widest = 0
        for line in out.split(separator: "\n") {
            let gutter = line.prefix { "*|/\\_-. ".contains($0) }
            widest = max(widest, (gutter.count + 1) / 2)
        }
        return widest
    }

    // MARK: Bigger histories

    /// A branchy history built with `git fast-import`, for tests needing more
    /// commits than `commit(_:in:)` can make quickly.
    ///
    /// `lifetime` is the load-bearing parameter, and it defaults high on purpose.
    /// Branches here fork and stay open for that many trunk commits before
    /// merging, with `concurrent` of them in flight at once — so a window smaller
    /// than `lifetime` contains merges whose fork points lie outside it. That is
    /// the shape every real bug in this code needed: short-lived branches that
    /// merge a few rows after forking make the graph's in-degrees force one
    /// legal ordering and one lane layout, and a fixture like that happily
    /// passes against broken code. Mutation testing found exactly that — four
    /// bugs reintroduced, four tests still green — so if you lower `lifetime`,
    /// expect these tests to stop proving anything.
    static func importHistory(
        trunk: Int, concurrent: Int = 6, lifetime: Int = 120, in dir: URL
    ) {
        var stream = "blob\nmark :1\ndata 6\nhello\n"
        var mark = 1
        func next() -> Int { mark += 1; return mark }

        // Deterministic PRNG: fixtures must be identical run to run.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func roll(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        var time = 1_600_000_000
        var parent: Int?
        var made = 0
        var open: [(tip: Int, mergeAt: Int, name: String)] = []

        func emit(_ ref: String, _ message: String, from: Int?, merge: Int? = nil) -> Int {
            let m = next()
            time += 60
            stream += "commit refs/heads/\(ref)\nmark :\(m)\n"
            stream += "author Test User <test@example.com> \(time) +0000\n"
            stream += "committer Test User <test@example.com> \(time) +0000\n"
            stream += "data \(message.utf8.count)\n\(message)\n"
            if let from { stream += "from :\(from)\n" }
            if let merge { stream += "merge :\(merge)\n" }
            stream += "M 100644 :1 file\(made % 5).txt\n"
            return m
        }

        while made < trunk {
            parent = emit("main", "Trunk commit \(made)", from: parent)
            made += 1

            // Open branches inch along beside the trunk, so their commits
            // interleave with it by date the way real work does.
            for i in open.indices where roll(100) < 30 && made < trunk {
                open[i].tip = emit(open[i].name, "Work on \(open[i].name) at \(made)",
                                   from: open[i].tip)
                made += 1
            }

            for i in open.indices.reversed() where made >= open[i].mergeAt {
                parent = emit("main", "Merge \(open[i].name)", from: parent, merge: open[i].tip)
                made += 1
                open.remove(at: i)
            }

            while open.count < concurrent && made + lifetime < trunk {
                let name = "topic\(next())"
                open.append((tip: emit(name, "Start \(name)", from: parent),
                             mergeAt: made + lifetime, name: name))
                made += 1
            }
        }
        stream += "reset refs/heads/main\nfrom :\(parent!)\n"

        let streamFile = dir.appendingPathComponent("stream.fi")
        try? stream.write(to: streamFile, atomically: true, encoding: .utf8)
        sh("git fast-import --quiet < stream.fi && rm stream.fi", in: dir)
        sh("git checkout -q -f main", in: dir)
    }
}
