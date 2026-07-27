import AppKit
import RashunCore
import SwiftUI

@MainActor
private final class TrackingPreferencesModel: ObservableObject {
    @Published var labels: [TrackingLabel] = []
    @Published var newName = ""
    @Published var trackingEnabled = SettingsStore.shared.trackingEnabled
    @Published var isSessionActive = false
    @Published var activeLabelID: UUID?
    @Published var persistenceError: String?
    private let store = TrackedUsageStore.shared
    init() { reload() }
    func reload() {
        do {
            labels = try store.readLabels()
            activeLabelID = try store.readActiveSession()?.labelID
            isSessionActive = activeLabelID != nil
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
    func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try store.createLabel(name: name)
            newName = ""
            reload()
        } catch {
            persistenceError = error.localizedDescription
        }
    }
    func archive(_ label: TrackingLabel) {
        do {
            try store.archiveLabel(id: label.id, archived: label.archivedAt == nil)
            reload()
        } catch {
            persistenceError = error.localizedDescription
        }
    }
    func save(_ label: TrackingLabel) {
        do {
            try store.updateLabel(label)
            reload()
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}

struct TrackingTabView: View {
    @StateObject private var model = TrackingPreferencesModel()
    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandCard(title: "Tracking") {
                        BrandToggle(
                            title: "Enable usage tracking",
                            subtitle:
                                "Show tracking controls in the menu bar and record labelled sessions.",
                            isOn: Binding(
                                get: { model.trackingEnabled },
                                set: {
                                    model.trackingEnabled = $0
                                    SettingsStore.shared.setTrackingEnabled($0)
                                })
                        )
                        Rectangle().fill(BrandPalette.primary.opacity(0.22)).frame(height: 1)
                            .padding(.vertical, 4)
                        Text("Labels").font(.system(size: 14, weight: .semibold)).foregroundColor(
                            BrandPalette.textPrimary)
                        HStack(spacing: 10) {
                            TrackingTextField(placeholder: "New label", text: $model.newName)
                            Button("Create") { model.add() }
                                .buttonStyle(PrimaryActionButtonStyle())
                                .disabled(
                                    model.newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty)
                        }
                        if model.labels.isEmpty {
                            Text("Create a label to start grouping observed usage.")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(
                                    BrandPalette.textSecondary)
                        } else {
                            ForEach(model.labels) { label in LabelRow(label: label, model: model) }
                        }
                    }
                }.padding(.bottom, 20)
            }
            .disabled(model.isSessionActive)
            if model.isSessionActive {
                VStack(spacing: 12) {
                    Image(systemName: "record.circle").font(.system(size: 34, weight: .semibold))
                        .foregroundColor(BrandPalette.primary)
                    Text("Tracking is active").font(
                        .system(size: 20, weight: .bold, design: .rounded)
                    ).foregroundColor(BrandPalette.textPrimary)
                    Text(
                        "Stop the current session from the Rashun menu before changing tracking settings or labels."
                    ).font(.system(size: 14, weight: .medium)).foregroundColor(
                        BrandPalette.textSecondary
                    ).multilineTextAlignment(.center).frame(maxWidth: 390)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    BrandPalette.background.opacity(0.9))
            }
            if let persistenceError = model.persistenceError {
                Text(persistenceError)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                    .padding()
                    .background(BrandPalette.card)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiDataRefreshed)) { _ in
            model.reload()
        }
    }
}

private struct LabelRow: View {
    @State private var name: String
    @State private var color: String
    let label: TrackingLabel
    @ObservedObject var model: TrackingPreferencesModel
    init(label: TrackingLabel, model: TrackingPreferencesModel) {
        self.label = label
        self.model = model
        _name = State(initialValue: label.name)
        _color = State(initialValue: label.colorHex)
    }
    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool {
        normalizedName != label.name || color.uppercased() != label.colorHex.uppercased()
    }
    private var canSave: Bool { !normalizedName.isEmpty && hasChanges }
    var body: some View {
        let isActive = model.activeLabelID == label.id
        HStack {
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: color) ?? .purple }, set: { color = $0.hexString ?? color }),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 32, height: 32)
            .fixedSize()
            .clipShape(Circle())
            .overlay(Circle().stroke(BrandPalette.primary.opacity(0.55), lineWidth: 1))
            TrackingTextField(placeholder: "Label", text: $name, width: 190)
            Button("Save") { save() }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.42)
            Button(label.archivedAt == nil ? "Archive" : "Unarchive") { model.archive(label) }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isActive)
                .opacity(isActive ? 0.42 : 1)
            if isActive {
                Text("Stop session before archiving").font(.system(size: 12, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary)
            }
        }.padding(.vertical, 5)
    }
    private func save() {
        guard canSave else { return }
        var updated = label
        updated.name = normalizedName
        updated.colorHex = color
        name = normalizedName
        model.save(updated)
    }
}

private struct TrackingTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(BrandPalette.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
                    BrandPalette.background.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(
                    BrandPalette.primary.opacity(0.4), lineWidth: 1))
    }
}

extension Color {
    fileprivate init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255,
            blue: Double(number & 255) / 255)
    }
}

extension Color {
    fileprivate var hexString: String? {
        #if os(macOS)
            guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
            return String(
                format: "#%02X%02X%02X", Int(round(color.redComponent * 255)),
                Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
        #else
            return nil
        #endif
    }
}
