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
            "pane", "mode", "kind", "verb",
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
                                                                    agentsResumed: .one),
                                                at: Date(timeIntervalSince1970: 1_760_000_000))]
        let data = try TelemetryClient.encode(payloads, distinctID: "test-install")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let batch = try XCTUnwrap(root["batch"] as? [[String: Any]])
        let event = try XCTUnwrap(batch.first)
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])

        // Without this, PostHog builds a person profile and these events stop
        // being anonymous. Nothing visible would change.
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)

        XCTAssertEqual(event["event"] as? String, "app_launched")
        XCTAssertEqual(properties["distinct_id"] as? String, "test-install")
        XCTAssertEqual(properties["sessions"] as? String, "2-3")

        // The full set, spelled out: anything new appearing on the wire has to
        // be added here deliberately.
        let expected: Set<String> = [
            "sessions", "agents_resumed", "distinct_id", "$process_person_profile",
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
        XCTAssertEqual(CommandVerb(.version).rawValue, "version")
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
            events.append(.appLaunched(sessions: count, agentsResumed: count))
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
            events.append(.previewOpened(mode: mode))
        }
        let causes: [AttentionCause] = [.needsInput, .failed, .turnDone, .finished]
        for cause in causes {
            events.append(.agentAttention(kind: cause))
        }
        let verbs: [CommandVerb] = [.open, .new, .rename, .notify, .version]
        for verb in verbs {
            events.append(.commandRun(verb: verb))
        }

        events.append(.agentJumpUsed)
        events.append(.reportingDisabled)
        return events
    }
}
