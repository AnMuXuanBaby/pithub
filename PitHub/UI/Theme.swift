//
//  Theme.swift
//  PitHub
//
//  深色、磨砂玻璃、低饱和蓝的视觉风格。
//

import SwiftUI

enum PitHubPalette {
    static let accent = Color(red: 0.35, green: 0.55, blue: 0.92)
    static let accentSoft = Color(red: 0.45, green: 0.65, blue: 0.98).opacity(0.18)
    static let backgroundTop = Color(red: 0.045, green: 0.060, blue: 0.085)
    static let backgroundBottom = Color(red: 0.015, green: 0.020, blue: 0.030)
    static let textPrimary = Color(red: 0.91, green: 0.94, blue: 0.99)
    static let textSecondary = Color(red: 0.58, green: 0.64, blue: 0.74)
    static let success = Color(red: 0.35, green: 0.82, blue: 0.62)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.35)
    static let danger = Color(red: 0.95, green: 0.42, blue: 0.42)
}

struct PitHubBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PitHubPalette.backgroundTop, PitHubPalette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(PitHubPalette.accent.opacity(0.25))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: -140, y: -260)
            Circle()
                .fill(Color(red: 0.22, green: 0.35, blue: 0.62).opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 130)
                .offset(x: 160, y: 300)
        }
        .ignoresSafeArea()
    }
}

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(PitHubPalette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PitHubPalette.textSecondary)
            }
        }
    }
}

struct StatusDot: View {
    var active: Bool

    var body: some View {
        Circle()
            .fill(active ? PitHubPalette.success : PitHubPalette.textSecondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .shadow(color: active ? PitHubPalette.success.opacity(0.7) : .clear, radius: 6)
    }
}

struct PillLabel: View {
    let text: String
    var color: Color = PitHubPalette.accent

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct MonospaceURL: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(PitHubPalette.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
