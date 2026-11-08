import SwiftUI

// Shell appearance deliberately has no dependency on document page palettes.
enum ShellAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Adaptive {
    enum Space {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let large: CGFloat = 24
        static let extraLarge: CGFloat = 32
    }
    static let corner: CGFloat = 12
    static let body: Font = .system(.body)
    static let heading: Font = .system(.title2, weight: .semibold)
    static let caption: Font = .system(.caption)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
}

struct AdaptiveEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct ComponentCatalog: View {
    @State private var query = ""
    @State private var enabled = true
    var body: some View {
        Form {
            Section("Typography") {
                Text("Adaptive Reader").font(Adaptive.heading)
                Text("A quiet place to read.").font(Adaptive.body)
                Text("Reading progress").font(Adaptive.caption).foregroundStyle(.secondary)
            }
            Section("Controls") {
                TextField("Search books", text: $query)
                Toggle("Show sidebar", isOn: $enabled)
                HStack {
                    Button("Open PDF", systemImage: "doc") {}
                    Button("Unavailable") {}.disabled(true)
                }
                ProgressView(value: 0.42) { Text("Reading progress") }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .navigationTitle("Adaptive components")
    }
}
