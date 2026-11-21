# The name and the icon

The code is yours to use under the GPL (see [`LICENSE`](LICENSE)). The name
**Wortel** and its icon (`macos/Wortel/AppIcon.icon`, and everything exported
from it, on the site and in the app) are not part of that licence. They belong
to Giel Cobben, and they say which builds come from wortel.sh.

## What you can do

- Build Wortel from this source for yourself, and change it. Nothing here needs
  renaming for that.
- Say that your program is based on Wortel, or a fork of it. That is just true.
- Write about Wortel, link to it, and show the app as it is.

## What a published fork changes

If you distribute a build of your own, changed or not, it carries its own
identity, so nobody mistakes it for Wortel or sends Wortel's users to it:

- **Its own name**, in `CFBundleDisplayName`, the product name, the menus and
  the windows.
- **Its own icon.** Replace `macos/Wortel/AppIcon.icon`.
- **Its own bundle id.** `bundleIdPrefix` in `macos/project.yml` and the
  `com.gielcobben.Wortel` identifiers in the code. With Wortel's bundle id,
  macOS treats the two as one app: they share settings and permissions.
- **Its own update feed, or none.** Change `SUFeedURL` and `SUPublicEDKey` in
  `macos/project.yml` to a feed and a key of your own, or remove Sparkle. Never
  point a build at updates.wortel.sh: that feed installs Wortel over your app.
- **Its own telemetry, or none.** Change `projectKey` and `endpoint` in
  `macos/Wortel/Telemetry/TelemetryClient.swift`, or remove the client. A fork
  must not report to Wortel's project.
- **Its own links.** The app links to wortel.sh in a few places (search the
  source for `wortel.sh`). Point them at your own pages.

## Questions

Ask before doing something this does not cover:
[privacy@wortel.sh](mailto:privacy@wortel.sh).
