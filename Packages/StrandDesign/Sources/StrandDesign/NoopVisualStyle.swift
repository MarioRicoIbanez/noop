import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // Dark appearance follows the iOS system palette on a pure black canvas: black canvas, #111112 cards,
    // #1E1E20 inset wells, #38383A separators. Light values are unchanged from the previous design.
    public static let canvas = Color(light: "#F3F4F6", dark: "#000000")
    public static let surface = Color(light: "#FFFFFF", dark: "#111112")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#111112")
    public static let surfaceBottom = Color(light: "#F4F5F7", dark: "#111112")
    public static let inset = Color(light: "#E8E9ED", dark: "#1E1E20")

    public static let border = Color(light: "#D8DAE0", dark: "#38383A")
    /// Only used for transient emphasis (hover / press / selected segment); resting cards draw no border.
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#48484A")
    public static let divider = Color(light: "#E4E5E9", dark: "#38383A")

    public static let primaryText = Color(light: "#17181C", dark: "#F5F3EE")
    public static let secondaryText = Color(light: "#555861", dark: "#8E8E93")
    public static let tertiaryText = Color(light: "#7D808A", dark: "#636366")

    /// Fill of the selected segment in a segmented control (#5A5A5F on dark).
    public static let selectedSegment = Color(light: "#E3E4E8", dark: "#5A5A5F")

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    // The single accent and its tonal steps. Dark values are the approved design hexes; the light values
    // are the same hues darkened so the greens keep contrast on a white card.
    /// Muted emerald: the one accent (selected state, links, gauges at full value).
    public static let green = Color(light: "#1E9E45", dark: "#54C794")
    /// Deep green: sleep "deep", the low end of intensity ramps.
    public static let greenDeep = Color(light: "#14663A", dark: "#1E6F52")
    /// Mid green: sleep "light", mid intensity.
    public static let greenMid = Color(light: "#2A9A55", dark: "#3FA57A")
    /// Pale green: sleep "REM", the top of intensity ramps.
    public static let greenSoft = Color(light: "#5CCB8A", dark: "#BFE6D3")
    /// Neutral grey for "awake" and other non-data marks (system grey).
    public static let neutralMark = Color(light: "#8E8E93", dark: "#8E8E93")
    /// The only colours that are allowed to differ from the green family: real warnings.
    public static let warning = Color(light: "#C77700", dark: "#D9906A")
    public static let critical = Color(light: "#D70015", dark: "#FF453A")

    /// Decorative glow, bloom and halo layers are off. The shared glow helpers (`additiveBloom`, gauge
    /// tip halos, pulse-dot shadows) read this single switch, so flipping it back restores them.
    public static let glowsEnabled = false

    public static let cardRadius: CGFloat = 16
    public static let compactRadius: CGFloat = 14
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// Shared card/panel treatment: a flat solid surface with continuous corners. No border, no shadow, no
/// gradient and no tint wash on any platform. `tint` and `elevated` stay in the API so call sites keep
/// compiling, but they no longer paint anything: metric identity lives in the card's content, not its fill.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(NoopVisualStyle.surface)
            .opacity(surfaceOpacity)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers: a flat surface with the divider token
/// along its bottom edge (no gradient).
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        NoopVisualStyle.surface
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(NoopVisualStyle.divider)
                    .frame(height: 0.5)
            }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
