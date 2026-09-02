import SwiftUI

enum DuckTheme {
    static let warmYellow = Color(red: 1.0, green: 0.79, blue: 0.16)
    static let duckOrange = Color(red: 1.0, green: 0.60, blue: 0.0)
    static let skyBlue = Color(red: 0.21, green: 0.73, blue: 0.94)
    static let softBlue = Color(red: 0.92, green: 0.98, blue: 1.0)
    static let inkBlue = Color(red: 0.11, green: 0.16, blue: 0.25)
    static let softWhite = Color(red: 1.0, green: 0.99, blue: 0.97)
    static let mutedText = Color(red: 0.45, green: 0.52, blue: 0.65)

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

struct HeaderBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("MascotChat")
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text("选选鸭")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.duckOrange)
                Text("纠结终结者 · 鸭鸭帮你选")
                    .font(.caption)
                    .foregroundStyle(DuckTheme.skyBlue)
            }
            Spacer()
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(DuckTheme.skyBlue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DuckTheme.warmYellow.opacity(0.35))
                .frame(height: 1)
        }
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

