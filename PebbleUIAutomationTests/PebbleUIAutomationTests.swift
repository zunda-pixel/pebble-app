import XCTest

final class PebbleUIAutomationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMacAppLaunchesAndShowsPrimaryNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.zunda.Pebble")
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        if app.buttons["Get Started"].waitForExistence(timeout: 1) {
            app.buttons["Get Started"].click()
        }
        XCTAssertTrue(app.staticTexts["Devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apps"].exists)
        XCTAssertTrue(app.staticTexts["Timeline"].exists)
        XCTAssertTrue(app.staticTexts["Health"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication(bundleIdentifier: "com.zunda.Pebble").launch()
        }
    }
}
