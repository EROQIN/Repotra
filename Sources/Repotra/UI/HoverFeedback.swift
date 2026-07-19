import SwiftUI

enum RepotraHoverFill: Equatable {
    case clear
    case primary(Double)
    case accent(Double)
}

enum RepotraHoverFeedbackResolver {
    static func fill(
        isEnabled: Bool,
        isSelected: Bool,
        isPressed: Bool,
        isHovering: Bool
    ) -> RepotraHoverFill {
        guard isEnabled else { return .clear }
        if isSelected { return .accent(isPressed ? 0.20 : 0.14) }
        if isPressed { return .primary(0.09) }
        if isHovering { return .primary(0.05) }
        return .clear
    }
}

struct RepotraHoverButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        RepotraHoverButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            cornerRadius: cornerRadius
        )
    }
}

private struct RepotraHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering in
                let update = { isHovering = isEnabled && hovering }
                if reduceMotion { update() }
                else { withAnimation(.easeOut(duration: 0.1), update) }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovering = false }
            }
    }

    private var backgroundColor: Color {
        color(for: RepotraHoverFeedbackResolver.fill(
            isEnabled: isEnabled,
            isSelected: isSelected,
            isPressed: configuration.isPressed,
            isHovering: isHovering
        ))
    }

    private func color(for fill: RepotraHoverFill) -> Color {
        switch fill {
        case .clear: .clear
        case let .primary(opacity): Color.primary.opacity(opacity)
        case let .accent(opacity): Color.accentColor.opacity(opacity)
        }
    }
}

private struct RepotraHoverSurfaceModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering in
                let update = { isHovering = isEnabled && hovering }
                if reduceMotion { update() }
                else { withAnimation(.easeOut(duration: 0.1), update) }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovering = false }
            }
    }

    private var backgroundColor: Color {
        switch RepotraHoverFeedbackResolver.fill(
            isEnabled: isEnabled,
            isSelected: isSelected,
            isPressed: false,
            isHovering: isHovering
        ) {
        case .clear: .clear
        case let .primary(opacity): Color.primary.opacity(opacity)
        case let .accent(opacity): Color.accentColor.opacity(opacity)
        }
    }
}

extension View {
    func repotraHoverFeedback(
        isSelected: Bool = false,
        cornerRadius: CGFloat = 6
    ) -> some View {
        modifier(RepotraHoverSurfaceModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
