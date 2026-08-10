---
title: Privacy
description: What Wortel and wortel.sh record, what they do not, and why the app itself sends nothing.
updated: 2026-08-10
nav: Privacy
order: 10
---

Wortel is free, has no account, and asks for nothing about you. This page is the
whole of what is measured anyway, written so you can check it rather than take
it on trust.

The short version: the website counts pages and download clicks without storing
anything on your machine, the update server counts downloads and update checks,
and the app itself sends nothing at all.

## Who is responsible

Giel Cobben, in the Netherlands, is the controller for the processing described
here. Questions, objections and requests go to
[privacy@wortel.sh](mailto:privacy@wortel.sh).

If you think this processing breaches the GDPR you can complain to the Dutch
supervisory authority, the Autoriteit Persoonsgegevens.

## The app sends nothing

Wortel.app contains no analytics. It does not phone home, has no account, no
login and no identifier, and it does not report which commands you run, which
directories you open, which repositories you have, what your sessions are named
or anything drawn on your screen. None of that leaves your Mac.

Your session list, window layout and preferences are stored in
`~/Library/Application Support/Wortel/` and stay there. Your shell
configuration is yours and is never read by Wortel for any purpose beyond
running your shell.

The one thing the app does talk to is the update server, described next.

If in-app analytics is ever added, it will be opt-out, it will be announced in
the release notes, and this page will describe every event before it ships.

## The update server

Wortel checks for updates through Sparkle, which asks
`updates.wortel.sh/appcast.xml` roughly once a day and downloads an archive from
the same place when there is a new version. That is how the app stays current,
and it is the one thing it does over the network.

Those requests are counted. For each one, the following is recorded:

- which file was requested, so a first download can be told apart from an update
- the app version, which Sparkle puts in its user agent
- an approximate country
- a short identifier, described below, that changes every day

Nothing is stored that identifies your machine, and none of it is linked to
anything else.

**This is the one part you cannot switch off from inside the app.** An update
check is how the app learns a security fix exists, so it happens regardless of
any other preference. The only way to stop it is to turn off automatic update
checks, which also means updates stop arriving. Should the app ever gain its own
analytics with an opt-out, that opt-out will not cover this: turning it off will
not stop update checks, and saying otherwise would be a lie.

## The website

wortel.sh uses PostHog, hosted in the EU, to count how the page is doing. It
records page views, and four things worth naming: which download button was
clicked, which release note was opened, whether anyone interacted with the
demo window, and the version offered at the time.

**Nothing is stored on your device.** No cookies, no local storage, no session
storage. The identifier PostHog uses lives in memory for one page load and is
gone when you navigate. The practical consequence is that we cannot tell a
returning reader from a new one, and cannot follow anyone from page to page.
That is the trade, and it is deliberate.

Analytics requests go to wortel.sh itself rather than to PostHog directly. That
is done so the page adds no third-party origin and so an ad blocker does not
change what the page does. It does not send PostHog anything extra.

Your IP address reaches the server, because that is how the web works, and is
used to derive an approximate country. It is not used to build a profile of you.

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
identifying way that answers the question. No device storage is used, so no
consent is required for it.

You have the rights the GDPR gives you, including access, erasure and objection.
There is an honest catch worth stating plainly: because none of this data
identifies you, and the update server's identifier is rebuilt daily from
information that is never stored, there is generally no way to find "your" data
in order to show or delete it. That is a consequence of collecting so little,
not a way of avoiding the question. Write to
[privacy@wortel.sh](mailto:privacy@wortel.sh) and you will get a straight answer
about what exists.

Events are kept while they are useful for understanding how Wortel is used, and
are aggregate from the moment they arrive.

## Changes

The date at the top is the last time this page changed. If what is collected
ever grows, this page changes before the collecting starts, not after.
