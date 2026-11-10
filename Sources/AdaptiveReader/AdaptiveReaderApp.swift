import SwiftUI

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

struct WorkspaceActions {
    var openDocument: () -> Void
    var toggleSidebar: () -> Void
    var toggleAppearance: () -> Void
    var toggleInspector: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
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
            Button("Open PDF") { actions?.openDocument() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Zoom in") { actions?.zoomIn() }.keyboardShortcut("+", modifiers: .command).disabled(actions == nil)
            Button("Zoom out") { actions?.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(actions == nil)
            Button("Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Appearance") { actions?.toggleAppearance() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Document inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

/// Sizes DEBUG visual-review windows after attachment to the native window.
struct WindowIntegration: NSViewRepresentable {
    let autosaveName: String
    func makeNSView(context: Context) -> NSView {
        let view = FrameView()
        view.autosaveName = autosaveName
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class FrameView: NSView {
        var autosaveName = ""
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
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
                window.setFrame(NSRect(x: 0, y: 40, width: width, height: 780), display: true)
            }
            #endif
        }
    }
}
