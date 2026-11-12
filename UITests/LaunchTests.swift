import XCTest
import AppKit
import IOKit.pwr_mgt
import Carbon.HIToolbox

private var targetApplicationBundleID: String {
    Bundle(for: OfflineReaderTests.self).object(forInfoDictionaryKey: "AdaptiveReaderTargetBundleID") as? String ?? "com.karavaevflow.AdaptiveReader"
}

final class LaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    @MainActor
    private func launch(width: Int = 1440, theme: String = "light", language: String = "en", reader: Bool = false, library: Bool = false, storedReader: Bool = false, companionReview: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-designReview", "YES", "-designWidth", String(width),
                               "-reviewAppearance", theme,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if reader { app.launchArguments += ["-designReader", "YES"] }
        if library { app.launchArguments += ["-libraryReview", "YES"] }
        if storedReader { app.launchArguments += ["-phase0Import", "YES"] }
        if companionReview { app.launchArguments += ["-companionFixture", "YES", "-companionReview", "YES"] }
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
    func testDailyReadingVisualMatrix() {
        for language in ["en", "ru"] {
            for width in [800, 1440] {
                for theme in ["light", "dark"] {
                    let app = launch(width: width, theme: theme, language: language, storedReader: true)
                    XCTAssertTrue(app.windows["Phase 0 reader"].waitForExistence(timeout: 10))
                    let name = "\(language)-\(width)-\(theme)"
                    func command(_ english: String, _ russian: String) {
                        app.menuBars.menuBarItems[language == "ru" ? "Вид" : "View"].click()
                        app.menuItems[language == "ru" ? russian : english].firstMatch.click()
                    }
                    command("Command Center", "Центр команд")
                    XCTAssertTrue(app.textFields["command.query"].firstMatch.waitForExistence(timeout: 5))
                    capture(app, name: "v02-Commands-\(name)")
                    app.typeKey(.escape, modifierFlags: [])
                    command("Reading tools", "Инструменты чтения")
                    XCTAssertTrue(app.buttons["comfort.start"].waitForExistence(timeout: 5))
                    app.checkBoxes["comfort.spotlight"].firstMatch.click()
                    capture(app, name: "v02-Tools-\(name)")
                    app.typeKey(.escape, modifierFlags: [])
                    capture(app, name: "v02-Spotlight-\(name)")
                    command("Mini Reader", "Мини-читалка")
                    let mini = app.windows["reader.mini"].firstMatch
                    XCTAssertTrue(mini.waitForExistence(timeout: 5))
                    let image = XCTAttachment(screenshot: mini.screenshot())
                    image.name = "v02-Mini-\(name)"; image.lifetime = .keepAlways; add(image)
                    app.terminate()
                }
            }
        }
    }

    @MainActor func testCompanionVisualMatrix() {
        for language in ["en", "ru"] {
            for width in [800, 1440] {
                for theme in ["light", "dark"] {
                    let app = launch(width: width, theme: theme, language: language, storedReader: true, companionReview: true)
                    let menu = app.menuBars.menuBarItems[language == "ru" ? "Вид" : "View"]
                    menu.click(); app.menuItems["AI Companion"].firstMatch.click()
                    XCTAssertTrue(app.staticTexts["ai.answer"].firstMatch.waitForExistence(timeout: 15))
                    capture(app, name: "v03-Companion-\(language)-\(width)-\(theme)")
                    app.buttons["ai.settings"].firstMatch.click()
                    XCTAssertTrue(app.textFields["ai.endpoint"].firstMatch.waitForExistence(timeout: 5))
                    app.popUpButtons["ai.providerMode"].firstMatch.click()
                    app.menuItems[language == "ru" ? "Облачный API" : "Cloud API"].firstMatch.click()
                    XCTAssertTrue(app.checkBoxes["ai.cloudConsent"].firstMatch.waitForExistence(timeout: 5))
                    capture(app, name: "v03-Settings-\(language)-\(width)-\(theme)")
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

    @MainActor private func launch(_ id: String, specimen: Bool, diagnostics: Bool = false, additionalArguments: [String] = [], width: Int = 1440, theme: String = "light", language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-phase0Store", id, "-designWidth", String(width), "-AppleLanguages", "(\(language))", "-AppleLocale", language, "-shellAppearance", theme]
        if specimen { app.launchArguments += ["-phase0Import", "YES"] }
        if diagnostics { app.launchArguments += ["-comfortDiagnostics", "YES"] }
        app.launchArguments += additionalArguments
        app.launch(); app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            let file = app.menuBars.menuBarItems.element(boundBy: 2)
            file.click(); file.menuItems.firstMatch.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func menu(_ app: XCUIApplication, _ group: String, _ command: String) {
        let bar = app.menuBars.menuBarItems[group]
        bar.click()
        let item = bar.menuItems[command].firstMatch
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
        let edit = app.menuBars.menuBarItems.element(boundBy: 3)
        edit.click(); edit.menuItems["selectAll:"].firstMatch.click()
        board.clearContents(); board.setString(text, forType: .string)
        edit.click(); edit.menuItems["paste:"].firstMatch.click()
    }
    @MainActor private func goToFolderKey() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "g" }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id.localizedCaseInsensitiveContains("Russian") ? "п" : "g"
    }

    @MainActor private func readingAssertions() -> Int {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: targetApplicationBundleID)
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
        panel.buttons["OKButton"].firstMatch.click()
        return start
    }

    @MainActor private func studySection(_ app: XCUIApplication, _ title: String) {
        let picker = app.popUpButtons["study.section"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.click()
        app.menuItems[title].firstMatch.click()
    }

    @MainActor func testStudyCardsNotesRecallAndHighlightsSurviveReflowAndRestart() {
        let id = UUID().uuidString, app = launch(id, specimen: false)
        menu(app, "File", "Open book"); choosePDF(app, relativePath: "Research/Fixtures/EPUB/reflow.epub")
        XCTAssertTrue(app.windows["reflow"].waitForExistence(timeout: 10))
        menu(app, "Edit", "Find in book")
        paste("Passage 853.", into: app.textFields["reader.search.query"].firstMatch, app: app)
        let match = app.buttons["reader.search.match"].firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10)); match.click()
        app.buttons["Close search"].firstMatch.click()
        menu(app, "Edit", "New note")
        let note = app.textViews["study.note.editor"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5)); paste("A note about passage 853.", into: note, app: app)
        app.buttons["study.note.save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["study.note.text"].firstMatch.waitForExistence(timeout: 5))
        menu(app, "Edit", "New card")
        let question = app.descendants(matching: .any)["card.question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        paste("What strengthens memory?", into: question, app: app)
        paste("Active recall.", into: app.textViews["card.answer"].firstMatch, app: app)
        app.buttons["card.save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["study.card.question"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["study.card.edit"].firstMatch.click()
        let answer = app.textViews["card.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5)); paste("Active retrieval practice.", into: answer, app: app)
        app.buttons["card.save"].firstMatch.click()
        studySection(app, "Recall")
        XCTAssertTrue(app.buttons["recall.reveal"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["recall.answer"].firstMatch.exists)
        app.buttons["recall.reveal"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["recall.answer"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "v04-recall-flow")
        app.buttons["recall.remembered"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["recall.empty"].firstMatch.waitForExistence(timeout: 5))
        studySection(app, "Cards")
        app.buttons["study.card.source"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 5))
        menu(app, "Edit", "Highlight passage")
        XCTAssertTrue(app.staticTexts["study.highlight.text"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["appearance.toggle"].firstMatch.click()
        let size = app.sliders["epub.fontSize"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5)); size.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).click()
        app.typeKey(.escape, modifierFlags: [])
        snapshot(app, "v04-highlight-reflow-flow")
        app.menuBars.menuBarItems.element(boundBy: 1).click(); app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let restored = launch(id, specimen: false)
        XCTAssertTrue(restored.windows["reflow"].waitForExistence(timeout: 10))
        menu(restored, "View", "Study"); studySection(restored, "Cards")
        XCTAssertTrue(restored.staticTexts["study.card.question"].firstMatch.waitForExistence(timeout: 5))
        let savedAnswer = restored.staticTexts["study.card.answer"].firstMatch
        XCTAssertTrue(((savedAnswer.value as? String) ?? savedAnswer.label).contains("Active retrieval practice."))
        restored.buttons["study.card.source"].firstMatch.click()
        XCTAssertTrue(restored.staticTexts["2/2"].waitForExistence(timeout: 5))
        menu(restored, "View", "Study")
        studySection(restored, "Notes")
        XCTAssertTrue(restored.staticTexts["study.note.text"].firstMatch.waitForExistence(timeout: 5))
        restored.buttons["study.note.edit"].firstMatch.click()
        let editor = restored.textViews["study.note.editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); paste("Edited note survives.", into: editor, app: restored)
        restored.buttons["study.note.save"].firstMatch.click()
        studySection(restored, "Highlights")
        XCTAssertTrue(restored.staticTexts["study.highlight.text"].firstMatch.waitForExistence(timeout: 5))
        snapshot(restored, "v04-study-restored-flow")
        restored.buttons["study.highlight.source"].firstMatch.click()
        let passageText = "Passage 853. Retrieval practice strengthens memory through active recall. Reflow changes presentation while keeping the original text and its source locator stable. Images preserve their colors."
        let passage = restored.webViews.staticTexts.matching(NSPredicate(format: "value == %@", passageText)).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 10)); XCTAssertTrue(passage.isHittable)
        restored.terminate()
    }

    @MainActor func testStudyVisualMatrix() {
        let short = ProcessInfo.processInfo.environment["ADAPTIVE_V04_MATRIX_SHORT"] == "1"
        for language in ["en", "ru"] { for width in [800, 1440] { for theme in ["light", "dark"] {
            if short && !((language == "ru" && width == 800 && theme == "dark") || (language == "en" && width == 1440 && theme == "light")) { continue }
            let app = launch(UUID().uuidString, specimen: false, width: width, theme: theme, language: language)
            app.buttons["reader.open"].firstMatch.click()
            choosePDF(app, relativePath: "Research/Fixtures/EPUB/reflow.epub")
            XCTAssertTrue(app.windows["reflow"].waitForExistence(timeout: 10))
            if app.buttons["study.toggle"].firstMatch.exists { app.buttons["study.toggle"].firstMatch.click() }
            else {
                app.popUpButtons["workspace.more"].firstMatch.click()
                app.menuItems[language == "en" ? "Study" : "Обучение"].firstMatch.click()
            }
            let suffix = "\(language)-\(width)-\(theme)"
            XCTAssertTrue(app.buttons["study.newNote"].firstMatch.waitForExistence(timeout: 5))
            snapshot(app, "v04-Notes-" + suffix)
            app.buttons["study.newNote"].firstMatch.click()
            XCTAssertTrue(app.textViews["study.note.editor"].firstMatch.waitForExistence(timeout: 5))
            snapshot(app, "v04-NoteEditor-" + suffix)
            app.buttons["study.note.cancel"].firstMatch.click()
            studySection(app, language == "en" ? "Cards" : "Карточки")
            snapshot(app, "v04-Cards-" + suffix)
            app.buttons["study.newCard"].firstMatch.click()
            XCTAssertTrue(app.descendants(matching: .any)["card.question"].firstMatch.waitForExistence(timeout: 5))
            snapshot(app, "v04-CardEditor-" + suffix)
            app.buttons["card.cancel"].firstMatch.click()
            studySection(app, language == "en" ? "Recall" : "Самопроверка")
            snapshot(app, "v04-Recall-" + suffix)
            studySection(app, language == "en" ? "Highlights" : "Выделения")
            app.buttons["study.highlight"].firstMatch.click()
            XCTAssertTrue(app.staticTexts["study.highlight.text"].firstMatch.waitForExistence(timeout: 5))
            snapshot(app, "v04-Highlights-" + suffix)
            studySection(app, language == "en" ? "Listen" : "Озвучивание")
            XCTAssertTrue(app.buttons["listen.start"].firstMatch.waitForExistence(timeout: 5))
            snapshot(app, "v04-Listen-" + suffix)
            app.buttons["study.close"].firstMatch.click()
            snapshot(app, "v04-Reader-" + suffix)
            app.terminate()
        } } }
    }

    @MainActor func testStudyMarkdownExportThroughNativeSavePanel() throws {
        let app = launch(UUID().uuidString, specimen: true)
        menu(app, "Edit", "New card")
        let question = app.descendants(matching: .any)["card.question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5)); paste("Exported question?", into: question, app: app)
        paste("Exported answer.", into: app.textViews["card.answer"].firstMatch, app: app)
        app.buttons["card.save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["study.card.question"].firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["study.actions"].firstMatch.click()
        app.menuItems["Export Markdown"].firstMatch.click()
        let panel = app.sheets["save-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveReader-Export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        panel.typeKey(goToFolderKey(), modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5)); paste(destination.path, into: path, app: app); path.typeKey(.return, modifierFlags: [])
        panel.buttons["OKButton"].firstMatch.click()
        let exists = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "md" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exists], timeout: 10), .completed)
        let url = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" })
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Exported question?") && text.contains("Exported answer.") && text.contains("SourceAnchor:"))
        snapshot(app, "v04-markdown-export-flow")
        app.terminate()
    }

    @MainActor func testNativeListenPauseResumeRestartAndClose() {
        let id = UUID().uuidString, app = launch(id, specimen: false, additionalArguments: ["-silentSpeechTest"])
        menu(app, "File", "Open book"); choosePDF(app, relativePath: "Research/Fixtures/EPUB/reflow.epub")
        XCTAssertTrue(app.windows["reflow"].waitForExistence(timeout: 10))
        menu(app, "View", "Listen from here")
        let pause = app.buttons["listen.pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["listen.word"].firstMatch.waitForExistence(timeout: 15), "Must receive actual AVFoundation speech progress")
        pause.click()
        XCTAssertTrue(app.buttons["listen.continue"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "v04-listen-paused-flow")
        app.buttons["listen.continue"].firstMatch.click()
        XCTAssertTrue(app.buttons["listen.pause"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["listen.stop"].firstMatch.click()
        XCTAssertTrue(app.buttons["listen.saved"].firstMatch.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems.element(boundBy: 1).click(); app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let restored = launch(id, specimen: false, additionalArguments: ["-silentSpeechTest"])
        XCTAssertTrue(restored.windows["reflow"].waitForExistence(timeout: 10))
        menu(restored, "View", "Study"); studySection(restored, "Listen")
        let saved = restored.buttons["listen.saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.click()
        XCTAssertTrue(restored.buttons["listen.pause"].firstMatch.waitForExistence(timeout: 15))
        menu(restored, "File", "Close book")
        XCTAssertTrue(restored.buttons["listen.pause"].firstMatch.waitForNonExistence(timeout: 5))
        let view = restored.menuBars.menuBarItems["View"]; view.click()
        XCTAssertFalse(view.menuItems["Stop listening"].firstMatch.isEnabled)
        restored.typeKey(.escape, modifierFlags: [])
        restored.terminate()
    }

    @MainActor func testEPUBSearchReflowBookmarkAndRestore() {
        let id = UUID().uuidString
        let app = launch(id, specimen: false)
        menu(app, "File", "Open book")
        choosePDF(app, relativePath: "Research/Fixtures/EPUB/reflow.epub")
        XCTAssertTrue(app.windows["reflow"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        let viewMenu = app.menuBars.menuBarItems["View"]
        viewMenu.click()
        for command in ["Zoom in", "Zoom out", "Reading Spotlight", "Mini Reader"] {
            XCTAssertFalse(viewMenu.menuItems[command].firstMatch.isEnabled)
        }
        app.typeKey(.escape, modifierFlags: [])
        let footnote = app.webViews.links["[1]"].firstMatch
        XCTAssertTrue(footnote.waitForExistence(timeout: 10)); footnote.click()
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 5))
        menu(app, "View", "Back")
        XCTAssertTrue(app.staticTexts["1/2"].waitForExistence(timeout: 5))
        menu(app, "Edit", "Find in book")
        let field = app.textFields["reader.search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        paste("Passage 853.", into: field, app: app)
        let match = app.buttons["reader.search.match"].firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10)); match.click()
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 5))
        app.buttons["Close search"].firstMatch.click()
        // WebKit exposes paragraph text in AXValue; heading AXValue is numeric.
        // Exact equality supports both types without substring predicate exceptions.
        let passageText = "Passage 853. Retrieval practice strengthens memory through active recall. Reflow changes presentation while keeping the original text and its source locator stable. Images preserve their colors."
        let passage = app.webViews.staticTexts.matching(NSPredicate(format: "value == %@", passageText)).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 10))
        XCTAssertTrue(passage.isHittable, "Locator must resolve to visible text in WebKit")
        menu(app, "Edit", "Bookmark page")
        app.buttons["appearance.toggle"].firstMatch.click()
        let size = app.sliders["epub.fontSize"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        size.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).click()
        let column = app.sliders["epub.columnWidth"].firstMatch
        column.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(passage.isHittable, "Reflow must keep the source fragment visible")
        snapshot(app, "v04-epub-reflow")
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Quit AdaptiveReader"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let restored = launch(id, specimen: false)
        XCTAssertTrue(restored.windows["reflow"].waitForExistence(timeout: 10))
        XCTAssertTrue(restored.staticTexts["2/2"].waitForExistence(timeout: 10))
        let restoredPassage = restored.webViews.staticTexts.matching(NSPredicate(format: "value == %@", passageText)).firstMatch
        XCTAssertTrue(restoredPassage.waitForExistence(timeout: 10))
        XCTAssertTrue(restoredPassage.isHittable)
        snapshot(restored, "v04-epub-restored")
        menu(restored, "File", "Close book")
        XCTAssertTrue(restored.buttons.matching(NSPredicate(format: "label CONTAINS %@", "EPUB")).firstMatch.waitForExistence(timeout: 5))
        restored.terminate()
    }

    @MainActor func testLinkedImportSurvivesQuit() {
        let id = UUID().uuidString
        let app = launch(id, specimen: false)
        menu(app, "File", "Import linked book")
        choosePDF(app, relativePath: "Research/Fixtures/text.pdf")
        XCTAssertTrue(app.windows["text"].waitForExistence(timeout: 10))
        app.buttons["page.next"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
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
        menu(app, "File", "Open book")
        choosePDF(app, relativePath: "Research/Large/large-text.pdf")
        XCTAssertTrue(app.windows["large-text"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1/600"].waitForExistence(timeout: 5))
        menu(app, "Edit", "Find in book")
        let field = app.textFields["reader.search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        paste("responsive", into: field, app: app)
        XCTAssertTrue(app.buttons["reader.search.match"].firstMatch.waitForExistence(timeout: 10))
        let pages = app.scrollViews["reader.pages"].firstMatch
        XCTAssertTrue(pages.exists)
        app.typeKey(.escape, modifierFlags: [])
        pages.click()
        for _ in 0..<3 { pages.scroll(byDeltaX: 0, deltaY: -1200) }
        XCTAssertTrue(app.staticTexts["1/600"].waitForNonExistence(timeout: 5))
        snapshot(app, "v01-large-search")
        app.toolbars.buttons["reader.focus"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["library.sidebar"].waitForNonExistence(timeout: 5))
        app.toolbars.buttons["reader.close"].firstMatch.click()
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
            menu(app, "File", "Open book")
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

    @MainActor private func expectComfort(_ id: String, _ key: String, _ expected: String, timeout: TimeInterval = 6) {
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let url = home.appendingPathComponent("Library/Containers/\(targetApplicationBundleID)/Data/Library/Application Support/AdaptiveReader/Phase0Tests/\(id)/ComfortDiagnostics.json")
        let predicate = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let actual = (value[key] as? String) ?? (value[key] as? Bool).map { String($0) } ?? (value[key] as? Int).map { String($0) }
            return actual == expected
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, "Comfort state \(key) = \(expected)")
    }

    @MainActor func testDailyCommandCenterAndSmartBack() {
        let id = UUID().uuidString, app = launch(id, specimen: true, diagnostics: true)
        menu(app, "View", "Command Center")
        let field = app.textFields["command.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        paste("2", into: field, app: app)
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        menu(app, "View", "Back")
        XCTAssertTrue(app.staticTexts["1/3"].waitForExistence(timeout: 5))
        menu(app, "View", "Forward")
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        app.typeKey(goToFolderKey() == "п" ? "л" : "k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["command.query"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "v02-command-center")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["command.query"].firstMatch.waitForNonExistence(timeout: 5))
        menu(app, "View", "Command Center")
        let paletteQuery = app.textFields["command.query"].firstMatch
        XCTAssertTrue(paletteQuery.waitForExistence(timeout: 5))
        paste("Forest", into: paletteQuery, app: app)
        paletteQuery.typeKey(.return, modifierFlags: [])
        expectComfort(id, "palette", "forest")
        XCTAssertTrue(paletteQuery.waitForNonExistence(timeout: 5))
    }

    @MainActor func testCompanionEvidenceActionsAndNoteUndo() {
        let id = UUID().uuidString
        let app = launch(id, specimen: true, diagnostics: true, additionalArguments: ["-companionFixture", "YES", "-companionReview", "YES"])
        menu(app, "View", "AI Companion")
        XCTAssertTrue(app.staticTexts["ai.answer"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["ai.citation"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["ai.marginRail"].exists)
        app.buttons["ai.citation"].firstMatch.click()
        menu(app, "View", "Back")
        app.popUpButtons["ai.explainAgain"].firstMatch.click()
        app.menuItems["Simpler"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["ai.answer"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["ai.action.setTheme"].firstMatch.click()
        expectComfort(id, "palette", "forest")
        app.buttons["ai.action.createNote"].firstMatch.click()
        XCTAssertTrue(app.buttons["ai.saveNote"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["ai.saveNote"].firstMatch.click()
        XCTAssertTrue(app.buttons["ai.undoNote"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "v03-source-and-note")
        app.buttons["ai.undoNote"].firstMatch.click()
        XCTAssertTrue(app.buttons["ai.undoNote"].firstMatch.waitForNonExistence(timeout: 5))
        app.checkBoxes["ai.margins"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["ai.marginRail"].firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "v03-smart-margins")
        menu(app, "View", "Focus")
        XCTAssertTrue(app.descendants(matching: .any)["ai.marginRail"].firstMatch.waitForNonExistence(timeout: 5))
        menu(app, "View", "Focus")
        menu(app, "View", "AI Companion")
        app.buttons["ai.newTopic"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["ai.answer"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor func testCompanionCancellationAndScanWithoutText() {
        let app = launch(UUID().uuidString, specimen: true, additionalArguments: ["-companionFixture", "YES", "-companionReview", "YES", "-companionSlowFixture", "YES"])
        menu(app, "View", "AI Companion")
        XCTAssertTrue(app.buttons["ai.cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["ai.cancel"].firstMatch.click()
        XCTAssertTrue(app.buttons["ai.cancel"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["ai.answer"].firstMatch.exists)
        menu(app, "File", "Close book")
        menu(app, "File", "Open book")
        choosePDF(app, relativePath: "Research/Fixtures/scan.pdf")
        XCTAssertTrue(app.windows["scan"].firstMatch.waitForExistence(timeout: 10))
        menu(app, "View", "AI Companion")
        XCTAssertTrue(app.staticTexts["ai.error"].firstMatch.waitForExistence(timeout: 10))
        let error = app.staticTexts["ai.error"].firstMatch
        XCTAssertTrue(((error.value as? String) ?? error.label).contains("OCR"))
        XCTAssertFalse(app.staticTexts["ai.answer"].firstMatch.exists)
    }

    @MainActor func testCompanionCloudConsentIsExplicit() {
        let app = launch(UUID().uuidString, specimen: true)
        menu(app, "View", "AI Companion")
        app.buttons["ai.settings"].firstMatch.click()
        app.popUpButtons["ai.providerMode"].firstMatch.click(); app.menuItems["Cloud API"].firstMatch.click()
        paste("https://fixture.example/v1/chat/completions", into: app.textFields["ai.endpoint"].firstMatch, app: app)
        paste("fixture-model", into: app.textFields["ai.model"].firstMatch, app: app)
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Enable cloud sending for this endpoint before asking a question."].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["ai.cloudConsent"].firstMatch.exists)
        app.checkBoxes["ai.cloudConsent"].firstMatch.click()
        app.buttons["Save"].firstMatch.click()
        XCTAssertTrue(app.textFields["ai.endpoint"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud · selected excerpts will be sent"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["ai.answer"].firstMatch.exists)
    }

    @MainActor func testMagicSelectionKeepsSourceVisible() {
        let app = launch(UUID().uuidString, specimen: true, additionalArguments: ["-companionFixture", "YES"])
        app.scrollViews["reader.pages"].firstMatch.click()
        menu(app, "Edit", "Select All")
        XCTAssertTrue(app.buttons["ai.explainSelection"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["ai.explainSelection"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["ai.answer"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ai.explainSelection"].firstMatch.exists)
        snapshot(app, "v03-magic-selection")
    }

    @MainActor func testDailyTimerAndManualScrollCancellation() {
        let id = UUID().uuidString, app = launch(id, specimen: true, diagnostics: true)
        menu(app, "View", "Reading tools")
        XCTAssertTrue(app.buttons["comfort.start"].waitForExistence(timeout: 5))
        app.buttons["comfort.start"].click()
        expectComfort(id, "timerStatus", "running")
        app.buttons["comfort.pause"].click()
        expectComfort(id, "timerStatus", "paused")
        expectComfort(id, "driverActive", "false")
        app.buttons["comfort.pause"].click()
        expectComfort(id, "timerStatus", "running")
        app.buttons["comfort.stop"].click()
        expectComfort(id, "timerStatus", "completed")
        app.checkBoxes["comfort.spotlight"].firstMatch.click()
        app.checkBoxes["comfort.autoscroll"].firstMatch.click()
        expectComfort(id, "autoScrolling", "true")
        snapshot(app, "v02-reading-tools")
        app.buttons["Done"].firstMatch.click()
        app.scrollViews["reader.pages"].firstMatch.click()
        expectComfort(id, "autoScrolling", "false")
        expectComfort(id, "driverActive", "false")
        snapshot(app, "v02-spotlight")
        menu(app, "File", "Close book")
        expectComfort(id, "documentOpen", "false")
        expectComfort(id, "driverActive", "false")
    }

    @MainActor func testDailyMiniReaderTransfersPositionAndCommands() {
        let id = UUID().uuidString, app = launch(id, specimen: true, diagnostics: true)
        app.buttons["page.next"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2/3"].waitForExistence(timeout: 5))
        menu(app, "View", "Mini Reader")
        let mini = app.windows["Mini Reader"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertTrue(mini.staticTexts["2/3"].waitForExistence(timeout: 5))
        mini.buttons["Next page"].firstMatch.click()
        XCTAssertTrue(mini.staticTexts["3/3"].waitForExistence(timeout: 5))
        mini.checkBoxes["mini.onTop"].click()
        let top = mini.checkBoxes["mini.onTop"].value
        XCTAssertTrue((top as? NSNumber)?.boolValue == true || top as? String == "1")
        expectComfort(id, "miniLevel", String(NSWindow.Level.floating.rawValue))
        app.typeKey(goToFolderKey() == "п" ? "л" : "k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["command.query"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        let image = XCTAttachment(screenshot: mini.screenshot())
        image.name = "v02-mini-reader"; image.lifetime = .keepAlways; add(image)
        mini.buttons["mini.return"].firstMatch.click()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3/3"].waitForExistence(timeout: 5))
        expectComfort(id, "miniOpen", "false")
        menu(app, "File", "Close book")
        expectComfort(id, "driverActive", "false")
    }

    @MainActor func testDailyPhysicalFootnoteLinkReturnsToSource() {
        let app = launch(UUID().uuidString, specimen: false)
        menu(app, "File", "Open book")
        choosePDF(app, relativePath: "Research/Comfort/footnote.pdf")
        XCTAssertTrue(app.windows["footnote"].waitForExistence(timeout: 10))
        let pages = app.scrollViews["reader.pages"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        let scale = (pages.frame.width - 16) / 612
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 8 + 145 * scale, dy: 4 + (792 - 468) * scale)).click()
        XCTAssertTrue(app.staticTexts["3/3"].waitForExistence(timeout: 5))
        menu(app, "View", "Back")
        XCTAssertTrue(app.staticTexts["1/3"].waitForExistence(timeout: 5))
        snapshot(app, "v02-smart-back-footnote")
    }

    @MainActor func testDailyScheduledPaletteHonorsManualOverrideUntilBoundary() {
        let id = UUID().uuidString
        let app = launch(id, specimen: true, diagnostics: true, additionalArguments: ["-comfortScheduleProbe", "YES"])
        expectComfort(id, "palette", "paper")
        menu(app, "View", "Command Center")
        app.buttons["command.palette.forest"].firstMatch.click()
        expectComfort(id, "palette", "forest")
        expectComfort(id, "palette", "midnight", timeout: 135)
        snapshot(app, "v02-scheduled-palette")
        menu(app, "File", "Close book")
        expectComfort(id, "driverActive", "false")
    }

    @MainActor func testDailyClosingMainWindowClosesMiniAndStopsActivity() {
        let id = UUID().uuidString, app = launch(id, specimen: true, diagnostics: true)
        XCTAssertTrue(app.windows["Phase 0 reader"].waitForExistence(timeout: 10))
        menu(app, "View", "Reading tools")
        XCTAssertTrue(app.buttons["comfort.start"].waitForExistence(timeout: 5))
        app.buttons["comfort.start"].click()
        app.buttons["Done"].firstMatch.click()
        menu(app, "View", "Mini Reader")
        XCTAssertTrue(app.windows["Mini Reader"].waitForExistence(timeout: 5))
        app.windows["Phase 0 reader"].buttons["sidebar.toggle"].firstMatch.click()
        app.windows["Phase 0 reader"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.windows["Mini Reader"].waitForNonExistence(timeout: 5))
        expectComfort(id, "driverActive", "false")
        expectComfort(id, "sessionActive", "false")
    }

    @MainActor func testComfortTwentyFiveMinuteReleaseSession() throws {
        #if !COMFORT_SOAK
        throw XCTSkip("Opt-in real 25-minute Release Mini Reader/auto-scroll session on the control Mac")
        #else
        executionTimeAllowance = 1800
        let id = UUID().uuidString, app = launch(id, specimen: false, diagnostics: true, additionalArguments: ["-comfortSoak", "YES"])
        menu(app, "File", "Open book")
        choosePDF(app, relativePath: "Research/Large/large-text.pdf")
        XCTAssertTrue(app.windows["large-text"].waitForExistence(timeout: 10))
        menu(app, "View", "Mini Reader")
        let mini = app.windows["Mini Reader"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.checkBoxes["mini.onTop"].click()
        mini.buttons["Reading tools"].firstMatch.click()
        XCTAssertTrue(app.buttons["comfort.start"].waitForExistence(timeout: 5))
        app.buttons["comfort.start"].click()
        app.checkBoxes["comfort.autoscroll"].firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
        expectComfort(id, "autoScrolling", "true")
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let diagnostic = home.appendingPathComponent("Library/Containers/\(targetApplicationBundleID)/Data/Library/Application Support/AdaptiveReader/Phase0Tests/\(id)/ComfortDiagnostics.json")
        let start = ProcessInfo.processInfo.systemUptime
        var rows = [[String: Any]]()
        var complete = false
        while ProcessInfo.processInfo.systemUptime - start < 26 * 60 {
            XCTAssertNotEqual(app.state, .notRunning)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: diagnostic)) as! [String: Any]
            XCTAssertGreaterThan(state["rssBytes"] as? Double ?? -1, 0)
            var sample = state; sample["testElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            rows.append(sample)
            if state["timerStatus"] as? String == "completed" { complete = true; break }
            Thread.sleep(forTimeInterval: 30)
        }
        XCTAssertTrue(complete)
        expectComfort(id, "autoScrolling", "false")
        expectComfort(id, "driverActive", "false")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "v02-25-minute-release-session"; attachment.lifetime = .keepAlways; add(attachment)
        let image = XCTAttachment(screenshot: mini.screenshot()); image.name = "v02-soak-complete"; image.lifetime = .keepAlways; add(image)
        mini.buttons["mini.return"].firstMatch.click()
        menu(app, "File", "Close book")
        expectComfort(id, "documentOpen", "false")
        expectComfort(id, "driverActive", "false")
        #endif
    }

}
