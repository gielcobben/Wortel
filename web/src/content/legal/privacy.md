---
title: Privacy
description: What Wortel and wortel.sh record, what they never record, and how to turn the app's reporting off.
updated: 2026-11-10
nav: Privacy
order: 10
---

Wortel is free, has no account, and asks for nothing about you. This page is the
whole of what is measured anyway, written so you can check it rather than take
it on trust.

The short version: the website counts pages and download clicks without storing
anything on your machine, the update server counts downloads and update checks,
and the app reports which of its features get used, in a form that cannot
describe you or your work. That last one you can switch off in one click.

## Who is responsible

Giel Cobben, in the Netherlands, is the controller for the processing described
here. Questions, objections and requests go to
[privacy@wortel.sh](mailto:privacy@wortel.sh).

If you think this processing breaches the GDPR you can complain to the Dutch
supervisory authority, the Autoriteit Persoonsgegevens.

## The app

Wortel reports which of its features are used, and nothing else. It is on by
default, it says so the first time you open it, and it is one click to turn off:
the **ⓘ** at the bottom of the sidebar, or **Share anonymous usage data** in
Settings (the Wortel menu, or ⌘,). Both are the same switch.

### What is never sent

None of this leaves your Mac, ever, whether reporting is on or off:

- what you type, and anything drawn on your screen
- the commands you run, and their output
- session names, window titles, directories or file paths
- repository names, branch names, or anything from your git history
- your user name, your computer's name, or your files

That is not a policy, it is the shape of the code. The list of things the app
can report is a single file with no free-form text in it: every value is chosen
from a fixed set, so there is no field a directory or a session name could be
put into even by mistake. A terminal sees everything you do, which is exactly
why the reporting was built this way.

### What is sent

One short message when something happens, saying what happened and nothing
about the thing it happened to:

- the app started, roughly how many sessions came back (as a range like "4-7",
  never an exact count), and roughly how many agents resumed; whether this is
  the first time it has started on this Mac; whether the time before, it quit
  normally or ended some other way (a crash or a force quit); and whether macOS
  allows it to show notifications
- if the time before ended in a crash that macOS kept a report of: which kind
  of crash it was, the version, whether the Mac is Apple Silicon or Intel, and
  where in Wortel's own code it happened, as a number that only the build's
  own debug file can turn into a name. Never the report itself, nothing named
  in it, and nothing about other programs
- the app quit, and roughly how long it ran
- a session was created, and whether that was from the menu, the `wortel`
  command, a worktree, opening a folder, the shortcut that starts one in
  your home directory, or New Terminal (never which folder, or where it was
  opened), and a yes or no for whether it started with the command you set in
  Settings (never the command itself)
- a session was renamed
- the git panel was opened, on which of the three panes, and whether from the
  toolbar or the keyboard
- a file preview was opened, whether it showed source, a diff or Markdown, and
  whether it opened as a tab or a window
- a tab was opened, which kind (a terminal, a browser, a file or one of the git
  and file panes) and in which area of the window (never what is in it, where
  a browser is pointed, or which file)
- the command palette was used (⌘P or ⇧⌘P), and whether it ended with a session
  picked, a command run, or neither (never what was typed or which session or
  command it was)
- a commit was made from the Changes pane, and whether its message was typed,
  drafted on your Mac and kept, or drafted and then edited (never the message,
  the files or the repository)
- the list of processes your sessions are still running was opened, with rough
  counts of how many there were and how many had outlived their session (never
  what they are, what they are serving, or where they are running)
- something was quit from that list, and whether it was one that had outlived
  its session
- an agent was started in a session, and which one, chosen from the fixed list
  of agents Wortel recognises (Claude Code, Codex, Pi, Gemini, OpenCode, Goose,
  Aider, Amp, Crush, Cline, Ollama, llm, Cursor). Anything else is reported as
  "other", never by its name, and never what it was asked or where it ran
- a background session asked for attention, which kind of signal raised it,
  and which of those agents (if any) it came from
- the background process that keeps your terminals running stopped
  unexpectedly, and roughly how many sessions it took with it
- a session in a worktree was archived, or brought back from the archive
- the jump-to-next-waiting shortcut was used
- the shortcut that shows and hides Wortel from any app was used
- a `wortel` command was run, and which one (`open`, `new`, `rename`, `notify`,
  `mark`, `list`, `read`, `send`, `wait`, `version`)
- one last message when you turn reporting off, and then silence

Each carries the app version, your macOS version to one decimal place, and
whether the Mac is Apple Silicon or Intel. That is the whole list.

### Who it says you are

A random identifier, made once on your machine and stored with your other
preferences. It is not derived from your hardware, your serial number or your
name, so it identifies nothing and nobody can recompute it. Deleting Wortel's
preferences loses it, and that is correct behaviour rather than a bug.

The events are marked anonymous at PostHog, which means no profile is built
from them: they are counted, not accumulated into a record of what one install
did.

### When it reports nothing at all

- you turned it off
- `DO_NOT_TRACK` is set in your environment, which Wortel honours like any other
  command line tool
- the build is a development build rather than a release

Your session list, window layout and preferences are stored in
`~/Library/Application Support/Wortel/` and in your preferences file, and stay
there. While Wortel is open it also keeps an empty file named `running` in that
folder, which is how the next launch knows whether it quit normally. Your shell configuration is yours and is never read by Wortel for any
purpose beyond running your shell.

The other thing the app talks to is the update server, described next, and that
one the switch above does not cover.

## The update server

Wortel checks for updates through Sparkle, which asks
`updates.wortel.sh/appcast.xml` roughly once a day and downloads an archive from
the same place when there is a new version. That is how the app stays current.

Those requests are counted. For each one, the following is recorded:

- which file was requested, so a first download can be told apart from an update
- the app version, which Sparkle puts in its user agent
- an approximate country
- a short identifier, described below, that changes every day

Nothing is stored that identifies your machine, and none of it is linked to
anything else.

**This is the one part you cannot switch off from inside the app, and "Share
anonymous usage data" does not cover it.** An update check is how the app learns
that a security fix exists, so it happens regardless of any other preference.
Turning reporting off stops everything in the section above and does not stop
this, and saying otherwise would be a lie. The only way to stop it is to turn
off automatic update checks, which also means updates stop arriving.

## The website

wortel.sh uses PostHog, hosted in the EU, to count how the page is doing. It
records page views, and four things worth naming: which download button was
clicked, which release note was opened, whether anyone interacted with the
demo window, and the version offered at the time. It also measures how quickly
each page loaded and responded, so we know if the site is slow for anyone.

**Nothing is stored on your device.** No cookies, no local storage, no session
storage.

To count visitors without storing anything, PostHog combines your IP address,
your browser's user agent and the site's address with a secret that changes
every day, and keeps only the scrambled result (a hash), never the parts. The
same browser on the same day gives the same hash, so we can see how many people
visited and how many pages each one read. The next day the secret changes and so
does the hash, so a visit can never be linked to one on another day, and we
cannot tell a returning reader from a new one.

Analytics requests go to wortel.sh itself rather than to PostHog directly. That
is done so the page adds no third-party origin and so an ad blocker does not
change what the page does. The one thing it changes on the way is location: it
switches off PostHog's own lookup, which would record a city and postal code,
and adds only the country instead.

Your IP address reaches the server, because that is how the web works. It is
used for the daily hash above and to look up an approximate country, and then
thrown away: it is not stored, and neither is a city or anything finer than the
country. It is not used to build a profile of you.

There is no cookie banner because there are no cookies. What European law asks
consent for is storing things on your device, and none of this does.

## Who else is involved

- **PostHog**, EU region, receives the events described above and stores them.
- **Cloudflare** serves this site and the update files, and sees the requests
  that reach them, as any host does.

Nothing is sold, and nothing is shared with advertisers, data brokers or anyone
building an advertising profile. There is no such profile to share.

## The legal part

The lawful basis is legitimate interest under Article 6(1)(f) GDPR: knowing
roughly how many people use a free tool, and which parts they use, in the least
identifying way that answers the question.

The website stores nothing on your device, so there is nothing there for a
consent banner to ask about. The app is different and it is worth being straight
about it: it does keep one random identifier in its own preferences, and that is
storage on your machine. It is on by default, the app tells you so the first
time you open it, and it stops the moment you turn it off. If you would rather
it never started, `DO_NOT_TRACK` is honoured from the first launch.

You have the rights the GDPR gives you, including access, erasure and objection.
For the website and the update server there is an honest catch: nothing there
identifies you, and the update server's identifier is rebuilt daily from
information that is never stored, so there is generally no way to find "your"
data in order to show or delete it. That is a consequence of collecting so
little, not a way of dodging the question.

The app is the one place a request can actually be acted on, because its
identifier is stable. You can read it yourself:

```
defaults read com.gielcobben.Wortel TelemetryInstallID
```

Send that to [privacy@wortel.sh](mailto:privacy@wortel.sh) and the events under
it can be shown to you or deleted. Deleting it locally, or turning reporting
off, stops anything further being recorded under it.

Events are kept while they are useful for understanding how Wortel is used, and
are aggregate from the moment they arrive.

## Changes

The date at the top is the last time this page changed. If what is collected
ever grows, this page changes before the collecting starts, not after.
