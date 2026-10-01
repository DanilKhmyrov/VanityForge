import SwiftUI

/// Общий "объёмный" стеклянный стиль для панелей/карточек: лёгкая подсветка
/// сверху (имитация света на стекле), градиентная обводка и двойная тень
/// (тёмная контактная + мягкое цветное свечение) — вместо плоской заливки
/// с тонкой рамкой, как было раньше.
struct ElevatedGlass: ViewModifier {
    var accent: Color = .white
    var cornerRadius: CGFloat = 14
    var intensity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12 * intensity), .clear],
                                startPoint: .top,
                                endPoint: .init(x: 0.5, y: 0.6)
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                accent.opacity(0.35 * intensity),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 7)
            .shadow(color: accent.opacity(0.22 * intensity), radius: 22, x: 0, y: 10)
    }
}

extension View {
    func elevatedGlass(accent: Color = .white, cornerRadius: CGFloat = 14, intensity: Double = 1.0) -> some View {
        modifier(ElevatedGlass(accent: accent, cornerRadius: cornerRadius, intensity: intensity))
    }
}
