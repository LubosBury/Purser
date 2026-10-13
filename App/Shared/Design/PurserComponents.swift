import SwiftUI

/// Status pill (docs/design/components/Badge.md): always a word; danger, warning and success add an icon of a different shape.
struct PurserBadge: View {
    enum Kind { case neutral, info, success, warning, danger }

    let text: String
    var kind: Kind = .neutral

    var body: some View {
        HStack(spacing: PurserSpacing.space1) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(PurserFont.subheadline)
        .foregroundStyle(foreground)
        .padding(.horizontal, PurserSpacing.space2)
        .padding(.vertical, PurserSpacing.space1 / 2)
        .background(background, in: Capsule())
        .fixedSize()
    }

    private var symbol: String? {
        switch kind {
        case .neutral, .info: return nil
        case .success: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .danger: return "xmark.octagon"
        }
    }

    private var foreground: Color {
        switch kind {
        case .neutral: return PurserColor.textSecondary
        case .info: return PurserColor.info
        case .success: return PurserColor.success
        case .warning: return PurserColor.warning
        case .danger: return PurserColor.danger
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: return PurserColor.glassFill
        case .info: return PurserColor.infoTint
        case .success: return PurserColor.successTint
        case .warning: return PurserColor.warningTint
        case .danger: return PurserColor.dangerTint
        }
    }
}

/// Glass surface (docs/design/components/GlassPanel.md): `.glassEffect` on macOS 26, material before, opaque with Reduce Transparency.
struct PurserGlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let padded = content.padding(padding)
        if reduceTransparency {
            padded.background(PurserColor.surface2, in: shape).overlay(shape.strokeBorder(PurserColor.glassBorder))
        } else if #available(macOS 26.0, *) {
            padded.glassEffect(.regular, in: shape)
        } else {
            padded.background(.ultraThinMaterial, in: shape).overlay(shape.strokeBorder(PurserColor.glassBorder))
        }
    }
}

/// The ground glass sits on (`pu-stage`): canvas with two faint light pools, so the blur has something to bend.
struct PurserStage: View {
    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height)
            ZStack {
                PurserColor.canvas
                RadialGradient(colors: [PurserColor.accentTint, .clear], center: UnitPoint(x: 0.12, y: 0), startRadius: 0, endRadius: reach * 0.6)
                RadialGradient(colors: [PurserColor.glassFill, .clear], center: .bottomTrailing, startRadius: 0, endRadius: reach * 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// Groups the glass panels of one screen so they blend as one layer on macOS 26.
struct PurserGlassContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    func purserGlassPanel(radius: CGFloat = PurserRadius.radiusLg, padding: CGFloat = PurserSpacing.space4) -> some View {
        modifier(PurserGlassPanel(radius: radius, padding: padding))
    }

    /// Glass button; `primary` is the single main action of a screen or sheet (docs/design/components/Button.md).
    @ViewBuilder
    func purserButton(primary: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                buttonStyle(.glassProminent).tint(PurserColor.accentFill)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if primary {
                buttonStyle(.borderedProminent).tint(PurserColor.accentFill)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// Low-emphasis text action in toolbars and rows.
    func purserPlainButton() -> some View {
        buttonStyle(.plain).foregroundStyle(PurserColor.accentText)
    }

    /// Dense read-only table on the opaque table ground (docs/design/components/DataTable.md).
    func purserTable() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .purserTableGround()
    }

    /// The opaque ground of a table, also for the placeholder shown while a table's rows load.
    func purserTableGround() -> some View {
        background(PurserColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: PurserRadius.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PurserRadius.radiusMd, style: .continuous).strokeBorder(PurserColor.glassBorder))
    }
}

/// Screen title row: the title on the left, the screen's controls on the right.
struct PurserScreenHeader<Accessory: View>: View {
    let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: PurserSpacing.space3) {
            Text(title)
                .font(PurserFont.titleLarge)
                .foregroundStyle(PurserColor.textPrimary)
                .lineLimit(1)
            accessory
        }
    }
}

/// A labelled figure in a summary panel.
struct PurserStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            Text(label).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
            Text(value).font(PurserFont.title2.monospacedDigit()).foregroundStyle(PurserColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Right-aligned monospaced figure for table cells.
struct PurserFigure: View {
    let text: String
    var color: Color = PurserColor.textPrimary

    init(_ text: String, color: Color = PurserColor.textPrimary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(PurserFont.figure)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Full-window screens before a workspace is open (owner name, lock, workspace picker): one glass card on the stage.
struct PurserGateLayout<Content: View>: View {
    private let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat = 440, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: maxWidth)
            .purserGlassPanel(radius: PurserRadius.radiusXl, padding: PurserSpacing.space8)
            .padding(PurserSpacing.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PurserStage())
    }
}

/// One titled group of settings on a glass panel.
struct PurserSettingsPanel<Content: View>: View {
    private let title: String
    private let hint: String?
    private let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space3) {
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                Text(title).font(PurserFont.title2).foregroundStyle(PurserColor.textPrimary)
                if let hint {
                    Text(hint)
                        .font(PurserFont.callout)
                        .foregroundStyle(PurserColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .purserGlassPanel()
    }
}

/// A read-only value with its label; identifiers are set in the monospaced `identifier` style.
struct PurserKeyValue: View {
    let label: String
    let value: String
    var isIdentifier = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space3) {
            Text(label)
                .font(PurserFont.callout)
                .foregroundStyle(PurserColor.textSecondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(isIdentifier ? PurserFont.identifier : PurserFont.body)
                .foregroundStyle(PurserColor.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
