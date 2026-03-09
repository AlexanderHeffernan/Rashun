import SwiftUI
import RashunCore

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BrandPalette.gradient)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(BrandPalette.textPrimary)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BrandPalette.cardAlt.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(BrandPalette.primary.opacity(0.35), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DangerActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.72 : 0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BrandNumericField: View {
    @Binding var text: String
    let width: CGFloat
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, width: CGFloat = 80, onCommit: @escaping () -> Void) {
        _text = text
        self.width = width
        self.onCommit = onCommit
    }

    var body: some View {
        TextField("", text: $text, onCommit: onCommit)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    onCommit()
                }
            }
            .onDisappear {
                onCommit()
            }
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundColor(BrandPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandPalette.background.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandPalette.primary.opacity(0.4), lineWidth: 1)
            )
    }
}

struct BrandSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) {
        self.options = options
        _selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(selection == option ? BrandPalette.textPrimary : BrandPalette.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minWidth: 94)
                        .background(tabBackground(isSelected: selection == option))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BrandPalette.cardAlt.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandPalette.primary.opacity(0.2), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func tabBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandPalette.primary.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BrandPalette.accent.opacity(0.5), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
        }
    }
}
