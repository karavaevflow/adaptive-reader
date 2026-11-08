import SwiftUI

@main
struct AdaptiveReaderApp: App {
    @AppStorage("shellAppearance") private var appearance = ShellAppearance.system

    var body: some Scene {
        WindowGroup("Adaptive Reader") {
            WorkspaceView()
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 800, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)

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
        }
    }
}
