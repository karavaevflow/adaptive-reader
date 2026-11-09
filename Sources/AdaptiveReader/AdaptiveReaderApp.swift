import SwiftUI

@main
struct AdaptiveReaderApp: App {
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system

    private var reviewMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--design-review")
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
                .frame(minWidth: 800, minHeight: 560)

        }
        .defaultSize(width: initialWidth, height: 760)
        .restorationBehavior(reviewMode ? .disabled : .automatic)
        .windowStyle(.titleBar)
        .defaultLaunchBehavior(.presented)

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
