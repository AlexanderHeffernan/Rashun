import SwiftUI
import RashunCore

struct SourcesTabView: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        TabScrollContainer {
            BrandCard(title: "Sources") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enable providers and configure notification rules for each source.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(BrandPalette.textSecondary)
                        .frame(maxWidth: 620, alignment: .leading)

                    ForEach(model.sources, id: \.name) { source in
                        SourceRowView(model: model, source: source)
                    }
                }
            }
        }
    }
}
