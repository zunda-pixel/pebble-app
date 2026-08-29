import XCTest

final class PebbleUIAutomationTests: XCTestCase {
    private static let primarySections = ["Devices", "Apps", "Timeline", "Health"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsPrimaryNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.zunda.Pebble")
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 2) {
            getStarted.tap()
        }

        // The sections are a tab bar on iOS and a sidebar list on macOS, so
        // each one is looked for as either a control or a label.
        for section in Self.primarySections {
            let found = app.buttons[section].waitForExistence(timeout: 5)
                || app.staticTexts[section].waitForExistence(timeout: 1)
            XCTAssertTrue(found, "\(section) is missing from the primary navigation")
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication(bundleIdentifier: "com.zunda.Pebble").launch()
        }
    }
}
