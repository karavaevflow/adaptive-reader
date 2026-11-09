import SwiftUI

// Document palettes belong to ReaderCore. These tokens describe the application shell.
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
    enum TypeStyle {
        static let title: Font = .system(.largeTitle, weight: .semibold)
        static let heading: Font = .system(.title2, weight: .semibold)
        static let section: Font = .system(.headline)
        static let body: Font = .system(.body)
        static let caption: Font = .system(.caption)
    }
    enum Layout {
        static let sidebar: CGFloat = 220
        static let inspector: CGFloat = 260
        static let sidebarThreshold: CGFloat = 1000
        static let inspectorThreshold: CGFloat = 1200
    }
    enum Motion {
        static let panel = Animation.easeInOut(duration: 0.22)
    }
    static let corner: CGFloat = 12
    static let background = color(light: 0xF5F5F3, dark: 0x17181B)
    static let surface = color(light: 0xFFFFFF, dark: 0x24262A)
    static let text = color(light: 0x202124, dark: 0xE8E9EB)
    // A stronger secondary color preserves small-text contrast on both surfaces.
    static let secondary = color(light: 0x666970, dark: 0xB0B3BA)
    static let divider = color(light: 0xE5E5E3, dark: 0x383A3F)
    static let accent = Color.accentColor

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255,
                alpha: 1
            )
        })
    }
}

struct AdaptivePanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if reduceTransparency { Adaptive.surface }
                else { Rectangle().fill(.regularMaterial) }
            }
    }
}

struct AdaptiveEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: Adaptive.Space.regular) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Adaptive.secondary)
                .accessibilityHidden(true)
            Text(title).font(Adaptive.TypeStyle.heading)
            Text(message)
                .font(Adaptive.TypeStyle.body)
                .foregroundStyle(Adaptive.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Adaptive.text)
        .padding(Adaptive.Space.large)
        .accessibilityElement(children: .combine)
    }
}

struct AppearancePicker: View {
    @Binding var appearance: ShellAppearance
    var body: some View {
        VStack(alignment: .leading, spacing: Adaptive.Space.regular) {
            Text("Appearance").font(Adaptive.TypeStyle.section)
            Picker("Appearance", selection: $appearance) {
                ForEach(ShellAppearance.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
        .padding(Adaptive.Space.large)
        .frame(width: 240, alignment: .leading)
        .background(Adaptive.surface)
        .foregroundStyle(Adaptive.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.popover")
    }
}

/// The card uses the same button, focus and selection semantics as library entries.
struct AdaptiveBookCard: View {
    let title: LocalizedStringKey
    let author: LocalizedStringKey
    let progress: Double
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Adaptive.Space.regular) {
                Image(systemName: "book.closed")
                    .font(.system(size: 28, weight: .light))
                    .frame(width: 56, height: 76)
                    .foregroundStyle(Adaptive.secondary)
                    .background(Adaptive.background, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Adaptive.Space.small) {
                    Text(title).font(Adaptive.TypeStyle.section)
                    Text(author).foregroundStyle(Adaptive.secondary)
                    ProgressView(value: progress)
                        .accessibilityLabel(Text("Reading progress"))
                }
            }
            .padding(Adaptive.Space.regular)
            .foregroundStyle(Adaptive.text)
            .background(hovering ? Adaptive.background : Adaptive.surface,
                        in: RoundedRectangle(cornerRadius: Adaptive.corner))
            .overlay {
                RoundedRectangle(cornerRadius: Adaptive.corner)
                    .strokeBorder(selected ? Adaptive.accent : Adaptive.divider, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Adaptive.corner))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ComponentCatalog: View {
    @State private var query = ""
    @State private var enabled = true
    @State private var selected = false
    @State private var appearance = ShellAppearance.system
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Adaptive.Space.large) {
                Text("Adaptive components").font(Adaptive.TypeStyle.heading)
                GroupBox("Typography") {
                    VStack(alignment: .leading, spacing: Adaptive.Space.small) {
                        Text("Adaptive Reader").font(Adaptive.TypeStyle.title)
                        Text("A quiet place to read.").font(Adaptive.TypeStyle.body)
                        Text("Reading progress").font(Adaptive.TypeStyle.caption).foregroundStyle(Adaptive.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Adaptive.Space.medium)
                }
                GroupBox("Controls") {
                    VStack(alignment: .leading, spacing: Adaptive.Space.regular) {
                        TextField("Search books", text: $query).textFieldStyle(.roundedBorder)
                        Toggle("Show sidebar", isOn: $enabled)
                        HStack {
                            Button("Select preview", systemImage: "checkmark") { selected.toggle() }
                                .buttonStyle(.borderedProminent)
                            Button("Unavailable") {}.disabled(true)
                        }
                        AdaptiveBookCard(title: "Book preview", author: "Author", progress: 0.42,
                                         selected: selected) { selected.toggle() }
                        AppearancePicker(appearance: $appearance)
                    }.padding(Adaptive.Space.medium)
                }
            }
            .padding(Adaptive.Space.large)
        }
        .background(Adaptive.background)
        .foregroundStyle(Adaptive.text)
        .frame(width: 560, height: 580)
    }
}
