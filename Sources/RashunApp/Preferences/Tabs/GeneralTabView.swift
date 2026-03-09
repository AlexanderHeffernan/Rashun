import SwiftUI
import RashunCore

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
                sectionDivider
                menuBarSection
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

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Menu Bar Appearance")

            HStack(alignment: .center, spacing: 10) {
                Text("Color mode")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)

                Picker(
                    "",
                    selection: Binding(
                        get: { model.menuBarColorMode },
                        set: { model.menuBarColorMode = $0 }
                    )
                ) {
                    Text("Monochrome").tag(MenuBarColorMode.monochrome)
                    Text("Color").tag(MenuBarColorMode.sourceSolid)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340)
            }

            HStack(alignment: .center, spacing: 10) {
                Text("Center content")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)

                Picker(
                    "",
                    selection: Binding(
                        get: { model.menuBarCenterContentMode },
                        set: { model.menuBarCenterContentMode = $0 }
                    )
                ) {
                    Text("Logo").tag(MenuBarCenterContentMode.logo)
                    Text("Remaining Percentage").tag(MenuBarCenterContentMode.percentage)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340)
            }

            Text("Select metrics to render as horizontal ring icons in the menu bar.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandPalette.textSecondary.opacity(0.9))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.menuBarMetricOptions()) { option in
                    Toggle(
                        "\(option.sourceTitle) · \(option.metricTitle)",
                        isOn: Binding(
                            get: {
                                model.isMenuBarMetricSelected(sourceName: option.sourceName, metricId: option.metricId)
                            },
                            set: {
                                model.setMenuBarMetricSelected(
                                    sourceName: option.sourceName,
                                    metricId: option.metricId,
                                    selected: $0
                                )
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)
                }
            }

            Text("Selected: \(model.menuBarSelectionCount)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(BrandPalette.textSecondary)
        }
    }
}
