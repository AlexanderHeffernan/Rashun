import SwiftUI
import RashunCore

struct DataTabView: View {
    @ObservedObject var model: PreferencesViewModel
    @StateObject private var dataModel = DataTabViewModel()

    var body: some View {
        TabScrollContainer {
            summaryCard
            transferCard
            deleteCard
        }
        .onAppear {
            syncSources()
        }
        .onChange(of: model.sources.map { "\($0.name)|\($0.metrics.map(\.id).joined(separator: ","))|\($0.metrics.map(\.title).joined(separator: ","))" }) { _, _ in
            syncSources()
        }
        .alert("Delete Usage History?", isPresented: $dataModel.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                dataModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dataModel.pendingDeleteMessage)
        }
        .alert("Replace Current Usage History?", isPresented: $dataModel.showImportConfirmation) {
            Button("Replace", role: .destructive) {
                dataModel.confirmImport()
            }
            Button("Cancel", role: .cancel) {
                dataModel.cancelImport()
            }
        } message: {
            Text(dataModel.pendingImportMessage)
        }
    }

    private var summaryCard: some View {
        BrandCard(title: "Stored Usage Data") {
            VStack(alignment: .leading, spacing: 8) {
                Text(dataModel.statsSubtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)

                Text(dataModel.statsDateRangeText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)
            }
        }
    }

    private var transferCard: some View {
        BrandCard(title: "Import & Export") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export usage history to JSON, or import a JSON export from another Rashun setup.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)

                HStack(spacing: 10) {
                    Button("Export JSON") { dataModel.exportHistory() }
                        .buttonStyle(PrimaryActionButtonStyle())

                    Button("Import JSON") { dataModel.importHistory() }
                        .buttonStyle(SecondaryActionButtonStyle())
                }

                if !dataModel.transferStatusText.isEmpty {
                    Text(dataModel.transferStatusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(dataModel.transferStatusIsError ? BrandPalette.warning : BrandPalette.accent)
                }
            }
        }
    }

    private var deleteCard: some View {
        BrandCard(title: "Delete History") {
            VStack(alignment: .leading, spacing: 14) {
                BrandSegmentedControl(
                    options: DataTabViewModel.DeleteScope.allCases,
                    selection: $dataModel.deleteScope,
                    label: { $0.rawValue }
                )

                if dataModel.deleteScope == .singleSource {
                    Picker("Source", selection: $dataModel.selectedSourceName) {
                        ForEach(dataModel.availableSourceNames, id: \.self) { sourceName in
                            Text(sourceName).tag(sourceName)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(BrandPalette.textPrimary)
                }

                BrandSegmentedControl(
                    options: DataTabViewModel.DeleteMode.allCases,
                    selection: $dataModel.deleteMode,
                    label: { $0.rawValue }
                )

                switch dataModel.deleteMode {
                case .olderThanDate:
                    DatePicker(
                        "Delete snapshots older than",
                        selection: $dataModel.olderThanDate,
                        displayedComponents: .date
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(BrandPalette.textPrimary)
                case .keepLastDays:
                    HStack(spacing: 10) {
                        Text("Keep only the last")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(BrandPalette.textPrimary)

                        BrandNumericField(text: $dataModel.keepLastDaysText, width: 90) {}

                        Text("day(s)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(BrandPalette.textPrimary)
                    }
                case .deleteAll:
                    Text("Delete all stored usage snapshots for the selected scope.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(BrandPalette.textSecondary)
                }

                Text(dataModel.deletePreviewText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(dataModel.canDelete ? BrandPalette.warning : BrandPalette.textSecondary)

                Button("Delete History") {
                    dataModel.beginDeleteFlow()
                }
                .buttonStyle(DangerActionButtonStyle())
                .disabled(!dataModel.canDelete)

                if !dataModel.deleteStatusText.isEmpty {
                    Text(dataModel.deleteStatusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(dataModel.deleteStatusIsError ? BrandPalette.warning : BrandPalette.accent)
                }
            }
        }
    }

    private func syncSources() {
        dataModel.configure(sources: model.sources)
    }
}
