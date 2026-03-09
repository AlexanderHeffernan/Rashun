import SwiftUI
import RashunCore

struct BrandCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(BrandPalette.textPrimary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BrandPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(BrandPalette.primary.opacity(0.42), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
        )
    }
}
