import SwiftUI
import FolioReader

/// Theme, typeface, size, spacing, margins and layout. Changes apply to the
/// open page instantly without losing the reading position.
struct AppearanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(EntitlementStore.self) private var entitlements
    @State private var showPremium = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Theme") {
                    HStack(spacing: 12) {
                        ForEach(ReadingTheme.builtIn) { theme in
                            ThemeSwatch(theme: theme, selected: model.readerSettings.theme.id == theme.id && model.readerSettings.automaticThemes == nil) {
                                model.readerSettings.theme = theme
                                model.readerSettings.automaticThemes = nil
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Toggle("Match system light and dark", isOn: Binding(
                        get: { model.readerSettings.automaticThemes != nil },
                        set: { model.readerSettings.automaticThemes = $0 ? ("warm-paper", "midnight") : nil }))
                }

                Section("Text") {
                    Picker("Typeface", selection: $model.readerSettings.typography.font) {
                        ForEach(FontChoice.allCases, id: \.self) { font in
                            Text(font.displayName).tag(font)
                        }
                    }
                    LabeledContent("Size") {
                        Stepper("\(Int(model.readerSettings.typography.fontSize)) pt",
                                value: $model.readerSettings.typography.fontSize, in: Typography.fontSizeRange, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Line spacing")
                        Slider(value: $model.readerSettings.typography.lineHeight, in: Typography.lineHeightRange, step: 0.05)
                            .accessibilityValue(String(format: "%.2f", model.readerSettings.typography.lineHeight))
                    }
                    VStack(alignment: .leading) {
                        Text("Margins")
                        Slider(value: $model.readerSettings.typography.margin, in: Typography.marginRange, step: 2)
                    }
                    Toggle("Justify text", isOn: $model.readerSettings.typography.justify)
                    Toggle("Hyphenation", isOn: $model.readerSettings.typography.hyphenate)
                }

                Section("Layout") {
                    Picker("Layout", selection: $model.readerSettings.layout) {
                        Text("Scroll").tag(LayoutMode.scroll)
                        Text("Pages").tag(LayoutMode.paginated)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPremium) { PremiumView() }
        }
    }

}

private struct ThemeSwatch: View {
    let theme: ReadingTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Color(theme.text))
                    .frame(width: 58, height: 58)
                    .background(Color(theme.background), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color(theme.accent) : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1)
                    }
                Text(theme.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
