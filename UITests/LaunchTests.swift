import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    @MainActor
    private func launch(width: Int = 1440, theme: String = "light", language: String = "en", reader: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-review", "-designWidth", String(width),
                               "-shellAppearance", theme, "-sidebarVisible", "YES", "-inspectorVisible", "NO",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if reader { app.launchArguments.append("--design-reader") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWindowAndAppearancePopover() {
        let app = launch()
        let appearance = app.buttons["appearance.toggle"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.radioButtons["System"].exists)
        app.typeKey("a", modifierFlags: [.command, .control])
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testAccessibilityDescriptions() throws {
        let app = launch()
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .contrast])
        app.terminate()
    }

    @MainActor
    func testVisualAcceptanceMatrix() {
        for language in ["en", "ru"] {
            for width in [800, 1440] {
                for theme in ["light", "dark"] {
                    let name = "\(language)-\(width)-\(theme)"
                    let app = launch(width: width, theme: theme, language: language)
                    XCTAssertTrue(app.buttons["library.open"].waitForExistence(timeout: 5))
                    capture(app, name: "Library-\(name)")
                    app.buttons["appearance.toggle"].firstMatch.click()
                    XCTAssertTrue(app.otherElements["appearance.popover"].waitForExistence(timeout: 5))
                    let popover = XCTAttachment(screenshot: app.otherElements["appearance.popover"].screenshot())
                    popover.name = "Appearance-\(name)"
                    popover.lifetime = .keepAlways
                    add(popover)
                    app.typeKey(.escape, modifierFlags: [])
                    app.typeKey("i", modifierFlags: [.command, .control])
                    XCTAssertTrue(app.otherElements["document.inspector"].waitForExistence(timeout: 5))
                    capture(app, name: "Inspector-\(name)")
                    app.terminate()
                    let reader = launch(width: width, theme: theme, language: language, reader: true)
                    XCTAssertTrue(reader.windows["Reading specimen"].waitForExistence(timeout: 5))
                    capture(reader, name: "Reader-\(name)")
                    reader.terminate()
                }
            }
        }
    }
}
