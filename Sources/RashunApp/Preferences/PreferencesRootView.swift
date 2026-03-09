import SwiftUI
import RashunCore

enum PreferencesTab: String, CaseIterable, Hashable {
    case general = "General"
    case sources = "Sources"
    case data = "Data"
    case updates = "Updates"
}

struct PreferencesRootView: View {
    @ObservedObject var model: PreferencesViewModel

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 20) {
                header
                tabBar
                tabContent
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 1040, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 620)
        .alert(
            "Enable \(model.pendingEnableSource?.name ?? "")?",
            isPresented: Binding(
                get: { model.pendingEnableSource != nil },
                set: { if !$0 { model.cancelEnableSource() } }
            )
        ) {
            Button("Enable") { model.confirmEnableSource() }
            Button("Cancel", role: .cancel) { model.cancelEnableSource() }
        } message: {
            Text(model.pendingEnableMessage)
        }
        .alert("Install Update?", isPresented: $model.showInstallConfirmation) {
            Button("Install & Restart") { model.installUpdate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rashun will download version \(model.availableVersionText), install it, and restart.")
        }
        .alert(
            "Launch at Login Unavailable",
            isPresented: Binding(
                get: { model.launchAtLoginErrorMessage != nil },
                set: { if !$0 { model.launchAtLoginErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.launchAtLoginErrorMessage = nil }
        } message: {
            Text(model.launchAtLoginErrorMessage ?? "")
        }
        .alert(
            "Source Health Check Failed",
            isPresented: Binding(
                get: { model.sourceHealthCheckErrorMessage != nil },
                set: { if !$0 { model.sourceHealthCheckErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.sourceHealthCheckErrorMessage = nil }
        } message: {
            Text(model.sourceHealthCheckErrorMessage ?? "")
        }
    }

    private var background: some View {
        BrandPalette.background.ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            logoBadge

            VStack(alignment: .leading, spacing: 4) {
                Text("Rashun Preferences")
                    .font(.system(size: 44 / 2, weight: .bold, design: .rounded))
                    .foregroundColor(BrandPalette.textPrimary)

                Text("Configure sources, notifications, data, and update behavior")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)
            }

            Spacer()
        }
    }

    private var logoBadge: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 58)
            .scaleEffect(1.24)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(BrandPalette.primary.opacity(0.38), lineWidth: 1)
            )
        .shadow(color: BrandPalette.primary.opacity(0.24), radius: 10, x: 0, y: 5)
    }

    private var tabBar: some View {
        HStack {
            BrandSegmentedControl(
                options: PreferencesTab.allCases,
                selection: $model.selectedTab,
                label: { $0.rawValue }
            )
            Spacer()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.selectedTab {
        case .general:
            GeneralTabView(model: model)
        case .sources:
            SourcesTabView(model: model)
        case .data:
            DataTabView(model: model)
        case .updates:
            UpdatesTabView(model: model)
        }
    }
}
