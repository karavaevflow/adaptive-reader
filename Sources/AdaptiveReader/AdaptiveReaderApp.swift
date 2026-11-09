import SwiftUI

@main
struct AdaptiveReaderApp: App {
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system
    private let preferences: UserDefaults

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-designReview") {
            let suite = "com.karavaevflow.AdaptiveReader.designReview"
            let store = UserDefaults(suiteName: suite)!
            store.removePersistentDomain(forName: suite)
            store.set(UserDefaults.standard.string(forKey: "reviewAppearance") ?? "system", forKey: "shellAppearance")
            store.set(true, forKey: "sidebarVisible")
            store.set(false, forKey: "inspectorVisible")
            preferences = store
        } else { preferences = .standard }
        #else
        preferences = .standard
        #endif
        _appearance = AppStorage(wrappedValue: .system, "shellAppearance", store: preferences)
    }

    private var reviewMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-designReview")
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
                .background(WindowIntegration())
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
    func makeNSView(context: Context) -> NSView { FrameView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class FrameView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            #if DEBUG
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
