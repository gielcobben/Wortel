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

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
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
