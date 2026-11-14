import SwiftUI
import StrandDesign

/// A titled group of cards that stays folded until its header is tapped, and remembers whether it was
/// left open. It keeps the first screenful of a tab to what is read every day; nothing is removed, the
/// rest is one tap away.
struct FoldSection<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey?
    let accent: Color
    private let content: () -> Content
    @AppStorage private var open: Bool

    /// `storageKey` names the group; its open state is kept under that name.
    init(symbol: String, title: LocalizedStringKey, caption: LocalizedStringKey? = nil, accent: Color,
         storageKey: String, startsOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.symbol = symbol
        self.title = title
        self.caption = caption
        self.accent = accent
        self.content = content
        _open = AppStorage(wrappedValue: startsOpen, "fold." + storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            Button {
                StrandHaptic.selection.play()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { open.toggle() }
            } label: {
                header
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))

            if open {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    content()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 14))
                        .foregroundStyle(SummaryStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SummaryStyle.tertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}
