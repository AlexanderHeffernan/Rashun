import SwiftUI
import RashunCore

struct UpdatesTabView: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        TabScrollContainer {
            versionCard
            updateChecksCard
        }
    }

    private var versionCard: some View {
        BrandCard(title: "Version") {
            HStack(spacing: 8) {
                Text(model.currentVersionText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var updateChecksCard: some View {
        BrandCard(title: "Update Checks") {
            VStack(alignment: .leading, spacing: 14) {
                BrandToggle(
                    title: "Check for updates automatically",
                    subtitle: "Periodically check GitHub releases.",
                    isOn: Binding(
                        get: { model.autoUpdateCheckEnabled },
                        set: { model.autoUpdateCheckEnabled = $0 }
                    )
                )

                HStack(spacing: 10) {
                    Button("Check Now") {
                        Task { await model.checkForUpdates() }
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!model.checkNowEnabled)

                    if !model.updateStatusText.isEmpty {
                        Text(model.updateStatusText)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(model.updateStatusColor)
                    }
                }

                if model.updateAvailable {
                    Button("Install & Restart") {
                        model.showInstallConfirmation = true
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(!model.installEnabled)
                }
            }
        }
    }
}
