import XCTest

/// Smoke tests on the simulator, using the built-in demo library. Ported from
/// the first Codex build's UI tests and adapted to this app.
final class FolioUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["--ui-reset", "--demo"] : ["--demo"]) + extra
        app.launch()
        return app
    }

    /// Settings → Voices; the row may sit below the first screen on small phones.
    private func openVoiceLibrary(_ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let voices = app.buttons["voice-library"]
        scrollTo(voices, in: app)
        voices.tap()
    }

    /// Lists only create rows on screen: scroll until `element` can be tapped.
    /// Half-screen drags, because a full swipe can carry a row from below the
    /// screen to above it without it ever being on screen.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
        for _ in 0..<14 where !(element.exists && element.isHittable) {
            from.press(forDuration: 0.05, thenDragTo: to)
        }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Screens in a light and a dark theme for design review. CI exports
    /// these attachments as the "screens" artifact.
    func testThemedScreensForReview() {
        for theme in ["warm-paper", "midnight"] {
            let app = launch(extra: ["--theme", theme])
            XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
            screenshot(app, "\(theme)-1-today")
            app.tabBars.buttons["Library"].tap()
            XCTAssertTrue(app.staticTexts["library-title"].waitForExistence(timeout: 5))
            screenshot(app, "\(theme)-2-library")
            app.tabBars.buttons["Listen"].tap()
            XCTAssertTrue(app.buttons["daily-mix"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["headlines"].waitForExistence(timeout: 5))
            screenshot(app, "\(theme)-3-listen")
            app.swipeUp()
            screenshot(app, "\(theme)-4-listen-stations")
            app.buttons["daily-mix"].tap()
            XCTAssertTrue(app.staticTexts["now-playing-title"].waitForExistence(timeout: 10))
            app.swipeDown()
            app.swipeDown()
            screenshot(app, "\(theme)-5-listen-playing")
            app.terminate()
        }
    }

    /// A tab on iPhone's tab bar, or the same tab where iPad puts it.
    private func tab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.buttons[name]
        (bar.exists ? bar : app.buttons[name].firstMatch).tap()
    }

    /// App Store screenshots. The App Store screens workflow runs this on the
    /// largest iPhone and iPad with TEST_RUNNER_APP_STORE_SCREENS=1; the normal
    /// test run skips it.
    func testAppStoreScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APP_STORE_SCREENS"] == "1",
                          "Only for the App Store screens workflow")
        var app = launch(extra: ["--theme", "warm-paper"])
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        screenshot(app, "01-today")
        app.buttons["featured-story"].tap()
        let listen = app.buttons["reader-listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        sleep(4)  // a few words in, so the highlight is on a sentence
        screenshot(app, "02-reader-read-along")
        app.terminate()

        app = launch(extra: ["--theme", "midnight"])
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        tab(app, "Listen")
        XCTAssertTrue(app.buttons["daily-mix"].waitForExistence(timeout: 10))
        app.buttons["daily-mix"].tap()
        XCTAssertTrue(app.staticTexts["now-playing-title"].waitForExistence(timeout: 10))
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        screenshot(app, "03-listen-playing")
        app.swipeUp()
        sleep(1)
        screenshot(app, "04-stations")
        tab(app, "Library")
        XCTAssertTrue(app.staticTexts["library-title"].waitForExistence(timeout: 5))
        screenshot(app, "07-library")
        app.terminate()

        app = launch(extra: ["--theme", "warm-paper"])
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        openVoiceLibrary(app)
        XCTAssertTrue(app.navigationBars["Voices"].waitForExistence(timeout: 5))
        sleep(1)
        screenshot(app, "05-voices")
        app.buttons["natural-voices"].tap()
        XCTAssertTrue(app.navigationBars["Natural voices"].waitForExistence(timeout: 5))
        screenshot(app, "06-natural-voices")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let premium = app.buttons["Paperwire Premium"]
        scrollTo(premium, in: app)
        premium.tap()
        XCTAssertTrue(app.staticTexts["Paperwire Premium"].waitForExistence(timeout: 5))
        sleep(3)  // StoreKit answers
        screenshot(app, "08-premium")
    }

    func testOnboardingOffersTheDemoLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["try-demo"].waitForExistence(timeout: 10))
        app.buttons["try-demo"].tap()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
    }

    func testNewReadersCanPickPopularSources() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-feeds"].waitForExistence(timeout: 10))
        app.buttons["choose-feeds"].tap()
        let start = app.buttons["start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)  // nothing picked yet
        app.buttons["pack-The world today"].tap()
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.label.contains("4 sources"))
        screenshot(app, "feed-picker")
        let hackerNews = app.buttons["feed-Hacker News"]
        scrollTo(hackerNews, in: app)
        hackerNews.tap()
        XCTAssertTrue(start.label.contains("5 sources"))
        screenshot(app, "feed-picker-topics")
    }

    func testDemoReaderAndAppearance() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        app.buttons["featured-story"].tap()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    }

    func testVoiceLibraryListsVoicesAndOpensDetail() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        openVoiceLibrary(app)
        XCTAssertTrue(app.navigationBars["Voices"].waitForExistence(timeout: 5))
        // The simulator ships system voices; the first one opens its detail page.
        let firstVoice = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Preview '")).firstMatch
        XCTAssertTrue(firstVoice.waitForExistence(timeout: 10))
        firstVoice.tap()
        XCTAssertTrue(app.buttons["make-default-voice"].waitForExistence(timeout: 5))
    }

    func testNeuralVoicesAreOfferedWithTheVoiceLab() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        openVoiceLibrary(app)
        XCTAssertTrue(app.navigationBars["Voices"].waitForExistence(timeout: 5))
        app.buttons["natural-voices"].tap()
        XCTAssertTrue(app.navigationBars["Natural voices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["download-supertonic"].exists)
        XCTAssertTrue(app.buttons["download-kokoro"].exists)
        let paradee = app.buttons["download-paradee"]
        scrollTo(paradee, in: app)
        XCTAssertTrue(paradee.exists)
        let server = app.buttons["voice-server"]
        scrollTo(server, in: app)
        server.tap()
        XCTAssertTrue(app.textFields["voice-server-address"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Natural voices"].waitForExistence(timeout: 5))
        let lab = app.buttons["voice-lab"]
        scrollTo(lab, in: app)
        XCTAssertTrue(lab.waitForExistence(timeout: 5))
        lab.tap()
        XCTAssertTrue(app.navigationBars["Voice Lab"].waitForExistence(timeout: 5))
    }

    func testLanguagesHaveTheirOwnSettings() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let languages = app.buttons["languages-settings"]
        scrollTo(languages, in: app)
        languages.tap()
        XCTAssertTrue(app.navigationBars["Languages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["read-aloud-en"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["read-aloud-de"].exists)
        screenshot(app, "languages-settings")
    }

    func testSettingsLinkThePrivacyPolicyTermsAndLicences() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let licences = app.buttons["licences"]
        scrollTo(licences, in: app)
        XCTAssertTrue(app.buttons["privacy-policy"].exists)
        XCTAssertTrue(app.buttons["terms-of-use"].exists)
        licences.tap()
        XCTAssertTrue(app.navigationBars["Licences"].waitForExistence(timeout: 5))
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Supertonic-3 voices'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Attachment A'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testHoldingTheMiniPlayerClosesNarration() {
        let app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["daily-mix"].waitForExistence(timeout: 10))
        app.buttons["daily-mix"].tap()
        XCTAssertTrue(app.staticTexts["now-playing-title"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Today"].tap()
        let mini = app.otherElements["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.press(forDuration: 0.8)
        let button = app.buttons["mini-player-button"]
        let turnedIntoClose = expectation(for: NSPredicate(format: "label == 'Stop and close'"), evaluatedWith: button)
        wait(for: [turnedIntoClose], timeout: 3)
        button.tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5))
    }

    func testBulletinIsQueuedPausedAndSurvivesRelaunch() {
        var app = launch()
        XCTAssertTrue(app.buttons["featured-story"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Listen"].tap()
        let build = app.buttons["build-bulletin"]
        XCTAssertTrue(build.waitForExistence(timeout: 10))
        for _ in 0..<6 where !build.isHittable { app.swipeUp() }
        build.tap()
        XCTAssertTrue(app.navigationBars["News Radio"].waitForExistence(timeout: 5))
        let create = app.buttons["confirm-build-bulletin"]
        for _ in 0..<12 where !create.isHittable { app.swipeUp() }
        create.tap()

        let play = app.buttons["listen-play-pause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.label, "Play")  // built, not auto-playing
        let title = app.staticTexts["now-playing-title"].label
        XCTAssertFalse(title.isEmpty)

        app.terminate()
        app = launch(reset: false)
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["listen-play-pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["listen-play-pause"].label, "Play")  // restored paused
        XCTAssertEqual(app.staticTexts["now-playing-title"].label, title)
    }
}
