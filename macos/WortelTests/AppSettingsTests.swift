import XCTest

/// The Settings window's stored rows. Small, but each default is a promise:
/// a key nobody has written must read as the behaviour before there was a
/// switch, or an update changes the app under someone who touched nothing.
@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testNothingWrittenIsTheAppAsItWas() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.showsCommitBox, "the commit box was always there")
        XCTAssertFalse(settings.opensServersInDefaultBrowser, "servers opened in a tab")
    }

    func testAChoiceIsRememberedByTheNextLaunch() {
        let settings = AppSettings(defaults: defaults)
        settings.showsCommitBox = false
        settings.opensServersInDefaultBrowser = true

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.showsCommitBox)
        XCTAssertTrue(relaunched.opensServersInDefaultBrowser)
    }

    func testTurningTheCommitBoxBackOnIsRememberedToo() {
        let settings = AppSettings(defaults: defaults)
        settings.showsCommitBox = false
        settings.showsCommitBox = true
        XCTAssertTrue(AppSettings(defaults: defaults).showsCommitBox)
    }

    /// The View menu's checkmark wrote this key before there was a window.
    func testTheServersChoiceMadeInTheOldMenuCarriesOver() {
        defaults.set(true, forKey: "browser.opensServersInDefaultBrowser")
        XCTAssertTrue(AppSettings(defaults: defaults).opensServersInDefaultBrowser)
    }
}
