import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testWindowAndAppearancePopover() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let appearance = app.buttons["Appearance"]
        XCTAssertTrue(appearance.exists)
        appearance.click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(appearance.exists)
    }
}
