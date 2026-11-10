import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    @MainActor
    private func launch(width: Int = 1440, theme: String = "light", language: String = "en", reader: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-designReview", "YES", "-designWidth", String(width),
                               "-reviewAppearance", theme,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if reader { app.launchArguments += ["-designReader", "YES"] }
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            let fileMenu = app.menuBars.menuBarItems.element(boundBy: 2)
            fileMenu.click()
            fileMenu.menuItems.firstMatch.click()
        }
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
        let appearance = app.buttons["appearance.toggle"].firstMatch.buttons["appearance.toggle"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.radioButtons["System"].exists)
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Appearance"].firstMatch.click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testAccessibilityDescriptions() throws {
        let app = launch()
        app.buttons["library.open"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: -1)).click()
        for identifier in ["library.open", "sidebar.toggle", "appearance.toggle", "inspector.toggle", "workspace.more"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.exists, identifier)
            XCTAssertFalse(element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identifier)
        }
        for title in ["All Books", "Reading", "Favorites"] {
            XCTAssertTrue(app.buttons[title].firstMatch.exists)
        }
        try app.performAccessibilityAudit(for: .contrast)
        app.terminate()
    }

    @MainActor
    func testReaderSessionRestoresAfterQuit() {
        let id = UUID().uuidString
        func open(importBook: Bool) -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = ["-phase0Store", id, "-designWidth", "1440", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
            if importBook { app.launchArguments += ["-phase0Import", "YES"] }
            app.launch()
            app.activate()
            if !app.windows.firstMatch.waitForExistence(timeout: 2) {
                let file = app.menuBars.menuBarItems.element(boundBy: 2)
                file.click(); file.menuItems.firstMatch.click()
            }
            XCTAssertTrue(app.windows["Phase 0 reader"].waitForExistence(timeout: 10))
            return app
        }
        let app = open(importBook: true)
        app.buttons["page.next"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Zoom in"].firstMatch.click()
        app.buttons["inspector.toggle"].firstMatch.buttons["inspector.toggle"].firstMatch.click()
        let scale = app.staticTexts["reader.scale"].firstMatch.label
        app.buttons["appearance.toggle"].firstMatch.buttons["appearance.toggle"].firstMatch.click()
        app.popUpButtons["page.palette"].firstMatch.click()
        app.menuItems["Midnight"].firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
        if app.popUpButtons["page.palette"].firstMatch.exists { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertFalse(app.popUpButtons["page.palette"].firstMatch.exists)
        let reference = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        reference.name = "Reader-Midnight-integrated"
        reference.lifetime = .keepAlways
        add(reference)
        let frame = app.windows.firstMatch.frame
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let restored = open(importBook: false)
        XCTAssertTrue(restored.staticTexts["2/3"].waitForExistence(timeout: 5))
        XCTAssertTrue(restored.staticTexts["reader.scale"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.staticTexts["reader.scale"].firstMatch.label, scale)
        XCTAssertEqual(restored.windows.firstMatch.frame.width, frame.width, accuracy: 2)
        XCTAssertEqual(restored.windows.firstMatch.frame.height, frame.height, accuracy: 2)
        restored.buttons["appearance.toggle"].firstMatch.buttons["appearance.toggle"].firstMatch.click()
        XCTAssertTrue(restored.popUpButtons["page.palette"].firstMatch.value as? String == "Midnight")
        restored.terminate()
    }

    @MainActor
    func testPhase0ReleaseMeasurements() throws {
        guard ProcessInfo.processInfo.environment["ADAPTIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Run the opt-in Release benchmark on the control Mac")
        }
        var rows = [[String: Double]]()
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let app = launch(reader: true)
            let ready = ProcessInfo.processInfo.systemUptime
            app.buttons["inspector.toggle"].firstMatch.buttons["inspector.toggle"].firstMatch.click()
            XCTAssertTrue(app.descendants(matching: .any)["document.inspector"].firstMatch.waitForExistence(timeout: 5))
            let panel = ProcessInfo.processInfo.systemUptime
            rows.append(["processLaunchToReadyMS": (ready-start)*1000, "panelInteractionMS": (panel-ready)*1000])
            app.terminate()
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Phase0-Release-UI-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testComponentCatalog() {
        for language in ["en", "ru"] {
            for theme in ["light", "dark"] {
                let app = launch(theme: theme, language: language)
                app.popUpButtons["workspace.more"].firstMatch.click()
                let title = language == "ru" ? "Компоненты Adaptive" : "Adaptive components"
                app.menuItems[title].firstMatch.click()
                XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["catalog.unavailable"].firstMatch.isEnabled)
                app.buttons["catalog.select"].firstMatch.click()
                let image = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
                image.name = "Components-\(language)-\(theme)"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
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
                    app.buttons["appearance.toggle"].firstMatch.buttons["appearance.toggle"].firstMatch.click()
                    XCTAssertTrue(app.descendants(matching: .any)["appearance.popover"].firstMatch.waitForExistence(timeout: 5))
                    let popover = XCTAttachment(screenshot: app.descendants(matching: .any)["appearance.popover"].firstMatch.screenshot())
                    popover.name = "Appearance-\(name)"
                    popover.lifetime = .keepAlways
                    add(popover)
                    app.typeKey(.escape, modifierFlags: [])
                    app.buttons["inspector.toggle"].firstMatch.buttons["inspector.toggle"].firstMatch.click()
                    XCTAssertTrue(app.descendants(matching: .any)["document.inspector"].firstMatch.waitForExistence(timeout: 5))
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
