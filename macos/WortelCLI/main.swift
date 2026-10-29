import Foundation

/// `wortel` — the command line's way into the running app.
///
/// It ships **inside the app bundle**, and Wortel puts its directory on the
/// `PATH` of every shell it spawns (see `GhosttyRuntime.newSurface`). So there
/// is nothing to install: inside a Wortel session the command is simply there,
/// which is where essentially all of its use is — an agent that just wrote a
/// file opening a preview of it, a hook naming its own session, a long build
/// raising attention when it finishes. That also keeps the app zero-config,
/// which an installer step would not.
///
/// Two streams, deliberately: anything a person reads goes to stderr, and the
/// one machine-readable value goes to stdout. That's what makes
/// `id=$(wortel new)` give you an id rather than an id and a sentence.

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("wortel: \(message)\n".utf8))
    exit(code)
}

/// Two versions, because they can differ and the difference is the bug.
///
/// The first is the bundle this binary was copied into — read from its
/// `Info.plist`, since a command line tool has none of its own. The second is
/// whatever answered the socket. They are the same app in every ordinary
/// install; they come apart when a `wortel` someone symlinked onto their `PATH`
/// outlives the app it shipped with, which is the one way these two ends drift.
private func reportVersion() -> Never {
    // `executablePath`, never `arguments[0]`: a shell puts the name you *typed*
    // in argv[0], so a command found on the PATH arrives as the bare word
    // "wortel" — which is inside no bundle, and reported its own version as
    // "unknown" for exactly as long as it took someone to run it the normal way.
    let mine = (Bundle.main.executablePath)
        .flatMap(WortelCLI.appBundle(containing:))
        .flatMap(Bundle.init(path:))
    let version = mine?.infoDictionary?["CFBundleShortVersionString"] as? String
    print("wortel \(version ?? "unknown")\(mine.map { " (\($0.bundlePath))" } ?? "")")

    // Not an error when the app is down: you asked what version this is, and
    // the answer above is the one you asked for.
    guard let response = try? WortelCLIClient.send(.version), let running = response.message else {
        print("Wortel isn't running.")
        exit(0)
    }
    // The app's path is named only when it isn't the bundle this binary came
    // from. In every ordinary install they're the same and repeating it is
    // noise; when they differ, that *is* the answer, and it needs to be the
    // thing that catches your eye rather than two long paths to compare.
    let elsewhere = response.value.map { $0 != mine?.bundlePath } ?? false
    print(running + (elsewhere ? " at \(response.value!)" : ""))
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Ours are the words before `--`; after it is a command's, so that
// `wortel new -- claude --help` runs claude's help rather than printing ours.
let options = arguments.prefix { $0 != "--" }

if options.contains("--version") { reportVersion() }

if arguments.isEmpty || options.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print(WortelCommandParser.usage)
    // No arguments is a usage error, not a request for help — a script that
    // runs `wortel` with an empty variable should not look like it worked.
    exit(arguments.isEmpty ? 2 : 0)
}

let command: WortelCommand
do {
    command = try WortelCommandParser.parse(
        arguments,
        environment: ProcessInfo.processInfo.environment,
        currentDirectory: FileManager.default.currentDirectoryPath)
} catch {
    // Exit 2 for "you typed it wrong", 1 for "the app said no" — the shell's
    // usual split, and it lets a script tell a bad invocation from a refusal.
    fail("\(error)\n\n\(WortelCommandParser.usage)", code: 2)
}

do {
    let response = try WortelCLIClient.send(command)
    if let message = response.message, !message.isEmpty {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
    guard response.ok else { exit(1) }
    if let value = response.value, !value.isEmpty { print(value) }
} catch {
    fail("\(error)", code: 1)
}
