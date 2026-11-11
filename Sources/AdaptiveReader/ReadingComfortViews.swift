import SwiftUI
import ReaderCore
import AppKit

struct ReadingToolsView: View {
    @Bindable var session: ReaderSession
    @State private var duration = 25
    @State private var customMinutes = 25
    @State private var editingGlobal = false
    @State private var invalidAmbientTimes = false

    private var ambient: Binding<AmbientReadingSettings> {
        Binding(get: { editingGlobal ? session.ambientDefaults : session.effectiveAmbient }, set: { value in
            guard value.dayMinute != value.nightMinute else { invalidAmbientTimes = true; return }
            invalidAmbientTimes = false
            session.updateAmbientSettings(value, global: editingGlobal)
        })
    }
    private func timeBinding(_ path: WritableKeyPath<AmbientReadingSettings, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: ambient.wrappedValue[keyPath: path], to: Calendar.current.startOfDay(for: Date()))!
        }, set: { date in
            let values = Calendar.current.dateComponents([.hour, .minute], from: date)
            var value = ambient.wrappedValue; value[keyPath: path] = (values.hour ?? 0) * 60 + (values.minute ?? 0)
            ambient.wrappedValue = value
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Reading tools").font(.title2.weight(.semibold))
                sessionControls
                Divider()
                HStack {
                    Text("Text blocks").font(.caption).foregroundStyle(Adaptive.secondary)
                    Spacer()
                    Button("Previous text block", systemImage: "arrow.up.to.line") { session.stepPassage(-1) }
                    Button("Next text block", systemImage: "arrow.down.to.line") { session.stepPassage(1) }
                }.labelStyle(.iconOnly).disabled(session.engine?.capabilities.contains(.passageNavigation) != true)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Reading Spotlight", isOn: Binding(get: { session.engine?.spotlightEnabled == true }, set: { _ in session.toggleSpotlight() }))
                        .disabled(session.engine == nil).accessibilityIdentifier("comfort.spotlight")
                    if session.engine?.spotlightEnabled == true {
                        Text(LocalizedStringKey(session.engine?.spotlightUsesText == true ? "Move the pointer over a line. Use Option–Up/Down to advance." : "Area spotlight: no text at this position."))
                            .font(.caption).foregroundStyle(Adaptive.secondary)
                        HStack {
                            Button("Previous line", systemImage: "arrow.up") { session.stepSpotlight(-1) }
                            Button("Next line", systemImage: "arrow.down") { session.stepSpotlight(1) }
                        }
                    }
                    Toggle("Auto-scroll", isOn: Binding(get: { session.autoScrolling }, set: { session.setAutoScroll($0) }))
                        .disabled(session.engine == nil).accessibilityIdentifier("comfort.autoscroll")
                    HStack {
                        Slider(value: Binding(get: { session.comfort.autoScrollSpeed }, set: { session.comfort.autoScrollSpeed = $0; session.saveComfortPreferences() }), in: 8...160)
                            .accessibilityLabel(Text("Scroll speed"))
                        Text("\(Int(session.comfort.autoScrollSpeed)) pt/s").monospacedDigit().font(.caption).frame(width: 65)
                    }
                    Text("Manual scrolling or selection stops auto-scroll.").font(.caption).foregroundStyle(Adaptive.secondary)
                    Button("Mini Reader", systemImage: "pip") { session.showMiniReader() }
                        .disabled(session.engine == nil || session.miniReaderActive).accessibilityIdentifier("comfort.mini")
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ambient Reading").font(.headline)
                    Picker("Applies to", selection: $editingGlobal) {
                        Text("This book").tag(false)
                        Text("Library defaults").tag(true)
                    }.pickerStyle(.segmented)
                    if !editingGlobal {
                        Toggle("Use library defaults", isOn: Binding(get: { session.comfort.ambient == nil }, set: { inherits in
                            session.comfort.ambient = inherits ? nil : session.ambientDefaults
                            session.comfort.manualOverrideUntil = nil; session.comfort.manualOverrideSystemDark = nil
                            session.saveComfortPreferences()
                        })).disabled(session.record == nil)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Palette automation", selection: ambient.strategy) {
                            Text("Manual").tag(AmbientStrategy.manual)
                            Text("System").tag(AmbientStrategy.system)
                            Text("Schedule").tag(AmbientStrategy.schedule)
                        }.accessibilityIdentifier("comfort.ambient.strategy")
                        if ambient.wrappedValue.strategy != .manual {
                            palettePicker("Day palette", value: ambient.dayPalette)
                            palettePicker("Night palette", value: ambient.nightPalette)
                            if ambient.wrappedValue.strategy == .schedule {
                                DatePicker("Day begins", selection: timeBinding(\.dayMinute), displayedComponents: .hourAndMinute)
                                DatePicker("Night begins", selection: timeBinding(\.nightMinute), displayedComponents: .hourAndMinute)
                            }
                            Picker("Manual palette choice", selection: ambient.manualBehavior) {
                                Text("Until next switch").tag(ManualPaletteBehavior.untilNextChange)
                                Text("Turn automation off").tag(ManualPaletteBehavior.disableAutomation)
                            }
                        }
                    }.disabled(!editingGlobal && session.comfort.ambient == nil)
                    if invalidAmbientTimes { Text("Day and night must start at different times.").font(.caption).foregroundStyle(.red) }
                    Text("Shell appearance and page palettes are independent.").font(.caption).foregroundStyle(Adaptive.secondary)
                }
            }.padding(24)
        }.frame(minWidth: 320, idealWidth: 380, maxWidth: 420, minHeight: 360, idealHeight: 520, maxHeight: 580)
            .accessibilityElement(children: .contain).accessibilityIdentifier("comfort.panel")
    }
    private func palettePicker(_ title: LocalizedStringKey, value: Binding<PagePalette>) -> some View {
        Picker(title, selection: value) { ForEach(PagePalette.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) } }
    }
    @ViewBuilder private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading session").font(.headline)
            if session.readingTimer.status == .running || session.readingTimer.status == .paused {
                HStack {
                    Text(clockString(session.readingTimer.remaining ?? session.readingTimer.elapsed)).font(.system(.title, design: .monospaced))
                        .accessibilityIdentifier("comfort.timer")
                    if session.readingTimer.status == .paused { Text("Paused").foregroundStyle(Adaptive.secondary) }
                    Spacer()
                    Button(LocalizedStringKey(session.readingTimer.status == .running ? "Pause session" : "Resume session")) {
                        if session.readingTimer.status == .running { session.pauseReadingSession() } else { session.resumeReadingSession() }
                    }.accessibilityIdentifier("comfort.pause")
                    Button("End session") { session.stopReadingSession() }.accessibilityIdentifier("comfort.stop")
                }
                if let total = session.readingTimer.duration { ProgressView(value: session.readingTimer.elapsed, total: total) }
            } else {
                if session.readingTimer.status == .completed {
                    Text("Session complete").font(.headline)
                    Text("\(clockString(session.readingTimer.elapsed)) read").font(.caption)
                    if let end = session.readingTimer.endAnchor, case .pdf(let point) = end.position { Text("Ended on page \(point.pageIndex + 1)").font(.caption) }
                }
                Picker("Session length", selection: $duration) {
                    Text("15 minutes").tag(15); Text("25 minutes").tag(25); Text("45 minutes").tag(45)
                    Text("Custom").tag(-1); Text("Free reading").tag(0)
                }
                if duration == -1 { Stepper("\(customMinutes) minutes", value: $customMinutes, in: 1...180) }
                Button("Start session", systemImage: "play.fill") {
                    session.startReadingSession(minutes: duration == 0 ? nil : (duration == -1 ? customMinutes : duration))
                }.disabled(session.engine == nil).accessibilityIdentifier("comfort.start")
            }
        }
    }
}

func clockString(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

struct CommandCenterView: View {
    @Bindable var session: ReaderSession
    var commands: [WorkspaceCommand]
    var perform: (WorkspaceCommand) -> Void
    var dismiss: () -> Void
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    private var filtered: [WorkspaceCommand] {
        commands.filter { query.isEmpty || NSLocalizedString($0.displayLabel(in: session), comment: "Command").localizedCaseInsensitiveContains(query) }
    }
    private var palettes: [PagePalette] {
        guard session.engine != nil else { return [] }
        return PagePalette.allCases.filter { query.isEmpty || NSLocalizedString($0.rawValue.capitalized, comment: "Palette").localizedCaseInsensitiveContains(query) }
    }
    private var page: Int? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(value), number > 0, number <= (session.engine?.document.pageCount ?? 0) else { return nil }
        return number
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command").foregroundStyle(Adaptive.secondary)
                TextField("Command or page number", text: $query).textFieldStyle(.plain)
                    .focused($fieldFocused).accessibilityIdentifier("command.query")
                    .onSubmit {
                        if let page { session.navigate(page: page); dismiss() }
                        else if let first = filtered.first(where: { $0.isEnabled(in: session) }) { perform(first) }
                        else if let palette = palettes.first { session.setPalette(palette); dismiss() }
                    }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollViewReader { _ in
                List {
                    if let page { Button("Go to page \(page)") { session.navigate(page: page); dismiss() }.accessibilityIdentifier("command.page") }
                    ForEach(filtered) { command in
                        Button { perform(command) } label: {
                            HStack { Text(LocalizedStringKey(command.displayLabel(in: session))); Spacer(); Image(systemName: "return").foregroundStyle(Adaptive.secondary) }
                                .padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!command.isEnabled(in: session)).accessibilityIdentifier("command.\(command.rawValue)")
                    }
                    if !palettes.isEmpty {
                        Section("Page palette") {
                            ForEach(palettes, id: \.self) { palette in
                                Button(LocalizedStringKey(palette.rawValue.capitalized)) { session.setPalette(palette); dismiss() }
                                    .accessibilityIdentifier("command.palette.\(palette.rawValue)")
                            }
                        }
                    }
                    if filtered.isEmpty && page == nil && palettes.isEmpty { Text("No matching commands").foregroundStyle(Adaptive.secondary) }
                }.listStyle(.plain)
            }
            Divider()
            HStack { Text("Commands work offline").font(.caption).foregroundStyle(Adaptive.secondary); Spacer(); Text("⌘K").font(.caption.monospaced()) }.padding(16)
        }.frame(minWidth: 320, idealWidth: 500, maxWidth: 560, minHeight: 380, idealHeight: 440)
            .onAppear { fieldFocused = true }
            .accessibilityElement(children: .contain).accessibilityIdentifier("command.center")
    }
}

@MainActor
final class MiniReaderController: NSObject, NSWindowDelegate {
    private weak var session: ReaderSession?
    private weak var mainWindow: NSWindow?
    private let panel: MiniReadingPanel
    private var finishing = false
    init(session: ReaderSession) {
        self.session = session; mainWindow = session.engine?.view.window
        panel = MiniReadingPanel(contentRect: NSRect(x: 140, y: 180, width: 420, height: 600), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.identifier = NSUserInterfaceItemIdentifier("reader.mini")
        panel.setAccessibilityIdentifier("reader.mini")
        panel.showCommands = { [weak session] in session?.commandCenterVisible.toggle() }
        panel.title = NSLocalizedString("Mini Reader", comment: "Window")
        panel.minSize = NSSize(width: 320, height: 360)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.delegate = self
        var autosave = "AdaptiveReader.Mini"
        #if DEBUG || FOUNDATION_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-designReview") { autosave = "" }
        else if let index = arguments.firstIndex(of: "-phase0Store"), index + 1 < arguments.count { autosave = "AdaptiveReader.Test.Mini.\(arguments[index + 1])" }
        #endif
        if !autosave.isEmpty { panel.setFrameUsingName(autosave); panel.setFrameAutosaveName(autosave) }
    }
    func present() {
        guard let session else { return }
        _ = session.prepareViewportTransfer()
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, session.miniReaderActive else { return }
            session.engine?.view.removeFromSuperview()
            self.panel.contentView = NSHostingView(rootView: MiniReaderView(session: session))
            self.updateLevel(); self.panel.makeKeyAndOrderFront(nil)
        }
    }
    var windowLevel: Int { panel.level.rawValue }
    func updateLevel() {
        panel.level = session?.comfort.miniAlwaysOnTop == true ? .floating : .normal
        updateAppearance(); session?.writeComfortDiagnostics(force: true)
    }
    func updateAppearance() {
        switch session?.shellAppearance ?? .system {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
    }
    func finish(revealMain: Bool) {
        guard !finishing else { return }; finishing = true
        _ = session?.prepareViewportTransfer()
        session?.engine?.view.removeFromSuperview(); panel.contentView = nil; panel.close()
        if revealMain { mainWindow?.makeKeyAndOrderFront(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finishing { return true }
        DispatchQueue.main.async { [weak session] in session?.pauseReadingSession(); session?.closeMiniReader() }
        return false
    }
}

private struct MiniReaderView: View {
    @Bindable var session: ReaderSession
    @State private var tools = false
    @State private var pendingCommand: WorkspaceCommand?
    var body: some View {
        VStack(spacing: 0) {
            if let engine = session.engine { NativePDFView(engine: engine, session: session) }
            Divider()
            HStack(spacing: 10) {
                Button("Previous page", systemImage: "chevron.left") { session.navigate(page: session.pageNumber - 1) }.disabled(session.pageNumber <= 1)
                Text("\(session.pageNumber)/\(session.engine?.document.pageCount ?? 0)").monospacedDigit().font(.caption)
                Button("Next page", systemImage: "chevron.right") { session.navigate(page: session.pageNumber + 1) }.disabled(session.pageNumber >= (session.engine?.document.pageCount ?? 0))
                Spacer()
                if session.readingTimer.status == .running || session.readingTimer.status == .paused { Text(clockString(session.readingTimer.remaining ?? session.readingTimer.elapsed)).font(.caption.monospacedDigit()) }
                Button("Reading tools", systemImage: "slider.horizontal.3") { tools.toggle() }.popover(isPresented: $tools) { ReadingToolsView(session: session) }
                Button("Return to Reader", systemImage: "arrow.up.left.and.arrow.down.right") { session.closeMiniReader() }.accessibilityIdentifier("mini.return")
            }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(12)
            HStack {
                Toggle("Keep on top", isOn: Binding(get: { session.comfort.miniAlwaysOnTop }, set: { session.comfort.miniAlwaysOnTop = $0; session.saveComfortPreferences(); session.miniReader?.updateLevel() }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("mini.onTop")
                Spacer()
                Button("Command Center", systemImage: "command") { session.commandCenterVisible.toggle() }.labelStyle(.iconOnly)
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }.background(Adaptive.background)
        .sheet(isPresented: $session.commandCenterVisible, onDismiss: {
            if let command = pendingCommand { pendingCommand = nil; miniPerform(command) }
        }) {
            CommandCenterView(session: session, commands: WorkspaceCommand.miniCommands, perform: { command in pendingCommand = command; session.commandCenterVisible = false }, dismiss: { session.commandCenterVisible = false })
        }
        .preferredColorScheme(session.shellAppearance.colorScheme)
        .onChange(of: session.shellAppearance) { session.miniReader?.updateAppearance() }
        .onChange(of: session.comfort.miniAlwaysOnTop) { session.miniReader?.updateLevel() }
    }
    private func miniPerform(_ command: WorkspaceCommand) {
        if command == .readingTools { tools = true }
        else { _ = session.performReadingCommand(command) }
    }
}

/// The floating panel shares commands while remaining independent of SwiftUI scene focus.
@MainActor private final class MiniReadingPanel: NSPanel {
    var showCommands: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command && event.keyCode == 40 {
            showCommands?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
