import SwiftUI
import RashunCore

struct TabScrollContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.bottom, 14)
        }
    }
}
