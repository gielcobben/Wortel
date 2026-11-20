// swift-tools-version: 5.9
import PackageDescription

// Ghostty, built here from one commit (`ghostty.ref`) with libghostty-spm's
// patch stack (`spm.ref`) and Wortel's own (`Patches/`). Two libraries come
// out of the same patched tree, and they have to: the keeper's terminal hands
// the app's surface a snapshot whose format is only defined within one commit.
//
// - GhosttyKit: the embedded app runtime with the Metal renderer. The app.
// - GhosttyVt: libghostty-vt, a terminal with no renderer. The keeper and
//   the tests. Never linked into the same binary as GhosttyKit: both carry
//   the same C dependencies and compiler runtime.
//
// `Frameworks/` is filled by `macos/scripts/build-ghostty.sh`.
let package = Package(
    name: "GhosttyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyVt", targets: ["GhosttyVtLink", "GhosttyVt"]),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(name: "libghostty", path: "Frameworks/GhosttyKit.xcframework"),
        // Only here for its linker settings: libghostty-vt carries C++
        // (simdutf, highway) and needs libc++ wherever it is linked.
        .target(
            name: "GhosttyVtLink",
            path: "Sources/GhosttyVtLink",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
    ]
)
