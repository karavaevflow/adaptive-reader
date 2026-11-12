import SwiftUI
import Combine

@main
struct AdaptiveReaderApp: App {
    @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var delegate
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system
    private let preferences: UserDefaults

    init() {
        #if DEBUG || FOUNDATION_BENCHMARK
        if ProcessInfo.processInfo.arguments.contains("-designReview") {
            let suite = "com.karavaevflow.AdaptiveReader.designReview"
            let store = UserDefaults(suiteName: suite)!
            store.removePersistentDomain(forName: suite)
            store.set(UserDefaults.standard.string(forKey: "reviewAppearance") ?? "system", forKey: "shellAppearance")
            store.set(true, forKey: "sidebarVisible")
            store.set(false, forKey: "inspectorVisible")
            preferences = store
        } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-phase0Store"),
                  index + 1 < ProcessInfo.processInfo.arguments.count,
                  let id = UUID(uuidString: ProcessInfo.processInfo.arguments[index + 1]) {
            preferences = UserDefaults(suiteName: "com.karavaevflow.AdaptiveReader.phase0.\(id.uuidString)")!
            preferences.register(defaults: ["shellAppearance": "light", "sidebarVisible": true, "inspectorVisible": false])
        } else { preferences = .standard }
        #else
        preferences = .standard
        #endif
        _appearance = AppStorage(wrappedValue: .system, "shellAppearance", store: preferences)
    }

    private var reviewMode: Bool {
        #if DEBUG || FOUNDATION_BENCHMARK
        ProcessInfo.processInfo.arguments.contains("-designReview") || ProcessInfo.processInfo.arguments.contains("-phase0Store")
        #else
        false
        #endif
    }
    private var initialWidth: CGFloat {
        guard reviewMode else { return 1120 }
        let width = UserDefaults.standard.double(forKey: "designWidth")
        return width == 800 || width == 1440 ? width : 1120
    }

    var body: some Scene {
        WindowGroup("Adaptive Reader") {
            WorkspaceView()
                .preferredColorScheme(appearance.colorScheme)
                .defaultAppStorage(preferences)
                .frame(minWidth: 800, minHeight: 560)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Reading workspace"))

        }
        .defaultSize(width: initialWidth, height: 760)
        .restorationBehavior(reviewMode ? .disabled : .automatic)
        .windowStyle(.titleBar)
        .defaultLaunchBehavior(.presented)
        .commands { WorkspaceCommands() }

        Settings {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(ShellAppearance.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(24)
            .frame(width: 360)
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// One application entry point, shared by native menus, toolbar and future adapters.
enum WorkspaceCommand: String, CaseIterable, Identifiable, Hashable {
    case openDocument, importReference, closeBook, search, toggleBookmark, toggleFocus, toggleAwake
    case toggleSidebar, toggleAppearance, toggleInspector, zoomIn, zoomOut
    case commandCenter, readingTools, back, forward, toggleSpotlight, spotlightNext, spotlightPrevious, nextPassage, previousPassage
    case toggleAutoScroll, toggleSession, stopSession, miniReader, returnToReader, companion
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openDocument: "Open book"
        case .importReference: "Import linked book"
        case .closeBook: "Close book"
        case .search: "Find in book"
        case .toggleBookmark: "Bookmark page"
        case .toggleFocus: "Focus"
        case .toggleAwake: "Keep Awake"
        case .toggleSidebar: "Sidebar"
        case .toggleAppearance: "Appearance"
        case .toggleInspector: "Document inspector"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .commandCenter: "Command Center"
        case .readingTools: "Reading tools"
        case .nextPassage: "Next text block"
        case .previousPassage: "Previous text block"
        case .back: "Back"
        case .forward: "Forward"
        case .toggleSpotlight: "Reading Spotlight"
        case .spotlightNext: "Next spotlight line"
        case .spotlightPrevious: "Previous spotlight line"
        case .toggleAutoScroll: "Toggle auto-scroll"
        case .toggleSession: "Start, pause or resume session"
        case .stopSession: "End session"
        case .miniReader: "Mini Reader"
        case .returnToReader: "Return to Reader"
        case .companion: "AI Companion"
        }
    }
    @MainActor func isEnabled(in session: ReaderSession) -> Bool {
        switch self {
        case .openDocument, .importReference: !session.busy
        case .commandCenter, .toggleSidebar, .toggleAppearance, .toggleInspector: true
        case .readingTools: true
        case .nextPassage, .previousPassage: session.engine?.capabilities.contains(.passageNavigation) == true
        case .back: session.commands?.canGoBack == true
        case .forward: session.commands?.canGoForward == true
        case .toggleSpotlight: session.engine?.capabilities.contains(.readingFocus) == true
        case .zoomIn, .zoomOut: session.engine?.capabilities.contains(.zoom) == true
        case .spotlightNext, .spotlightPrevious: session.pdfEngine?.spotlightEnabled == true
        case .stopSession: session.readingTimer.status == .running || session.readingTimer.status == .paused
        case .miniReader: session.pdfEngine != nil && !session.miniReaderActive
        case .returnToReader: session.miniReaderActive
        case .search: session.engine?.capabilities.contains(.search) == true || (session.engine == nil && !session.books.isEmpty)
        default: session.engine != nil && !session.busy
        }
    }
    @MainActor func displayLabel(in session: ReaderSession) -> String {
        if self == .search && session.engine == nil { return "Search books" }
        if self == .toggleSession {
            switch session.readingTimer.status {
            case .running: return "Pause session"
            case .paused: return "Resume session"
            default: return "Start session"
            }
        }
        if self == .toggleAutoScroll { return session.autoScrolling ? "Stop auto-scroll" : "Start auto-scroll" }
        return label
    }
    static var mainCommands: [Self] { allCases.filter { $0 != .commandCenter && $0 != .returnToReader } }
    static let miniCommands: [Self] = [.returnToReader, .back, .forward, .nextPassage, .previousPassage, .toggleBookmark, .readingTools, .toggleSpotlight, .spotlightNext, .spotlightPrevious, .toggleAutoScroll, .toggleSession, .stopSession, .toggleAwake, .zoomIn, .zoomOut, .closeBook]
}

struct WorkspaceActions {
    var hasBook: Bool
    var canSearch: Bool
    var canGoBack = false
    var canGoForward = false
    var canStepReading = false
    var enabledCommands: Set<WorkspaceCommand> = []
    var perform: (WorkspaceCommand) -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceActions) private var actions
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open book") { actions?.perform(.openDocument) }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Import linked book") { actions?.perform(.importReference) }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(actions == nil)
            Button("Close book") { actions?.perform(.closeBook) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(actions?.hasBook != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Center") { actions?.perform(.commandCenter) }.keyboardShortcut("k").disabled(actions == nil)
            Button("Reading tools") { actions?.perform(.readingTools) }.disabled(actions == nil)
            Button("AI Companion") { actions?.perform(.companion) }.disabled(actions?.hasBook != true)
            Button("Back") { actions?.perform(.back) }.keyboardShortcut("[").disabled(actions?.canGoBack != true)
            Button("Forward") { actions?.perform(.forward) }.keyboardShortcut("]").disabled(actions?.canGoForward != true)
            Button("Next text block") { actions?.perform(.nextPassage) }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(actions?.canStepReading != true)
            Button("Previous text block") { actions?.perform(.previousPassage) }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(actions?.canStepReading != true)
            Button("Reading Spotlight") { actions?.perform(.toggleSpotlight) }.disabled(actions?.enabledCommands.contains(.toggleSpotlight) != true)
            Button("Auto-scroll") { actions?.perform(.toggleAutoScroll) }.disabled(actions?.enabledCommands.contains(.toggleAutoScroll) != true)
            Button("Mini Reader") { actions?.perform(.miniReader) }.disabled(actions?.enabledCommands.contains(.miniReader) != true)
        }
        CommandGroup(after: .textEditing) {
            Button(LocalizedStringKey(actions?.hasBook == true ? "Find in book" : "Search books")) { actions?.perform(.search) }.keyboardShortcut("f").disabled(actions?.canSearch != true)
            Button("Bookmark page") { actions?.perform(.toggleBookmark) }.keyboardShortcut("d").disabled(actions?.hasBook != true)
        }
        CommandGroup(after: .sidebar) {
            Button("Zoom in") { actions?.perform(.zoomIn) }.keyboardShortcut("+", modifiers: .command).disabled(actions?.enabledCommands.contains(.zoomIn) != true)
            Button("Zoom out") { actions?.perform(.zoomOut) }.keyboardShortcut("-", modifiers: .command).disabled(actions?.enabledCommands.contains(.zoomOut) != true)
            Button("Focus") { actions?.perform(.toggleFocus) }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(actions?.hasBook != true)
            Button("Keep Awake") { actions?.perform(.toggleAwake) }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(actions?.hasBook != true)
            Button("Sidebar") { actions?.perform(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Appearance") { actions?.perform(.toggleAppearance) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Document inspector") { actions?.perform(.toggleInspector) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

/// Sizes DEBUG visual-review windows after attachment to the native window.
struct NativeFocusRequest: Equatable {
    let identifier: String
    let token = UUID()
}

struct WindowIntegration: NSViewRepresentable {
    let autosaveName: String
    var focusRequest: NativeFocusRequest?
    var onClose: (() -> Void)? = nil
    func makeNSView(context: Context) -> NSView {
        let view = FrameView()
        view.autosaveName = autosaveName
        view.onClose = onClose
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FrameView else { return }
        view.onClose = onClose
        if let focusRequest { view.requestFocus(focusRequest) }
    }
    private final class FrameView: NSView {
        var autosaveName = ""
        var onClose: (() -> Void)?
        private var closeObservation: AnyCancellable?
        private var lastRequest: UUID?
        private var pendingFocus: NativeFocusRequest?
        private var keyObserver: NSObjectProtocol?
        func requestFocus(_ request: NativeFocusRequest) {
            guard request.token != lastRequest else { return }
            lastRequest = request.token
            pendingFocus = request
            DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
        }

        private func applyPendingFocus() {
            guard let window, window.isKeyWindow, let request = pendingFocus else { return }
            func target(in node: any NSAccessibilityProtocol, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
                guard depth < 20 else { return nil }
                for child in node.accessibilityChildren() ?? [] {
                    if let element = child as? any NSAccessibilityProtocol,
                       let found = target(in: element, depth: depth + 1) { return found }
                }
                return node.accessibilityIdentifier() == request.identifier ? node : nil
            }
            guard let element = target(in: window) else { return }
            if let view = element as? NSView { window.makeFirstResponder(view) }
            element.setAccessibilityFocused(true)
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
            pendingFocus = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil; closeObservation = nil
            if let window {
                closeObservation = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose?() }
                }
                keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                    object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyPendingFocus() }
                }
            }
            if let window, !autosaveName.isEmpty {
                window.setFrameUsingName(autosaveName)
                window.setFrameAutosaveName(autosaveName)
            }
            #if DEBUG || FOUNDATION_BENCHMARK
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-designReview"),
                  let index = arguments.firstIndex(of: "-designWidth"), index + 1 < arguments.count,
                  let width = Double(arguments[index + 1]), [800.0, 1440.0].contains(width),
                  let window else { return }
            DispatchQueue.main.async {
                window.setFrame(NSRect(x: 0, y: 100, width: width, height: 780), display: true)
            }
            #endif
        }
    }
}
