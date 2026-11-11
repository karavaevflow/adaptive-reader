import XCTest
import AppKit
import IOKit.pwr_mgt
import Carbon.HIToolbox

final class LaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    @MainActor
    private func launch(width: Int = 1440, theme: String = "light", language: String = "en", reader: Bool = false, library: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-designReview", "YES", "-designWidth", String(width),
                               "-reviewAppearance", theme,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if reader { app.launchArguments += ["-designReader", "YES"] }
        if library { app.launchArguments += ["-libraryReview", "YES"] }
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
    private func toolbarButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: id)
        return matches.element(boundBy: max(0, matches.count - 1))
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
        let appearance = toolbarButton(app, "appearance.toggle")
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
        toolbarButton(app, "inspector.toggle").click()
        let scale = app.staticTexts["reader.scale"].firstMatch.label
        toolbarButton(app, "appearance.toggle").click()
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
        toolbarButton(restored, "appearance.toggle").click()
        XCTAssertTrue(restored.popUpButtons["page.palette"].firstMatch.value as? String == "Midnight")
        restored.terminate()
    }

    @MainActor
    func testPhase0ReleaseMeasurements() throws {
        #if !FOUNDATION_BENCHMARK
        throw XCTSkip("Run the opt-in Release benchmark on the control Mac")
        #else
        var rows = [[String: Double]]()
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let app = launch(reader: true)
            let ready = ProcessInfo.processInfo.systemUptime
            toolbarButton(app, "inspector.toggle").click()
            XCTAssertTrue(app.descendants(matching: .any)["document.inspector"].firstMatch.waitForExistence(timeout: 5))
            let panel = ProcessInfo.processInfo.systemUptime
            rows.append(["processLaunchToReadyMS": (ready-start)*1000, "panelInteractionMS": (panel-ready)*1000])
            app.terminate()
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Phase0-Release-UI-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    @MainActor
    func testVoiceOverRuntime() throws {
        #if !VOICEOVER_REVIEW
        throw XCTSkip("Opt-in review with VoiceOver enabled on the control Mac")
        #else
        let app = launch()
        toolbarButton(app, "appearance.toggle").click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey(rawValue: "\u{F707}"), modifierFlags: [.control, .option])
        func snapshot(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        for _ in 0..<3 {
            if app.radioButtons["System"].exists { app.typeKey(.escape, modifierFlags: []) }
        }
        XCTAssertFalse(app.radioButtons["System"].exists)
        app.typeKey(XCUIKeyboardKey(rawValue: "\u{F707}"), modifierFlags: [.control, .option])
        snapshot("VoiceOver-focus-return")
        app.terminate()
        #endif
    }

    @MainActor
    func testReducedAccessibilityAndFocus() throws {
        #if !ACCESSIBILITY_REVIEW
        throw XCTSkip("Opt-in review with Reduce Motion and Reduce Transparency enabled")
        #else
        XCTAssertTrue(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertTrue(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        let app = launch()
        toolbarButton(app, "inspector.toggle").click()
        XCTAssertTrue(app.descendants(matching: .any)["document.inspector"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Accessibility-opaque-inspector")
        toolbarButton(app, "inspector.toggle").click()
        toolbarButton(app, "appearance.toggle").click()
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.radioButtons["System"].exists)
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "appearance.toggle").allElementsBoundByIndex.contains {
                $0.debugDescription.contains("Keyboard Focused")
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 5), .completed, "Focus returns after native dismissal finishes")
        capture(app, name: "Accessibility-restored-focus")
        app.typeKey(.space, modifierFlags: [])
        capture(app, name: "Accessibility-space-activation")
        XCTAssertTrue(app.radioButtons["System"].waitForExistence(timeout: 5), "Space reopens the popover from restored toolbar focus")
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
        #endif
    }

    @MainActor
    func testOfflineLibraryVisualMatrix() {
        for language in ["en", "ru"] {
            for width in [800, 1440] {
                for theme in ["light", "dark"] {
                    let app = launch(width: width, theme: theme, language: language, library: true)
                    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book."))
                    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
                    XCTAssertEqual(cards.count, 4)
                    capture(app, name: "v01-Library-\(language)-\(width)-\(theme)")
                    app.terminate()
                }
            }
        }
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
                    toolbarButton(app, "appearance.toggle").click()
                    XCTAssertTrue(app.descendants(matching: .any)["appearance.popover"].firstMatch.waitForExistence(timeout: 5))
                    let popover = XCTAttachment(screenshot: app.descendants(matching: .any)["appearance.popover"].firstMatch.screenshot())
                    popover.name = "Appearance-\(name)"
                    popover.lifetime = .keepAlways
                    add(popover)
                    app.typeKey(.escape, modifierFlags: [])
                    toolbarButton(app, "inspector.toggle").click()
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

final class OfflineReaderTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor private func launch(_ id: String, specimen: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-phase0Store", id, "-designWidth", "1440", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        if specimen { app.launchArguments += ["-phase0Import", "YES"] }
        app.launch(); app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            let file = app.menuBars.menuBarItems.element(boundBy: 2)
            file.click(); file.menuItems.firstMatch.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func menu(_ app: XCUIApplication, _ group: String, _ command: String) {
        app.menuBars.menuBarItems[group].click()
        let item = app.menuItems[command].firstMatch
        XCTAssertTrue(item.isEnabled, "Command must remain enabled: \(command)")
        item.click()
    }
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func paste(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        let board = NSPasteboard.general
        let previous: [NSPasteboardItem] = board.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { board.clearContents(); if !previous.isEmpty { _ = board.writeObjects(previous as [any NSPasteboardWriting]) } }
        field.click()
        menu(app, "Edit", "Select All")
        board.clearContents(); board.setString(text, forType: .string)
        menu(app, "Edit", "Paste")
    }
    @MainActor private func goToFolderKey() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "g" }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id.localizedCaseInsensitiveContains("Russian") ? "п" : "g"
    }

    @MainActor private func readingAssertions() -> Int {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.karavaevflow.AdaptiveReader")
            .filter({ !$0.isTerminated }).max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return 0 }
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let dictionary = result?.takeRetainedValue() as NSDictionary?,
              let assertions = dictionary[NSNumber(value: process.processIdentifier)] as? [[String: Any]] else { return 0 }
        return assertions.filter { $0[kIOPMAssertionNameKey as String] as? String == "Adaptive Reader reading session" }.count
    }

    @MainActor func testOfflineReadingRoundTrip() {
        let id = UUID().uuidString
        let app = launch(id, specimen: true)
        XCTAssertTrue(app.windows["Phase 0 reader"].waitForExistence(timeout: 10))
        app.buttons["page.next"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        menu(app, "Edit", "Bookmark page")
        menu(app, "View", "Keep Awake")
        let awake = app.descendants(matching: .any)["reader.awake"].firstMatch
        XCTAssertTrue(awake.exists)
        XCTAssertEqual(readingAssertions(), 1)
        menu(app, "Edit", "Find in book")
        let field = app.textFields["reader.search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        paste("Chapter", into: field, app: app)
        XCTAssertTrue(app.buttons["reader.search.match"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["reader.search.match"].firstMatch.click()
        snapshot(app, "v01-search")
        menu(app, "View", "Focus")
        XCTAssertTrue(app.descendants(matching: .any)["library.sidebar"].waitForNonExistence(timeout: 5))
        snapshot(app, "v01-focus")
        menu(app, "View", "Focus")
        menu(app, "File", "Close book")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["reader.awake"].exists)
        XCTAssertEqual(readingAssertions(), 0)
        snapshot(app, "v01-library")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.click()
        XCTAssertTrue(app.windows["Phase 0 reader"].waitForExistence(timeout: 10))
        menu(app, "View", "Document inspector")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark.")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let reopened = launch(id, specimen: false)
        XCTAssertTrue(reopened.windows["Phase 0 reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.staticTexts["2/3"].waitForExistence(timeout: 5))
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark.")).firstMatch.exists)
        snapshot(reopened, "v01-restored")
        reopened.terminate()
    }

    @MainActor @discardableResult private func choosePDF(_ app: XCUIApplication, relativePath: String) -> Double {
        let panel = app.sheets["open-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.typeKey(goToFolderKey(), modifierFlags: [.command, .shift])
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relativePath).path
        let location = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        paste(path, into: location, app: app); location.typeKey(.return, modifierFlags: [])
        let start = ProcessInfo.processInfo.systemUptime
        panel.buttons["Open"].firstMatch.click()
        return start
    }

    @MainActor func testLinkedImportSurvivesQuit() {
        let id = UUID().uuidString
        let app = launch(id, specimen: false)
        menu(app, "File", "Import linked PDF")
        choosePDF(app, relativePath: "Research/Fixtures/text.pdf")
        XCTAssertTrue(app.windows["text"].waitForExistence(timeout: 10))
        app.buttons["page.next"].firstMatch.click()
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let restored = launch(id, specimen: false)
        XCTAssertTrue(restored.windows["text"].waitForExistence(timeout: 10))
        XCTAssertTrue(restored.staticTexts["2/3"].waitForExistence(timeout: 5))
        menu(restored, "File", "Close book")
        XCTAssertTrue(restored.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Linked PDF")).firstMatch.waitForExistence(timeout: 5))
        snapshot(restored, "v01-linked-library")
        restored.terminate()
    }
    @MainActor func testLargeDocumentCommandsDuringSearch() {
        let app = launch(UUID().uuidString, specimen: false)
        menu(app, "File", "Open PDF")
        choosePDF(app, relativePath: "Research/Large/large-text.pdf")
        XCTAssertTrue(app.windows["large-text"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1/600"].waitForExistence(timeout: 5))
        menu(app, "Edit", "Find in book")
        let field = app.textFields["reader.search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        paste("responsive", into: field, app: app)
        XCTAssertTrue(app.buttons["reader.search.match"].firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<3 { app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -1200) }
        XCTAssertNotEqual(app.staticTexts["page.current"].firstMatch.label, "1/600")
        snapshot(app, "v01-large-search")
        menu(app, "View", "Focus")
        XCTAssertTrue(app.descendants(matching: .any)["library.sidebar"].waitForNonExistence(timeout: 5))
        menu(app, "File", "Close book")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(readingAssertions(), 0)
    }

    @MainActor func testLargeDocumentReleaseMeasurements() throws {
        #if !FOUNDATION_BENCHMARK
        throw XCTSkip("Opt-in Release measurement on the control Mac")
        #else
        var rows = [[String: Double]]()
        for index in 0..<5 {
            let app = launch(UUID().uuidString, specimen: false)
            menu(app, "File", "Open PDF")
            let start = choosePDF(app, relativePath: "Research/Large/large-text.pdf")
            XCTAssertTrue(app.windows["large-text"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["1/600"].waitForExistence(timeout: 5))
            let image = app.windows.firstMatch.screenshot()
            rows.append(["openClickToCapturedWindowMS": (ProcessInfo.processInfo.systemUptime - start) * 1000])
            if index == 0 {
                let attachment = XCTAttachment(screenshot: image)
                attachment.name = "v01-large-release"; attachment.lifetime = .keepAlways; add(attachment)
            }
            app.terminate()
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "v01-large-ui-measurements"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

}
