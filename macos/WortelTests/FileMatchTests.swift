import XCTest

/// ⌘P's files: the first row is the whole feature. Paths from the Linux
/// tree, where the ranking was tuned against all 97k of them.
final class FileMatchTests: XCTestCase {
    private let paths = [
        "Documentation/mm/page_allocation.rst",
        "Kconfig",
        "Makefile",
        "README",
        "arch/arm64/kvm/hyp/nvhe/page_alloc.c",
        "arch/mips/include/asm/mach-n64/kmalloc.h",
        "arch/mips/mm/page.c",
        "drivers/gpu/drm/amd/amdgpu/amdgpu_vm.c",
        "drivers/gpu/drm/amd/amdgpu/amdgpu_vm.h",
        "drivers/gpu/drm/amd/amdgpu/amdgpu_vm_pt.c",
        "drivers/gpu/drm/amd/amdgpu/amdgpu_vram_mgr.c",
        "drivers/iommu/iommu-debug-pagealloc.c",
        "drivers/net/ethernet/mellanox/mlx5/core/pagealloc.c",
        "fs/coredump.c",
        "fs/ext4/ext4.h",
        "fs/ext4/inode-test.c",
        "fs/ext4/inode.c",
        "include/linux/sched.h",
        "include/linux/sched/coredump.h",
        "kernel/sched/core.c",
        "kernel/sched/core_sched.c",
        "macos/Wortel/UI/SessionSwitcher.swift",
        "macos/Wortel/Sessions/SessionSwitcherMatch.swift",
        "mm/page_alloc.c",
        "mm/page_alloc.h",
        "net/nfc/core.c",
        "net/sched/cls_api.c",
        "net/sched/cls_fw.c",
        "rust/Makefile",
        "scripts/coccinelle/api/kmalloc_objs.cocci",
    ]

    private lazy var index = FileIndex.merging([(FileIndex.sorted(paths), .tracked)])

    private func ranked(_ query: String, boosts: [String: Int32] = [:]) -> [String] {
        let byIndex = Dictionary(uniqueKeysWithValues: boosts.compactMap { path, boost in
            (0..<index.count).first { index.path($0) == path }.map { (Int32($0), boost) }
        })
        return FileMatch.rank(FileMatch.Query(query), in: index, boosts: byIndex).matches
            .map { index.path(Int($0.index)) }
    }

    private func first(_ query: String) -> String? { ranked(query).first }

    func testTheFileNameWins() {
        XCTAssertEqual(first("core"), "net/nfc/core.c")
        XCTAssertEqual(first("page_alloc"), "mm/page_alloc.c")
        XCTAssertEqual(first("kmalloc"), "arch/mips/include/asm/mach-n64/kmalloc.h")
        XCTAssertEqual(first("readme"), "README")
        XCTAssertEqual(first("makefile"), "Makefile")
    }

    /// The name closest to what was typed: `core.c` before `coredump.c`.
    func testAShorterNameBeatsALongerOne() {
        let names = ranked("core").prefix(2)
        XCTAssertTrue(names.allSatisfy { ($0 as NSString).lastPathComponent == "core.c" }, "\(names)")
    }

    func testLettersAcrossWordsFindTheName() {
        XCTAssertEqual(first("amdgpuvm"), "drivers/gpu/drm/amd/amdgpu/amdgpu_vm.c")
        XCTAssertEqual(first("SessSwitch"), "macos/Wortel/UI/SessionSwitcher.swift")
    }

    /// A word with a `/` is matched against the whole path.
    func testASlashMatchesThePath() {
        XCTAssertEqual(first("sched/core"), "kernel/sched/core.c")
        XCTAssertEqual(first("ext4/inode"), "fs/ext4/inode.c")
    }

    /// Letters spread over folder and name. A long run in another file's
    /// name (`iommu-debug-pagealloc.c`) scores close; the one meant is in
    /// the first three, which is what is pinned.
    func testLettersOverFolderAndName() {
        XCTAssertTrue(ranked("mmpagealloc").prefix(3).contains("mm/page_alloc.c"), "\(ranked("mmpagealloc"))")
    }

    func testSpacesMeanAnd() {
        XCTAssertEqual(first("ext4 inode"), "fs/ext4/inode.c")
        XCTAssertEqual(first("sched cls fw"), "net/sched/cls_fw.c")
        XCTAssertTrue(ranked("ext4 sched").isEmpty)
    }

    func testCaseDoesNotMatter() {
        XCTAssertEqual(first("KCONFIG"), "Kconfig")
    }

    /// A to Z are folded on both sides, and nothing else: a letter beyond
    /// them matches as typed (not turned into one the path doesn't have).
    func testLettersBeyondAToZMatchAsTyped() {
        let index = FileIndex.merging([(FileIndex.sorted(["docs/Übersicht.md", "docs/other.md"]), .tracked)])
        let found = FileMatch.rank(FileMatch.Query("Übersicht"), in: index).matches.map { index.path(Int($0.index)) }
        XCTAssertEqual(found, ["docs/Übersicht.md"])
    }

    func testNothingMatches() {
        XCTAssertTrue(ranked("zzzq").isEmpty)
        XCTAssertTrue(ranked("").isEmpty)
    }

    /// One or two letters: file names only, nobody means a folder by them.
    func testAShortQueryMatchesNamesOnly() {
        XCTAssertFalse(ranked("kv").contains("arch/arm64/kvm/hyp/nvhe/page_alloc.c"))
        XCTAssertFalse(ranked("mm").contains("mm/page_alloc.c"))
        XCTAssertTrue(ranked("mm").contains("drivers/iommu/iommu-debug-pagealloc.c"))
    }

    /// A changed file, or one opened lately, settles a near-tie, and never
    /// lifts a folder match over a name match.
    func testABoostSettlesATie() {
        XCTAssertEqual(first("inode"), "fs/ext4/inode.c")
        XCTAssertEqual(ranked("inode", boosts: ["fs/ext4/inode-test.c": 24]).first, "fs/ext4/inode-test.c")
        XCTAssertEqual(ranked("sched", boosts: ["kernel/sched/core.c": 24]).first, "include/linux/sched.h")
    }

    /// A query that adds to the last one searches the last one's survivors,
    /// and finds what a full search finds.
    func testNarrowingMatchesAFullSearch() {
        for (short, long) in [("s", "sched"), ("sch", "sched/c"), ("dr", "drm amd"), ("ext", "ext4 inode")] {
            let first = FileMatch.rank(FileMatch.Query(short), in: index)
            let narrowed = FileMatch.rank(FileMatch.Query(long), in: index, among: first.survivors)
            let full = FileMatch.rank(FileMatch.Query(long), in: index)
            XCTAssertEqual(narrowed.matches, full.matches, long)
            XCTAssertEqual(Set(narrowed.survivors), Set(full.survivors), long)
        }
    }

    func testCancelledReturnsNothing() {
        XCTAssertTrue(FileMatch.rank(FileMatch.Query("core"), in: index, isCancelled: { true }).matches.isEmpty)
    }

    /// `foo.swift:120` is a file and a line, as a ⌘-clicked path is.
    func testALineAfterTheName() {
        XCTAssertEqual(TerminalLink.withoutLocation("SessionSwitcher.swift:120").path, "SessionSwitcher.swift")
        XCTAssertEqual(TerminalLink.withoutLocation("SessionSwitcher.swift:120").line, 120)
        XCTAssertEqual(TerminalLink.withoutLocation("inode.c#L42").line, 42)
        XCTAssertNil(TerminalLink.withoutLocation("inode").line)
    }

    // MARK: - The index

    func testMergingKeepsTrackedFirstAndEachPathOnce() {
        let merged = FileIndex.merging([
            (FileIndex.sorted(["b", "a", "c"]), .tracked),
            (FileIndex.sorted(["c", "d"]), .untracked),
        ])
        XCTAssertEqual((0..<merged.count).map(merged.path), ["a", "b", "c", "d"])
        XCTAssertEqual(merged.kinds, [.tracked, .tracked, .tracked, .untracked])
    }

    /// A conflicted file is listed by git once per stage.
    func testRepeatsFromGitAreKeptOnce() {
        let output = Array("a.c\0b.c\0b.c\0b.c\0c.c\0".utf8)
        let merged = FileIndex.merging([(FileIndex.split(nulSeparated: output), .tracked)])
        XCTAssertEqual((0..<merged.count).map(merged.path), ["a.c", "b.c", "c.c"])
    }

    func testAFoldersContentsAreOneRange() {
        let range = index.range(withPrefix: Array("fs/ext4/".utf8))
        XCTAssertEqual(range.map(index.path), ["fs/ext4/ext4.h", "fs/ext4/inode-test.c", "fs/ext4/inode.c"])
        XCTAssertTrue(index.contains("mm/page_alloc.c"))
        XCTAssertFalse(index.contains("mm/page_alloc"))
    }

    // MARK: - Speed

    /// Half a million paths, as the work monorepo has. Printed every run;
    /// held to a frame (16 ms) only where the build is optimised, since a
    /// Debug test build runs this loop many times slower than the app.
    func testHalfAMillionPathsPerKeystroke() {
        let dirs = ["src", "lib", "app", "pkg", "test", "core", "web", "api", "ui", "util"]
        let names = ["index", "main", "session", "switcher", "page", "alloc", "config", "model", "view", "store"]
        let exts = ["swift", "ts", "c", "h", "md"]
        var generated: [String] = []
        generated.reserveCapacity(500_000)
        var n = 0
        while generated.count < 500_000 {
            let a = dirs[n % dirs.count], b = dirs[(n / 10) % dirs.count], c = n / 100
            let name = names[(n / 7) % names.count] + "_" + names[(n / 3) % names.count]
            generated.append("\(a)/\(b)/module\(c)/\(name)\(n % 13).\(exts[n % exts.count])")
            n += 1
        }
        let big = FileIndex.merging([(FileIndex.sorted(generated), .tracked)])
        var survivors: [Int32]?
        var worst = 0.0
        for query in ["s", "se", "ses", "sess", "sessi", "session", "session swi", "session switcher"] {
            let start = Date()
            let result = FileMatch.rank(FileMatch.Query(query), in: big, among: survivors)
            let ms = Date().timeIntervalSince(start) * 1000
            worst = max(worst, ms)
            survivors = result.survivors
            print(String(format: "FILEMATCH %@ %.2f ms, %d candidates", query, ms, result.survivors.count))
        }
        #if !DEBUG
        XCTAssertLessThan(worst, 16)
        #endif
    }
}
