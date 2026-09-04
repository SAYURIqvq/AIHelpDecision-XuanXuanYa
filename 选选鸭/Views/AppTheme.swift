import SwiftUI
import UIKit

enum DuckTheme {
    static let warmYellow = Color(red: 1.0, green: 0.79, blue: 0.16)
    static let duckOrange = Color(red: 1.0, green: 0.60, blue: 0.0)
    static let skyBlue = Color(red: 0.21, green: 0.73, blue: 0.94)
    static let softBlue = Color(red: 0.92, green: 0.98, blue: 1.0)
    static let inkBlue = Color(red: 0.11, green: 0.16, blue: 0.25)
    static let softWhite = Color(red: 1.0, green: 0.99, blue: 0.97)
    static let mutedText = Color(red: 0.45, green: 0.52, blue: 0.65)
    static let successGreen = Color(red: 0.18, green: 0.72, blue: 0.42)

    /// 标签轮换色：背景浅色 + 文字深色，便于区分
    static let tagPalette: [(background: Color, foreground: Color)] = [
        (Color(red: 1.00, green: 0.90, blue: 0.55), Color(red: 0.55, green: 0.35, blue: 0.02)),
        (Color(red: 0.78, green: 0.93, blue: 1.00), Color(red: 0.08, green: 0.38, blue: 0.62)),
        (Color(red: 0.82, green: 0.95, blue: 0.84), Color(red: 0.10, green: 0.42, blue: 0.24)),
        (Color(red: 1.00, green: 0.84, blue: 0.78), Color(red: 0.62, green: 0.22, blue: 0.12)),
        (Color(red: 0.90, green: 0.84, blue: 1.00), Color(red: 0.38, green: 0.20, blue: 0.62)),
        (Color(red: 1.00, green: 0.88, blue: 0.94), Color(red: 0.58, green: 0.18, blue: 0.42)),
        (Color(red: 0.86, green: 0.96, blue: 0.94), Color(red: 0.08, green: 0.42, blue: 0.40)),
        (Color(red: 1.00, green: 0.93, blue: 0.78), Color(red: 0.55, green: 0.32, blue: 0.05))
    ]

    static func tagColors(at index: Int) -> (background: Color, foreground: Color) {
        tagPalette[index % tagPalette.count]
    }

    /// Distinct vivid chrome for top brand bar (unlike pale page background)
    static let headerChromeGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.82, blue: 0.28),
            Color(red: 1.0, green: 0.70, blue: 0.32),
            Color(red: 0.45, green: 0.84, blue: 0.98),
            Color(red: 0.22, green: 0.72, blue: 0.94)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Distinct vivid chrome for bottom tab bar
    static let footerChromeGradient = LinearGradient(
        colors: [
            Color(red: 0.28, green: 0.76, blue: 0.96),
            Color(red: 0.55, green: 0.86, blue: 0.98),
            Color(red: 1.0, green: 0.86, blue: 0.42),
            Color(red: 1.0, green: 0.72, blue: 0.28)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Soft cream → sky mist for chat input row only
    static let inputBarChromeGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.99, blue: 0.97),
            Color(red: 0.93, green: 0.97, blue: 1.0),
            Color(red: 0.86, green: 0.94, blue: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let chromeEdge = LinearGradient(
        colors: [.white.opacity(0.55), warmYellow.opacity(0.65), skyBlue.opacity(0.55)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let inputBarEdge = LinearGradient(
        colors: [skyBlue.opacity(0.35), warmYellow.opacity(0.28), skyBlue.opacity(0.22)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let pageGradient = LinearGradient(
        colors: [softBlue, softWhite],
        startPoint: .top,
        endPoint: .bottom
    )

    static let heroGradient = LinearGradient(
        colors: [warmYellow, skyBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func applyChromeAppearance() {
        let border = UIColor(red: 1.0, green: 0.60, blue: 0.0, alpha: 0.35)
        let gradientImage = makeTabGradientImage()

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        if let gradientImage {
            tab.backgroundImage = gradientImage
            tab.shadowImage = UIImage()
        } else {
            tab.backgroundColor = UIColor(red: 0.45, green: 0.82, blue: 0.96, alpha: 1)
        }
        tab.shadowColor = border
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = UIColor(red: 1.0, green: 0.42, blue: 0.05, alpha: 1)
        UITabBar.appearance().unselectedItemTintColor = UIColor(red: 0.18, green: 0.28, blue: 0.38, alpha: 0.78)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1)
        nav.shadowColor = border
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    private static func makeTabGradientImage() -> UIImage? {
        let width = max(UIScreen.main.bounds.width, 390)
        let height: CGFloat = 96
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors = [
                UIColor(red: 0.28, green: 0.76, blue: 0.96, alpha: 1).cgColor,
                UIColor(red: 0.55, green: 0.86, blue: 0.98, alpha: 1).cgColor,
                UIColor(red: 1.0, green: 0.86, blue: 0.42, alpha: 1).cgColor,
                UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1).cgColor
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 0.7, 1]) else { return }
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }
}

struct DuckCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DuckTheme.softWhite)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DuckTheme.skyBlue.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: DuckTheme.skyBlue.opacity(0.15), radius: 10, y: 5)
    }
}

struct PrimaryDuckButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(DuckTheme.duckOrange)
        .clipShape(Capsule())
        .shadow(color: DuckTheme.duckOrange.opacity(0.28), radius: 12, y: 7)
    }
}

struct DuckTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(DuckTheme.inkBlue)
            .background(DuckTheme.warmYellow.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DuckTheme.duckOrange.opacity(0.55), lineWidth: 1.5)
            }
    }
}

/// 真正按可用宽度横排，放不下才换行（按内容 intrinsic 宽度）。
struct DuckFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = y + rowHeight
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct DuckTagChip: View {
    let text: String
    var index: Int = 0
    var onDelete: (() -> Void)? = nil

    private var colors: (background: Color, foreground: Color) {
        DuckTheme.tagColors(at: index)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(colors.foreground.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(colors.background)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 决策标签 / 测试结果标签共用：彩色 + 横排优先换行。
struct DuckTagCloud: View {
    let tags: [String]
    var onDelete: ((String) -> Void)? = nil

    var body: some View {
        DuckFlowLayout(spacing: 8) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                DuckTagChip(
                    text: tag,
                    index: index,
                    onDelete: onDelete.map { handler in { handler(tag) } }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HeaderBar<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            Image("MascotChat")
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 2.5))

            VStack(alignment: .leading, spacing: 4) {
                Text("选选鸭")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                Text("纠结终结者 · 鸭鸭帮你选")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(DuckTheme.headerChromeGradient)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DuckTheme.chromeEdge)
                .frame(height: 1.5)
        }
        .shadow(color: DuckTheme.skyBlue.opacity(0.12), radius: 8, y: 3)
    }
}

struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool = false, action: @escaping () -> Void = {}) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? .white : DuckTheme.duckOrange)
                .background(isSelected ? DuckTheme.duckOrange : DuckTheme.softWhite)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(DuckTheme.warmYellow.opacity(0.85), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
