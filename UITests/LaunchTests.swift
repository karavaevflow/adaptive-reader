import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testWindowAndAppearancePopover() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let appearance = app.buttons["appearance.toggle"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
    }
}
