import SwiftUI
import RashunCore

@MainActor
final class TrackedUsageViewModel: ObservableObject {
    @Published var sessions: [TrackedSession] = []
    @Published var selectedLabelID: UUID?
    @Published var selectedSessionID: UUID?
    private let store = TrackedUsageStore.shared
    init() { reload() }
    func reload() { sessions = store.sessions; if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) { self.selectedSessionID = nil } }
    var selected: TrackedSession? { sessions.first { $0.id == selectedSessionID } }
    var labels: [(id: UUID, name: String)] { Dictionary(grouping: sessions, by: \.labelID).compactMap { id, sessions in sessions.first.map { (id, $0.labelNameSnapshot) } }.sorted { $0.name < $1.name } }
    var sessionsForSelectedLabel: [TrackedSession] { guard let selectedLabelID else { return [] }; return sessions.filter { $0.labelID == selectedLabelID } }
    var totalDuration: TimeInterval { sessions.reduce(0) { $0 + (($1.endedAt ?? Date()).timeIntervalSince($1.startedAt)) } }
    func deleteSelected() { guard let id = selectedSessionID else { return }; store.deleteSession(id: id); selectedSessionID = nil; reload() }
}

struct TrackedUsageRootView: View {
    @ObservedObject var model: TrackedUsageViewModel
    @State private var labelFilter = "All labels"
    @State private var expandedObservationMetrics: Set<String> = []
    @State private var isConfirmingDeletion = false
    var body: some View {
        ZStack {
            BrandPalette.background.ignoresSafeArea()
            if model.sessions.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "scope")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(BrandPalette.primary)
                    Text("No tracked sessions yet")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(BrandPalette.textPrimary)
                    Text("Choose Start Session… from the Rashun menu to begin observing quota usage under a label.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(BrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 370)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tracked Usage").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(BrandPalette.textPrimary)
                        Text("Observed quota consumed during labelled sessions").font(.system(size: 16, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
                    }
                    HStack {
                        Text("\(model.sessions.count) sessions • \(duration(model.totalDuration)) tracked").font(.system(size: 13, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
                        Spacer()
                        Button("Tracking Preferences…") { (NSApp.delegate as? AppDelegate)?.openPreferences(tab: .tracking) }.buttonStyle(SecondaryActionButtonStyle())
                        Button("Delete Session") { isConfirmingDeletion = true }.buttonStyle(DangerActionButtonStyle()).disabled(model.selected == nil).opacity(model.selected == nil ? 0.42 : 1)
                    }
                    HStack(spacing: 16) {
                        labelPicker.frame(width: 255).fixedSize(horizontal: true, vertical: false).layoutPriority(1).frame(maxHeight: .infinity)
                        if model.selectedLabelID != nil {
                            sessionPicker.frame(width: 255).fixedSize(horizontal: true, vertical: false).layoutPriority(1).frame(maxHeight: .infinity)
                        }
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(26)
            }
        }
        .frame(minWidth: 740, minHeight: 520)
        .alert("Delete tracked session?", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the selected session and its usage observations. This action cannot be undone.")
        }
    }
    @ViewBuilder private var detail: some View {
        if let session = model.selected {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                Text(session.labelNameSnapshot).font(.system(size: 22, weight: .bold)).foregroundColor(BrandPalette.textPrimary)
                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) — \(session.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Active")").font(.system(size: 14, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
                ForEach(TrackedUsageAttributionEngine.results(for: session)) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(metric.sourceName) — \(metric.metricTitle): \(String(format: "%.1f", metric.percentagePointsConsumed))%").fontWeight(.semibold)
                        Button {
                            if expandedObservationMetrics.contains(metric.id) { expandedObservationMetrics.remove(metric.id) }
                            else { expandedObservationMetrics.insert(metric.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: expandedObservationMetrics.contains(metric.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Observation details")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
                        if expandedObservationMetrics.contains(metric.id) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(metric.segments) { segment in
                                    ForEach(segment.observations) { observation in
                                        Text("\(observation.timestamp.formatted(date: .abbreviated, time: .shortened)): \(Int(observation.remaining))/\(Int(observation.limit))  \(observation.origin.rawValue)").font(.caption).foregroundColor(BrandPalette.textSecondary)
                                    }
                                }
                            }
                            .padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(metric.warnings, id: \.self) { Text($0).font(.caption).foregroundColor(.orange) }
                    }.padding().background(RoundedRectangle(cornerRadius: 12).fill(BrandPalette.cardAlt))
                }
            }}
        } else if let labelID = model.selectedLabelID {
            labelSummary(for: labelID)
        } else { Text("Select a label, then a session, to inspect observed usage.").font(.system(size: 14, weight: .medium)).foregroundColor(BrandPalette.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private var labelPicker: some View {
        pickerCard(title: "Labels") {
            ForEach(model.labels, id: \.id) { label in
                let total = labelTotal(label.id)
                pickerButton(title: label.name, subtitle: "\(String(format: "%.1f", total))% observed", action: {
                    if model.selectedLabelID == label.id { model.selectedLabelID = nil; model.selectedSessionID = nil }
                    else { model.selectedLabelID = label.id; model.selectedSessionID = nil }
                }, selected: model.selectedLabelID == label.id)
            }
        }
    }
    private var sessionPicker: some View {
        pickerCard(title: "Sessions") {
            ForEach(model.sessionsForSelectedLabel) { session in
                let total = TrackedUsageAttributionEngine.results(for: session).reduce(0) { $0 + $1.percentagePointsConsumed }
                pickerButton(title: session.startedAt.formatted(date: .abbreviated, time: .shortened), subtitle: "\(String(format: "%.1f", total))% observed", action: {
                    model.selectedSessionID = model.selectedSessionID == session.id ? nil : session.id
                }, selected: model.selectedSessionID == session.id)
            }
        }
    }
    private func pickerCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BrandPalette.textPrimary)
            ScrollView { VStack(spacing: 7) { content() } }
        }.padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BrandPalette.card).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BrandPalette.primary.opacity(0.34), lineWidth: 1)))
    }
    private func pickerButton(title: String, subtitle: String, action: @escaping () -> Void, selected: Bool) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 3) { Text(title).lineLimit(1).truncationMode(.tail).font(.system(size: 14, weight: .semibold)).foregroundColor(BrandPalette.textPrimary); if !subtitle.isEmpty { Text(subtitle).lineLimit(1).truncationMode(.tail).font(.system(size: 12, weight: .medium)).foregroundColor(BrandPalette.textSecondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? BrandPalette.primary.opacity(0.24) : BrandPalette.background.opacity(0.5))).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BrandPalette.primary.opacity(selected ? 0.65 : 0.18), lineWidth: 1)) }.buttonStyle(.plain)
    }
    private func labelTotal(_ id: UUID) -> Double {
        model.sessions.filter { $0.labelID == id }.flatMap(TrackedUsageAttributionEngine.results).reduce(0) { $0 + $1.percentagePointsConsumed }
    }
    private func labelSummary(for id: UUID) -> some View {
        let sessions = model.sessions.filter { $0.labelID == id }
        let grouped = Dictionary(grouping: sessions.flatMap(TrackedUsageAttributionEngine.results), by: \.id)
        return ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text(sessions.first?.labelNameSnapshot ?? "Label").font(.system(size: 22, weight: .bold)).foregroundColor(BrandPalette.textPrimary)
            Text("Observed usage across \(sessions.count) sessions").font(.system(size: 14, weight: .medium)).foregroundColor(BrandPalette.textSecondary)
            ForEach(grouped.keys.sorted(), id: \.self) { key in
                if let metrics = grouped[key], let first = metrics.first {
                    let total = metrics.reduce(0) { $0 + $1.percentagePointsConsumed }
                    HStack { Text("\(first.sourceName) — \(first.metricTitle)").fontWeight(.semibold); Spacer(); Text("\(String(format: "%.1f", total))%").fontWeight(.semibold) }
                        .padding().background(RoundedRectangle(cornerRadius: 12).fill(BrandPalette.cardAlt))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func duration(_ value: TimeInterval) -> String { let minutes = Int(value / 60); return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m" }
}
