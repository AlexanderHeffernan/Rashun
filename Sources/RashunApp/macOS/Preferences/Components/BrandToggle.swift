import SwiftUI
import RashunCore

struct BrandToggle: View {
    let title: String
    let subtitle: String
    let isOn: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(BrandPalette.textPrimary)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary)
                .padding(.leading, 30)
        }
    }
}
