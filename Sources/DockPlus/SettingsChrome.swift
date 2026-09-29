import AppKit
import SwiftUI

// The settings window's visual vocabulary, copied from Cmd-Tab's so the two apps' settings are
// indistinguishable: a sidebar of tabs with gradient icon badges and a search field, and content
// built from titled sections whose rows sit inside a rounded card. Cmd-Tab's localisation lookup
// and colour control are left behind — DockPlus has nothing they serve.

enum SettingsChrome {
    static let cardCorner: CGFloat = 14
    static let hairline: CGFloat = 0.5

    /// Pitched a little heavier than a card on an opaque window would be: these sit on glass, and a
    /// faint fill over a backdrop that shows the desktop through it does not read as a card at all.
    static let cardFill = Color.primary.opacity(0.05)
    static let cardBorder = Color.primary.opacity(0.09)
    static let divider = Color.primary.opacity(0.07)

    static let rowInset: CGFloat = 14
    static let pageInset: CGFloat = 18
}

// MARK: - Page

/// A tab's content: a scrolling column of sections under the tab's own title.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 21, weight: .bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.pageInset)
            .padding(.top, 15)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Flash (search result → the section it landed on)

private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Anchor of the section a search result just navigated to. That section outlines itself for a
    /// moment — the only thing that tells the user which of the rows they were sent to.
    var settingsFlash: String? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }
}

// MARK: - Section

/// A titled group of rows inside a rounded card. Rows draw their own top divider, so the first
/// one lands on the card's top edge under the border stroke and a section needs no "last row" logic.
struct SettingsSection<Content: View>: View {
    let title: String
    /// Identifier the search index scrolls to, and the one `settingsFlash` names.
    var anchor: String?
    var footer: String?
    @ViewBuilder let content: Content

    @Environment(\.settingsFlash) private var flash

    private var isFlashing: Bool { anchor != nil && anchor == flash }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                        .fill(SettingsChrome.cardFill))
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                        .strokeBorder(
                            isFlashing ? Color.accentColor : SettingsChrome.cardBorder,
                            lineWidth: isFlashing ? 2 : SettingsChrome.hairline))
                .animation(.easeInOut(duration: 0.25), value: isFlashing)

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .id(anchor ?? title)
    }
}

// MARK: - Rows

/// Label and optional explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var controlWidth: CGFloat?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
                .frame(width: controlWidth, alignment: .trailing)
                // Every control is built with `labelsHidden()` so they line up down the card's
                // edge, which hides the label from VoiceOver too; this restores the association.
                .accessibilityLabel(title)
                .accessibilityHint(subtitle ?? "")
        }
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
        .settingsRowDivider()
    }
}

/// A row that is one full-width control rather than a label/control pair.
struct SettingsWideRow<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.system(size: 13)) }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 11)
        .settingsRowDivider()
    }
}

extension View {
    /// The hairline above a row, optionally starting past a leading icon column.
    func settingsRowDivider(leadingInset: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(SettingsChrome.divider)
                .frame(height: SettingsChrome.hairline)
                .padding(.leading, leadingInset)
        }
    }
}

// MARK: - Common controls

struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A slider with its value beside it — these are point sizes someone may want to set exactly.
struct SettingsSlider: View {
    let title: String
    var subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Shown in place of the bare number, for sliders whose unit is not points.
    var format: ((Double) -> String)?

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, controlWidth: 190) {
            HStack(spacing: 8) {
                Slider(value: stepped, in: range)
                Text(format?(value) ?? "\(Int(value))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Natural width, one line: "2.0 icons" wrapped to three lines in a fixed 30pt.
                    .fixedSize()
                    .frame(minWidth: 30, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .accessibilityValue(format?(value) ?? "\(Int(value)) points")
        }
    }

    /// Snapped on the way in rather than by handing `step` to the `Slider`, which would draw a tick
    /// mark under the track for every step.
    private var stepped: Binding<Double> {
        Binding(
            get: { value },
            set: { new in
                let snapped = (new / step).rounded() * step
                value = min(max(snapped, range.lowerBound), range.upperBound)
            })
    }
}

/// A choice shown as cards with a symbol, for options that read better seen than named.
struct SettingsChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var symbol: String?
        var id: Value { value }
    }

    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        SettingsWideRow(title: title, subtitle: subtitle) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        card(for: option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(option.value == selection ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func card(for option: Option) -> some View {
        let isSelected = option.value == selection
        return HStack(spacing: 6) {
            if let symbol = option.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            Text(option.title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.06 : 0.02)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : SettingsChrome.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Sidebar icon badge

/// A white SF Symbol on a rounded gradient badge, the way System Settings marks its tabs.
struct SettingsTabIcon: View {
    let symbol: String
    let start: Color
    let end: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                // A symbol name that does not resolve renders as nothing — a blank badge with no hint.
                Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
                    ? symbol : "questionmark")
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

/// A search field styled to sit in the sidebar.
struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Materials

/// An `NSVisualEffectView` material behind SwiftUI content — the sidebar's, over the window's own.
/// `.behindWindow`, so it blurs the desktop rather than the window beneath it.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
    }
}

extension Color {
    /// Nil for pattern-backed and catalog colours the panel can hand back; callers keep what they had.
    var hexString: String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses `#RRGGBB` — how Cmd-Tab writes its badge gradients, kept so the values match exactly.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        // `isHexDigit` as well as the parse: `Int(_:radix:)` also accepts a leading sign.
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let value = Int(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
