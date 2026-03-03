import SwiftUI

struct GeneralTabView: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        TabScrollContainer {
            appBehaviorCard
        }
    }

    private var appBehaviorCard: some View {
        BrandCard(title: "App Behavior") {
            VStack(alignment: .leading, spacing: 20) {
                startupSection
                sectionDivider
                refreshSection
            }
        }
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Startup")

            BrandToggle(
                title: "Launch Rashun at login",
                subtitle: "Start Rashun automatically when you sign in to your Mac.",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                )
            )
        }
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Refresh Frequency")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Check usage every")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)

                BrandNumericField(text: $model.pollMinutesText, width: 86) {
                    model.applyPollInterval()
                }

                Text("minute(s)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)
            }

            Text("Used for background refreshes in the menu bar.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary.opacity(0.9))
                .padding(.leading, 30)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(BrandPalette.textPrimary)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(BrandPalette.primary.opacity(0.22))
            .frame(height: 1)
    }
}
