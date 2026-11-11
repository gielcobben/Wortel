import XCTest

/// What these guard is the promise on wortel.sh/privacy, not the plumbing.
///
/// A telemetry bug does not throw and does not crash: it sends something it
/// should not, or stops sending something it should, and both look exactly like
/// working software. So the tests are about the two things with a consequence:
/// what a payload contains, and when reporting is off.
final class TelemetryTests: XCTestCase {

    // MARK: - The allowlist

    /// Every property value any event can carry, checked against the shape of a
    /// value rather than a list of expected strings. A path, a session name, a
    /// branch or a line of terminal output would all fail this: they contain
    /// slashes, spaces, capitals or characters no enum case here uses.
    ///
    /// The type system already makes it impossible to pass one (no case takes a
    /// String), so this is the second line: it catches a *new* case being added
    /// with a String parameter, which is the change this whole directory exists
    /// to prevent.
    func testEveryPropertyValueIsASmallToken() throws {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789_-+<.")
        for event in Self.everyEvent {
            for (key, value) in event.properties {
                XCTAssertFalse(value.isEmpty, "\(event.name).\(key) is empty")
                XCTAssertTrue(value.count <= 12, "\(event.name).\(key) is suspiciously long: \(value)")
                XCTAssertTrue(
                    value.unicodeScalars.allSatisfy(allowed.contains),
                    "\(event.name).\(key) = \(value) is not a plain token. A path, a name or "
                    + "anything a person typed would look like this.")
            }
        }
    }

    /// Property KEYS are a closed set too. A new key is a new column in someone
    /// else's dashboard and a new thing to describe on the privacy page, so it
    /// should not be possible to add one without this failing.
    func testPropertyKeysAreTheDocumentedSet() throws {
        let documented: Set<String> = [
            "sessions", "agents_resumed", "uptime", "via", "automatic",
            "pane", "mode", "kind", "verb", "jobs", "orphans", "orphan",
            "where", "area", "result", "message",
            "first", "previous_exit", "notifications", "agent",
            "signal", "exception", "site", "signature", "crashed_version", "crashed_arch",
        ]
        for event in Self.everyEvent {
            for key in event.properties.keys {
                XCTAssertTrue(documented.contains(key),
                              "\(event.name) carries an undocumented property: \(key). "
                              + "Add it to wortel.sh/privacy before adding it here.")
            }
        }
    }

    func testEventNamesAreUniqueAndSnakeCase() throws {
        var seen: [String: String] = [:]
        for event in Self.everyEvent {
            XCTAssertTrue(event.name.allSatisfy { $0.isLowercase || $0 == "_" },
                          "\(event.name) is not snake case")
            if let other = seen[event.name] {
                XCTAssertEqual(other, event.name)   // same case twice is fine
            }
            seen[event.name] = event.name
        }
    }

    // MARK: - The wire

    /// The two things whose absence would look exactly like success: the
    /// anonymity flag, and the fact that nothing else rides along.
    func testEncodedBatchIsAnonymousAndCarriesOnlyKnownKeys() throws {
        let payloads = [TelemetryClient.Payload(event: .appLaunched(sessions: .twoToThree,
                                                                    agentsResumed: .one, first: false,
                                                                    previousExit: .clean,
                                                                    notifications: .granted),
                                                at: Date(timeIntervalSince1970: 1_760_000_000))]
        let data = try TelemetryClient.encode(payloads, distinctID: "test-install")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let batch = try XCTUnwrap(root["batch"] as? [[String: Any]])
        let event = try XCTUnwrap(batch.first)
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])

        // Without this, PostHog builds a person profile and these events stop
        // being anonymous. Nothing visible would change.
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        // Without this, PostHog stores a city and postal code for the sender.
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)

        XCTAssertEqual(event["event"] as? String, "app_launched")
        XCTAssertEqual(properties["distinct_id"] as? String, "test-install")
        XCTAssertEqual(properties["sessions"] as? String, "2-3")

        // The full set, spelled out: anything new appearing on the wire has to
        // be added here deliberately.
        let expected: Set<String> = [
            "sessions", "agents_resumed", "first", "previous_exit", "notifications",
            "distinct_id", "$process_person_profile", "$geoip_disable",
            "app_version", "macos", "arch", "platform",
        ]
        XCTAssertEqual(Set(properties.keys), expected)
    }

    func testDevicePropertiesDescribeTheBuildAndNotTheMachine() throws {
        let device = TelemetryClient.deviceProperties()
        XCTAssertEqual(device["platform"], "macos")
        XCTAssertTrue(["arm64", "x86_64", "other"].contains(device["arch"] ?? ""))
        // Major.minor only. A patch level narrows the field of machines this
        // could be and never changes a decision.
        let macos = try XCTUnwrap(device["macos"])
        XCTAssertEqual(macos.filter { $0 == "." }.count, 1, "macOS version should be major.minor: \(macos)")
    }

    // MARK: - Buckets

    /// Boundaries, because an off-by-one here is invisible: the number still
    /// looks like a plausible number.
    func testCountBucketBoundaries() {
        XCTAssertEqual(CountBucket(0), .zero)
        XCTAssertEqual(CountBucket(-1), .zero)      // never crash on nonsense
        XCTAssertEqual(CountBucket(1), .one)
        XCTAssertEqual(CountBucket(2), .twoToThree)
        XCTAssertEqual(CountBucket(3), .twoToThree)
        XCTAssertEqual(CountBucket(4), .fourToSeven)
        XCTAssertEqual(CountBucket(7), .fourToSeven)
        XCTAssertEqual(CountBucket(8), .eightPlus)
        XCTAssertEqual(CountBucket(9_999), .eightPlus)
    }

    func testDurationBucketBoundaries() {
        XCTAssertEqual(DurationBucket(seconds: 0), .underMinute)
        XCTAssertEqual(DurationBucket(seconds: 59), .underMinute)
        XCTAssertEqual(DurationBucket(seconds: 60), .underTenMinutes)
        XCTAssertEqual(DurationBucket(seconds: 599), .underTenMinutes)
        XCTAssertEqual(DurationBucket(seconds: 600), .underHour)
        XCTAssertEqual(DurationBucket(seconds: 3_599), .underHour)
        XCTAssertEqual(DurationBucket(seconds: 3_600), .underFourHours)
        XCTAssertEqual(DurationBucket(seconds: 86_399), .underDay)
        XCTAssertEqual(DurationBucket(seconds: 86_400), .dayOrMore)
        // A machine asleep for a fortnight, not a crash.
        XCTAssertEqual(DurationBucket(seconds: 1_209_600), .dayOrMore)
    }

    // MARK: - The off switch

    /// `DO_NOT_TRACK` is an opt-out, and an opt-out that fails open is the
    /// worst kind, so the reading is deliberately generous: anything that is
    /// not plainly "no" counts as set.
    func testDoNotTrackReading() {
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack("1"))
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack("true"))
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack("yes"))
        // Someone who exports the variable at all has expressed a preference.
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack("anything"))
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack(" 1 "))
        XCTAssertTrue(TelemetrySettings.interpretDoNotTrack("TRUE"))

        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack(nil))
        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack(""))
        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack("0"))
        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack("false"))
        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack("no"))
        XCTAssertFalse(TelemetrySettings.interpretDoNotTrack("off"))
    }

    // MARK: - Bridging

    /// The mappings are exhaustive switches, so a new case in any of these
    /// fails the build rather than reporting as nothing. These pin the values,
    /// which the compiler cannot.
    func testBridgingValues() {
        XCTAssertEqual(AttentionCause(.needsInput).rawValue, "needs_input")
        XCTAssertEqual(AttentionCause(.failed).rawValue, "failed")
        XCTAssertEqual(AttentionCause(.turnDone).rawValue, "turn_done")
        XCTAssertEqual(AttentionCause(.finished).rawValue, "finished")

        XCTAssertEqual(InspectorPaneKind(.changes).rawValue, "changes")
        XCTAssertEqual(InspectorPaneKind(.history).rawValue, "history")
        XCTAssertEqual(InspectorPaneKind(.files).rawValue, "files")

        XCTAssertEqual(PreviewKind(.source).rawValue, "source")
        XCTAssertEqual(PreviewKind(.diff).rawValue, "diff")
        XCTAssertEqual(PreviewKind(.rendered).rawValue, "rendered")

        XCTAssertEqual(CommandVerb(.open(path: "/tmp/x")).rawValue, "open")
        XCTAssertEqual(CommandVerb(.newSession(cwd: nil, name: nil, branch: nil, base: nil)).rawValue, "new")
        XCTAssertEqual(CommandVerb(.rename(session: nil, name: "x")).rawValue, "rename")
        XCTAssertEqual(CommandVerb(.notify(session: nil, title: "t", body: nil)).rawValue, "notify")
        XCTAssertEqual(CommandVerb(.mark(session: nil, colour: "red")).rawValue, "mark")
        XCTAssertEqual(CommandVerb(.list(caller: nil)).rawValue, "list")
        XCTAssertEqual(CommandVerb(.read(session: "x", lines: nil)).rawValue, "read")
        XCTAssertEqual(CommandVerb(.send(session: "x", text: "secret prompt", enter: true)).rawValue, "send")
        XCTAssertEqual(CommandVerb(.wait(session: "x", text: "DONE", fromStart: false, idle: true, exit: false,
                                         timeout: 30)).rawValue, "wait")
        XCTAssertEqual(CommandVerb(.version).rawValue, "version")

        XCTAssertEqual(TabOpenedKind(.terminal(UUID()))?.rawValue, "terminal")
        XCTAssertEqual(TabOpenedKind(.browser(UUID()))?.rawValue, "browser")
        XCTAssertEqual(TabOpenedKind(.file("/x"))?.rawValue, "file")
        XCTAssertEqual(TabOpenedKind(.pane(.changes))?.rawValue, "pane")
        // The session's own terminal is never opened, so never reported.
        XCTAssertNil(TabOpenedKind(.session))

        XCTAssertEqual(TabArea(.main).rawValue, "main")
        XCTAssertEqual(TabArea(.side).rawValue, "side")
        XCTAssertEqual(TabArea(.bottom).rawValue, "bottom")
    }

    /// Every agent the shell integration detects maps to its own case, and
    /// anything else, however it is spelled, to `other`: the name itself must
    /// never be what comes out.
    func testAgentNames() {
        let detected = ["claude", "pi", "aider", "codex", "cursor-agent", "gemini", "opencode",
                        "goose", "cline", "ollama", "llm", "crush", "amp"]
        for command in detected {
            XCTAssertNotEqual(AgentName(command: command), .other, "\(command) is detected but unmapped")
        }
        XCTAssertEqual(AgentName(command: "cursor-agent"), .cursor)
        XCTAssertEqual(AgentName(command: "my-secret-tool"), .other)
        XCTAssertEqual(AgentName(command: "Claude"), .other)
        XCTAssertEqual(AgentName(command: "/usr/local/bin/claude"), .other)
        XCTAssertEqual(AgentName(command: ""), .other)
        XCTAssertEqual(AgentName(command: nil), .noAgent)
        XCTAssertEqual(AgentName.noAgent.rawValue, "none")
    }

    // MARK: - Crashes

    /// The shape of a real `.ips` (captured from a deliberate crash on macOS
    /// 27, trimmed to the fields that matter plus the ones that must never
    /// come out). Frames 0 and 1 are one inlined frame at the same offset;
    /// frame 3 is in dyld, not us.
    static let crashReport = """
        {"app_name":"Wortel","timestamp":"2026-11-10 19:44:31.00 -0500","app_version":"2026.46.5",\
        "slice_uuid":"0ec31609-a943-36fc-8520-220d311377a8","build_version":"2026.46.5","bug_type":"309",\
        "os_version":"macOS 27.0.1 (26A434)","name":"Wortel"}
        {"procPath":"/Applications/Wortel.app/Contents/MacOS/Wortel","cpuType":"ARM-64",\
        "codeSigningID":"com.gielcobben.Wortel","modelCode":"Mac16,1","faultingThread":0,
        "exception":{"codes":"0x1, 0x102900698","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
        "threads":[{"triggered":true,"id":1,"queue":"com.apple.main-thread","frames":[
          {"imageOffset":1688,"sourceFile":"/Users/someone/secret-repo/Session.swift","symbol":"Swift runtime failure","imageIndex":0},
          {"imageOffset":1688,"sourceLine":2,"sourceFile":"Session.swift","symbol":"deep(_:)","imageIndex":0},
          {"imageOffset":1652,"sourceLine":4,"sourceFile":"main.swift","symbol":"main","imageIndex":0},
          {"imageOffset":204416,"symbol":"start","imageIndex":1}]},
          {"id":2,"name":"my-branch-name","frames":[{"imageOffset":999,"imageIndex":0}]}],
        "usedImages":[{"name":"Wortel","uuid":"0EC31609-A943-36FC-8520-220D311377A8","base":4337958912,"arch":"arm64"},
          {"name":"dyld","uuid":"d341ddcb-7969-3a9c-8e03-0cf4751398a9","base":6527885312,"arch":"arm64e"}]}
        """

    func testCrashReportReducesToNumbersAndClosedSets() throws {
        let summary = try XCTUnwrap(CrashReport.reduce(Self.crashReport, executable: "Wortel",
                                                       bundleID: "com.gielcobben.Wortel"))
        XCTAssertEqual(summary.signal, .trap)
        XCTAssertEqual(summary.exception, .breakpoint)
        XCTAssertEqual(summary.arch, .arm64)
        XCTAssertEqual(summary.version.rawValue, "2026.46.5")
        // Faulting thread only, ours only, the inlined repeat folded, dyld gone.
        XCTAssertEqual(summary.offsets.map(\.value), [1688, 1652])

        let properties = summary.event.properties
        XCTAssertEqual(properties["site"], "698")
        XCTAssertEqual(properties["signature"]?.count, 12)
        // Nothing from the report's text reaches the event.
        let sent = properties.values.joined(separator: " ")
        for secret in ["secret", "Session", "deep", "main", "someone", "branch", "Mac16", "Applications"] {
            XCTAssertFalse(sent.contains(secret), "\(secret) leaked into app_crashed: \(sent)")
        }
    }

    func testCrashReportOfAnotherAppIsIgnored() {
        XCTAssertNil(CrashReport.reduce(Self.crashReport, executable: "Wortel", bundleID: "com.example.Other"))
        XCTAssertNil(CrashReport.reduce(Self.crashReport, executable: "wortel-keeper", bundleID: nil))
        XCTAssertNil(CrashReport.reduce("not a report", executable: "Wortel", bundleID: nil))
    }

    /// Same offsets, same signature; different offsets, different one.
    func testCrashSignatureIsStable() {
        let a = CrashSignature(offsets: [CodeOffset(1688)!, CodeOffset(1652)!])
        XCTAssertEqual(a, CrashSignature(offsets: [CodeOffset(1688)!, CodeOffset(1652)!]))
        XCTAssertNotEqual(a, CrashSignature(offsets: [CodeOffset(1652)!, CodeOffset(1688)!]))
        XCTAssertNil(CrashSignature(offsets: []))
    }

    func testCalVerOnlyFromIntegers() {
        XCTAssertEqual(CalVer("2026.46.4")?.rawValue, "2026.46.4")
        XCTAssertEqual(CalVer("2026.046.04")?.rawValue, "2026.46.4")
        XCTAssertNil(CalVer("2026.46"))
        XCTAssertNil(CalVer("2026.46.4-beta"))
        XCTAssertNil(CalVer("/Users/x/2026.46.4"))
        XCTAssertNil(CalVer("0.0.0"))
        XCTAssertNil(CalVer(nil))
        XCTAssertNil(CodeOffset(0x100_0000_0000))
    }

    /// A report on disk is matched to the unclean run by date: one written
    /// before that run started is some older crash, already reported.
    func testLatestCrashReportIsAfterTheRunStarted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-ips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Wortel-2026-11-10-194431.ips")
        try Self.crashReport.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                              ofItemAtPath: file.path)
        XCTAssertNotNil(CrashReport.latest(after: Date(timeIntervalSince1970: 1_000), in: dir,
                                           executable: "Wortel", bundleID: "com.gielcobben.Wortel"))
        XCTAssertNil(CrashReport.latest(after: Date(timeIntervalSince1970: 3_000), in: dir,
                                        executable: "Wortel", bundleID: "com.gielcobben.Wortel"))
    }

    /// Written late, after the next run had already started: the crash inside
    /// is the older run's, which was counted as unclean, so it isn't sent again.
    func testLateCrashReportIsNotBlamedOnTheNextRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wortel-ips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Wortel-2026-11-10-194431.ips")
        try Self.crashReport.write(to: file, atomically: true, encoding: .utf8)
        // Crashed 2026-11-10 19:44:31 -0500.
        let crashed = try XCTUnwrap(CrashReport.reduce(Self.crashReport, executable: "Wortel", bundleID: nil)?.crashedAt)
        XCTAssertEqual(crashed.timeIntervalSince1970, 1_794_357_871, accuracy: 1)
        XCTAssertNil(CrashReport.latest(after: crashed.addingTimeInterval(60), in: dir,
                                        executable: "Wortel", bundleID: "com.gielcobben.Wortel"))
        XCTAssertNotNil(CrashReport.latest(after: crashed.addingTimeInterval(-60), in: dir,
                                           executable: "Wortel", bundleID: "com.gielcobben.Wortel"))
    }

    func testCrashOfABuildWithoutAReleaseVersionIsIgnored() {
        let dev = Self.crashReport.replacingOccurrences(of: "\"app_version\":\"2026.46.5\"",
                                                        with: "\"app_version\":\"0.0.0\"")
        XCTAssertNil(CrashReport.reduce(dev, executable: "Wortel", bundleID: nil))
    }

    // MARK: - How the last run ended

    func testPreviousExit() {
        XCTAssertEqual(ExitMarker.previousExit(firstLaunch: true, markerFound: true, crashReported: true), .none)
        XCTAssertEqual(ExitMarker.previousExit(firstLaunch: false, markerFound: false, crashReported: false), .clean)
        // A report with no marker is a report about some older run.
        XCTAssertEqual(ExitMarker.previousExit(firstLaunch: false, markerFound: false, crashReported: true), .clean)
        XCTAssertEqual(ExitMarker.previousExit(firstLaunch: false, markerFound: true, crashReported: false), .unclean)
        XCTAssertEqual(ExitMarker.previousExit(firstLaunch: false, markerFound: true, crashReported: true), .crashed)
    }

    /// Armed, a second arm sees the first run's marker; disarmed, it doesn't.
    func testExitMarkerFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        ExitMarker.arm(at: url)
        XCTAssertFalse(ExitMarker.lastRunEndedUncleanly)
        ExitMarker.arm(at: url)          // relaunch without a quit
        XCTAssertTrue(ExitMarker.lastRunEndedUncleanly)
        ExitMarker.disarm(at: url)
        ExitMarker.arm(at: url)          // relaunch after a quit
        XCTAssertFalse(ExitMarker.lastRunEndedUncleanly)
    }

    // MARK: -

    /// One of every case, with every closed-set value that case can take. This
    /// list is the thing a reviewer should check against `TelemetryEvent`: if a
    /// case is missing here, the allowlist tests above simply do not cover it.
    static let everyEvent: [TelemetryEvent] = buildEveryEvent()

    /// Written out rather than chained: as one expression this defeats the type
    /// checker outright ("unable to type-check in reasonable time"), and this
    /// list is meant to be read against `TelemetryEvent` case by case anyway.
    private static func buildEveryEvent() -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []

        for count in CountBucket.allCases {
            for exit in PreviousExit.allCases {
                for notifications in NotificationState.allCases {
                    events.append(.appLaunched(sessions: count, agentsResumed: count, first: exit == .none,
                                               previousExit: exit, notifications: notifications))
                }
            }
        }
        for uptime in DurationBucket.allCases {
            events.append(.appQuit(uptime: uptime))
        }
        let origins: [SessionOrigin] = [.menu, .cli, .worktree, .restore, .openFolder, .home]
        for origin in origins {
            events.append(.sessionCreated(via: origin))
        }
        events.append(.sessionRenamed(automatic: true))
        events.append(.sessionRenamed(automatic: false))

        let panes: [InspectorPaneKind] = [.changes, .history, .files]
        let panelOrigins: [PanelOrigin] = [.toolbar, .shortcut, .restore]
        for pane in panes {
            for origin in panelOrigins {
                events.append(.inspectorShown(pane: pane, via: origin))
            }
        }
        let previews: [PreviewKind] = [.source, .diff, .rendered, .quickLook]
        for mode in previews {
            for place in PreviewPlace.allCases {
                events.append(.previewOpened(mode: mode, where: place))
            }
        }
        for kind in TabOpenedKind.allCases {
            for area in TabArea.allCases {
                events.append(.tabOpened(kind: kind, area: area))
            }
        }
        for mode in PaletteMode.allCases {
            for result in PaletteResult.allCases {
                events.append(.paletteUsed(mode: mode, result: result))
            }
        }
        for source in CommitMessageSource.allCases {
            events.append(.commitMade(message: source))
        }
        for count in CountBucket.allCases {
            events.append(.processesShown(jobs: count, orphans: count))
        }
        events.append(.processQuit(orphan: true))
        events.append(.processQuit(orphan: false))
        let causes: [AttentionCause] = [.needsInput, .failed, .turnDone, .finished]
        for cause in causes {
            for agent in AgentName.allCases {
                events.append(.agentAttention(kind: cause, agent: agent))
            }
        }
        for agent in AgentName.allCases {
            events.append(.agentStarted(kind: agent))
        }
        for count in CountBucket.allCases {
            events.append(.keeperLost(sessions: count))
        }
        events.append(.sessionArchived)
        events.append(.sessionUnarchived)
        let offsets = [CodeOffset(0x6_98)!, CodeOffset(0xFF_FFFF_FFFF)!, CodeOffset(0)!]
        for signal in CrashSignal.allCases {
            for exception in CrashException.allCases {
                for arch in CrashArch.allCases {
                    events.append(.appCrashed(signal: signal, exception: exception, site: offsets[1],
                                              signature: CrashSignature(offsets: offsets),
                                              version: CalVer("2026.46.14"), arch: arch))
                }
            }
        }
        events.append(.appCrashed(signal: .other, exception: .other, site: nil, signature: nil,
                                  version: nil, arch: .other))
        let verbs: [CommandVerb] = [.open, .new, .rename, .notify, .mark, .list, .read, .send,
                                    .wait, .version]
        for verb in verbs {
            events.append(.commandRun(verb: verb))
        }

        events.append(.agentJumpUsed)
        events.append(.globalHotkeyUsed)
        events.append(.reportingDisabled)
        return events
    }
}
