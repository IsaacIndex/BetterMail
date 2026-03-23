import SwiftUI

internal enum ToastStyle {
    case success
    case error
    case info
}

internal struct ToastMessage: Identifiable {
    internal let id = UUID()
    internal let text: String
    internal let style: ToastStyle
    internal let duration: TimeInterval

    internal init(text: String, style: ToastStyle = .info, duration: TimeInterval = 3.0) {
        self.text = text
        self.style = style
        self.duration = duration
    }
}

internal struct ToastOverlay: View {
    @Binding internal var activeToast: ToastMessage?

    internal var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let toast = activeToast {
                toastPill(toast)
                    .transition(
                        .move(edge: .bottom)
                        .combined(with: .opacity)
                    )
                    .padding(.bottom, 24)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: activeToast?.id)
        .allowsHitTesting(false)
    }

    private func toastPill(_ toast: ToastMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: toast.style))
                .foregroundStyle(iconColor(for: toast.style))
                .font(.system(size: 14, weight: .semibold))
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func iconName(for style: ToastStyle) -> String {
        switch style {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    private func iconColor(for style: ToastStyle) -> Color {
        switch style {
        case .success:
            return .green
        case .error:
            return .red
        case .info:
            return .blue
        }
    }
}
