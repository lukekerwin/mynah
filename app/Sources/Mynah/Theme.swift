import AppKit
import SwiftUI

/// Mynah's visual language. Colours come from the app icon: the bird's ink body,
/// the teal squircle behind it and the amber beak. Everything adapts to the
/// system appearance, but keeps the same accents in both.
enum Theme {
    // MARK: colours

    /// Window background.
    static let canvas = dynamic(light: 0xF3F5F7, dark: 0x11151B)
    /// Sidebar surface, slightly separated from the canvas.
    static let sidebar = dynamic(light: 0xEBEEF1, dark: 0x0C0F14)
    /// Cards and grouped controls.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1A2029)
    /// A recessed field inside a card (text editors, lists).
    static let well = dynamic(light: 0xF3F5F7, dark: 0x11151B)
    static let border = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    static let borderStrong = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)

    static let ink = dynamic(light: 0x11151B, dark: 0xF4F6F8)
    static let inkSecondary = dynamic(light: 0x5B6472, dark: 0xA3ACB8)
    static let inkTertiary = dynamic(light: 0x8C94A0, dark: 0x6B7482)

    /// The interactive accent — the teal of the icon, darkened for light backgrounds.
    static let teal = dynamic(light: 0x0F9B8E, dark: 0x2FD3BE)
    static let tealDeep = Color(hex: 0x0B6E66)
    static let tealSoft = dynamic(light: 0x0F9B8E, dark: 0x2FD3BE, lightAlpha: 0.12, darkAlpha: 0.16)
    /// The beak: reserved for "live" — recording, and command mode.
    static let amber = Color(hex: 0xF7A51A)
    static let amberSoft = dynamic(light: 0xF7A51A, dark: 0xF7A51A, lightAlpha: 0.14, darkAlpha: 0.18)
    static let coral = Color(hex: 0xF0564A)
    static let coralSoft = dynamic(light: 0xF0564A, dark: 0xF0564A, lightAlpha: 0.12, darkAlpha: 0.18)
    static let mint = dynamic(light: 0x1E9E5A, dark: 0x4CD28A)

    /// Overlay pill colours are fixed: it floats over every app, so it is always dark.
    static let pill = Color(hex: 0x14181F)
    static let pillText = Color(hex: 0xF4F6F8)

    static let tealGradient = LinearGradient(colors: [Color(hex: 0x2FD3BE), Color(hex: 0x0B6E66)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let amberGradient = LinearGradient(colors: [Color(hex: 0xFFC24D), Color(hex: 0xF7681A)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: type

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let title = display(26, weight: .bold)
    static let heading = display(15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let stat = display(30, weight: .bold)

    // MARK: metrics

    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9
    static let sidebarWidth: CGFloat = 200

    // MARK: helpers

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Components

/// A grouped surface. Children are stacked with hairline separators when `divided`.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title { Text(title).font(Theme.heading).foregroundStyle(Theme.ink) }
                    if let subtitle {
                        Text(subtitle).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, padding)
                .padding(.top, padding)
                .padding(.bottom, 12)
            }
            content()
                .padding(.horizontal, padding)
                .padding(.bottom, padding)
                .padding(.top, title == nil && subtitle == nil ? padding : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// One labelled row inside a card: title + optional detail on the left, a control on the right.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// A keyboard key, drawn like a physical key cap. The signature Mynah element.
struct KeyCap: View {
    var label: String
    var symbol: String?
    var size: CGFloat = 15
    var tint: Color = Theme.ink

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: size * 0.8, weight: .medium)) }
            Text(label).font(.system(size: size, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, size * 0.75)
        .padding(.vertical, size * 0.45)
        .background(
            RoundedRectangle(cornerRadius: size * 0.5, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.5, style: .continuous).strokeBorder(Theme.borderStrong))
    }
}

/// Coloured dot + label, used for engine and permission state.
struct StatusBadge: View {
    enum Kind { case ok, busy, warn, off }
    var kind: Kind
    var text: String

    private var colour: Color {
        switch kind {
        case .ok: return Theme.mint
        case .busy: return Theme.amber
        case .warn: return Theme.coral
        case .off: return Theme.inkTertiary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
                .overlay(Circle().stroke(colour.opacity(0.35), lineWidth: 3).opacity(kind == .busy ? 1 : 0))
            Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.tealGradient) : AnyShapeStyle(Theme.well))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(prominent ? Color.white.opacity(0.18) : Theme.borderStrong))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
    static var quiet: AccentButtonStyle { AccentButtonStyle(prominent: false) }
}

/// A switch that takes the teal accent in both appearances.
struct TealToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(Theme.tealGradient) : AnyShapeStyle(Theme.borderStrong))
                        .frame(width: 36, height: 21)
                    Circle().fill(.white).frame(width: 17, height: 17)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Large, friendly page header with a one-line description.
struct PageHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.title).foregroundStyle(Theme.ink)
            if let subtitle { Text(subtitle).font(Theme.body).foregroundStyle(Theme.inkSecondary) }
        }
        .padding(.bottom, 6)
    }
}

/// Native Picker restyled to sit on a card.
struct PickerField<Selection: Hashable, Content: View>: View {
    @Binding var selection: Selection
    @ViewBuilder var content: () -> Content

    var body: some View {
        Picker("", selection: $selection, content: content)
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: 240)
    }
}

/// The audio-level bars used in the overlay and on the Home page.
struct Waveform: View {
    var levels: [Float]
    var tint: Color
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 4
    var maxHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: minHeight + CGFloat(level) * (maxHeight - minHeight))
            }
        }
        .animation(.easeOut(duration: 0.055), value: levels)
    }
}
