import AppKit
import SwiftUI
import RashunCore

@MainActor
private final class TrackingPreferencesModel: ObservableObject {
    @Published var labels: [TrackingLabel] = []
    @Published var newName = ""
    @Published var trackingEnabled = SettingsStore.shared.trackingEnabled
    @Published var isSessionActive = TrackedUsageStore.shared.activeSession != nil
    private let store = TrackedUsageStore.shared
    init() { reload() }
    func reload() { labels = store.labels; isSessionActive = store.activeSession != nil }
    func add() { let name = newName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; _ = store.createLabel(name: name); newName = ""; reload() }
    func archive(_ label: TrackingLabel) { store.archiveLabel(id: label.id, archived: label.archivedAt == nil); reload() }
    func save(_ label: TrackingLabel) { store.updateLabel(label); reload() }
}

struct TrackingTabView: View {
    @StateObject private var model = TrackingPreferencesModel()
    var body: some View {
        ZStack {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            BrandCard(title: "Tracking") {
                BrandToggle(
                    title: "Enable usage tracking",
                    subtitle: "Show tracking controls in the menu bar and record labelled sessions.",
                    isOn: Binding(get: { model.trackingEnabled }, set: { model.trackingEnabled = $0; SettingsStore.shared.setTrackingEnabled($0) })
                )
                Rectangle().fill(BrandPalette.primary.opacity(0.22)).frame(height: 1).padding(.vertical, 4)
                Text("Labels").font(.system(size: 14, weight: .semibold)).foregroundColor(BrandPalette.textPrimary)
                HStack(spacing: 10) {
                    TrackingTextField(placeholder: "New label", text: $model.newName)
                    Button("Create") { model.add() }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.labels.isEmpty {
                    Text("Create a label to start grouping observed usage.")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
                } else {
                    ForEach(model.labels) { label in LabelRow(label: label, model: model) }
                }
            }
        }.padding(.bottom, 20) }
        .disabled(model.isSessionActive)
        if model.isSessionActive {
            VStack(spacing: 12) {
                Image(systemName: "record.circle").font(.system(size: 34, weight: .semibold)).foregroundColor(BrandPalette.primary)
                Text("Tracking is active").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(BrandPalette.textPrimary)
                Text("Stop the current session from the Rashun menu before changing tracking settings or labels.").font(.system(size: 14, weight: .medium)).foregroundColor(BrandPalette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 390)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(BrandPalette.background.opacity(0.9))
        }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiDataRefreshed)) { _ in model.reload() }
    }
}

private struct LabelRow: View {
    @State private var name: String
    @State private var color: String
    let label: TrackingLabel
    @ObservedObject var model: TrackingPreferencesModel
    init(label: TrackingLabel, model: TrackingPreferencesModel) { self.label = label; self.model = model; _name = State(initialValue: label.name); _color = State(initialValue: label.colorHex) }
    var body: some View {
        let isActive = TrackedUsageStore.shared.activeSession?.labelID == label.id
        HStack {
            ColorPicker("", selection: Binding(get: { Color(hex: color) ?? .purple }, set: { color = $0.hexString ?? color; save() }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)
                .fixedSize()
                .clipShape(Circle())
                .overlay(Circle().stroke(BrandPalette.primary.opacity(0.55), lineWidth: 1))
            TrackingTextField(placeholder: "Label", text: $name, width: 190).onSubmit { save() }
            Button(label.archivedAt == nil ? "Archive" : "Unarchive") { model.archive(label) }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isActive)
                .opacity(isActive ? 0.42 : 1)
            if isActive { Text("Stop session before archiving").font(.system(size: 12, weight: .medium)).foregroundColor(BrandPalette.textSecondary) }
        }.padding(.vertical, 5)
    }
    private func save() { var updated = label; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines); updated.colorHex = color; model.save(updated) }
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandPalette.background.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BrandPalette.primary.opacity(0.4), lineWidth: 1))
    }
}

private extension Color { init?(hex: String) { let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")); guard let number = UInt64(value, radix: 16) else { return nil }; self.init(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255) } }

private extension Color {
    var hexString: String? {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
        #else
        return nil
        #endif
    }
}
