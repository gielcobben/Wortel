# Security

## Reporting a problem

Report it privately, not in a public issue:

- through GitHub's private vulnerability reporting: the **Security** tab of
  this repository, then **Report a vulnerability**, or
- by email to hello@wortel.sh.

Say what you found, the version (Wortel ▸ About Wortel), your macOS version,
and the steps that show it. You will get a reply within a week.

## Supported versions

Only the latest release. Fixes ship as a new release through the built-in
updater (Wortel ▸ Check for Updates…), and older versions are not patched.

## What is in scope

- **The app** (`macos/`): everything it does with what a terminal shows it,
  the files it opens and previews, and the browser tabs it hosts.
- **The keeper**, the process that holds every session's shell, and its
  socket.
- **The `wortel` command and its socket.**
- **The shell integration** Wortel installs into every shell it starts.
- **The update channel**: the appcast, the signed archives and the Worker at
  `updates.wortel.sh` (`updates/`).

## The trust model

Processes running as the same macOS user are trusted. They can already read
your files, type into your terminal and talk to any socket in your home
folder, so a report that needs one of them to attack Wortel is not in scope.

What is in scope is anything that crosses that line:

- **Another user** on the same Mac reaching your sessions, your sockets or
  your data folder.
- **Terminal output.** Whatever a program prints, a file you `cat`, or a
  server you `ssh` into is untrusted: an escape sequence that makes Wortel run
  a command, open something, read a file or leak data is in scope.
- **The network.** A web page in a browser tab, a link you click, or an update
  that is not the one that was signed.

## Not here

A problem in the terminal engine itself (parsing, rendering, input) is
usually Ghostty's. Report it to Ghostty through its own security policy
(<https://github.com/ghostty-org/ghostty/security>). If you are not sure
which side it is on, report it here and it will be passed on.
