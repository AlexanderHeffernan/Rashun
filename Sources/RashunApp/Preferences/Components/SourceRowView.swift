import SwiftUI
import RashunCore

struct SourceRowView: View {
    @ObservedObject var model: PreferencesViewModel
    let source: AISource

    var body: some View {
        let isEnabled = model.isSourceEnabled(source.name)
        let isSingleMetric = source.metrics.count <= 1
        let isExpanded = model.isSourceExpanded(source.name)
        let notificationSections = model.notificationSections(for: source)
        let hasNotifications = notificationSections.contains { !$0.definitions.isEmpty }
        let hasMultipleMetrics = !isSingleMetric
        let anyMetricExpanded = source.metrics.contains {
            model.isMetricNotificationsExpanded(sourceName: source.name, metricId: $0.id)
        }
        let isCheckingHealth = model.isSourceHealthCheckInProgress(source.name)
        let warningSummary = isSingleMetric ? model.sourceWarningSummary(source.name) : nil
        let warningDetail = isSingleMetric ? model.sourceWarningDetail(source.name) : nil
        let hasWarning = isSingleMetric
            ? (warningSummary != nil)
            : model.sourceHasAnyMetricWarning(source)
        let showExpandedStyle = isSingleMetric ? isExpanded : anyMetricExpanded

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Toggle(source.name, isOn: Binding(
                    get: { isEnabled },
                    set: { model.sourceToggleChanged(source, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(isCheckingHealth)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(BrandPalette.textPrimary)

                if isCheckingHealth {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(BrandPalette.accent)
                }

                if hasWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(BrandPalette.warning)
                }

                Spacer(minLength: 0)

                if isEnabled, isSingleMetric, hasNotifications {
                    Button {
                        model.toggleNotificationsSection(source.name)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Notifications")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(BrandPalette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(BrandPalette.card.opacity(0.55))
                        )
                        .overlay(
                            Capsule()
                                .stroke(BrandPalette.primary.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let warningDetail {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(BrandPalette.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        if let warningSummary {
                            Text(warningSummary)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(BrandPalette.warning)
                        }
                        Text(warningDetail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(BrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BrandPalette.warning.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(BrandPalette.warning.opacity(0.28), lineWidth: 1)
                        )
                )
            }

            if isEnabled, hasMultipleMetrics {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Usage Metrics")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BrandPalette.textSecondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(source.metrics, id: \.id) { metric in
                            MetricNotificationsRowView(model: model, source: source, metric: metric)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BrandPalette.cardAlt.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrandPalette.primary.opacity(0.18), lineWidth: 1)
                        )
                )
            }

            if isEnabled, isSingleMetric, isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notification Rules")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BrandPalette.textSecondary)
                        .textCase(.uppercase)

                    if let section = notificationSections.first {
                        ForEach(section.definitions, id: \.id) { definition in
                            RuleRowView(model: model, sourceName: section.sourceName, definition: definition)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BrandPalette.cardAlt.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrandPalette.primary.opacity(0.18), lineWidth: 1)
                        )
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BrandPalette.cardAlt.opacity(0.38))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandPalette.primary.opacity(showExpandedStyle ? 0.22 : 0.14), lineWidth: 1)
                )
        )
    }
}

private struct MetricNotificationsRowView: View {
    @ObservedObject var model: PreferencesViewModel
    let source: AISource
    let metric: AISourceMetric

    private var metricEnabled: Bool {
        model.isMetricEnabled(sourceName: source.name, metricId: metric.id)
    }

    private var metricExpanded: Bool {
        model.isMetricNotificationsExpanded(sourceName: source.name, metricId: metric.id)
    }

    private var metricDefinitions: [NotificationDefinition] {
        model.notificationDefinitions(for: source, metricId: metric.id)
    }

    private var metricHasNotifications: Bool {
        !metricDefinitions.isEmpty
    }

    private var metricScopeName: String {
        "\(source.name)::\(metric.id)"
    }

    private var warningSummary: String? {
        model.metricWarningSummary(sourceName: source.name, metricId: metric.id)
    }

    private var warningDetail: String? {
        model.metricWarningDetail(sourceName: source.name, metricId: metric.id)
    }

    private var hasWarning: Bool {
        warningSummary != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Toggle(metric.title, isOn: Binding(
                    get: { metricEnabled },
                    set: { model.setMetricEnabled(sourceName: source.name, metricId: metric.id, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(BrandPalette.textPrimary)

                if hasWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BrandPalette.warning)
                }

                Spacer(minLength: 0)

                if metricEnabled, metricHasNotifications {
                    Button {
                        model.toggleMetricNotificationsSection(sourceName: source.name, metricId: metric.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Notifications")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: metricExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(BrandPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(BrandPalette.card.opacity(0.55))
                        )
                        .overlay(
                            Capsule()
                                .stroke(BrandPalette.primary.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let warningDetail {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BrandPalette.warning)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        if let warningSummary {
                            Text(warningSummary)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(BrandPalette.warning)
                        }
                        Text(warningDetail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(BrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandPalette.warning.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(BrandPalette.warning.opacity(0.26), lineWidth: 1)
                        )
                )
            }

            if metricEnabled, metricExpanded, metricHasNotifications {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(metricDefinitions, id: \.id) { definition in
                        RuleRowView(
                            model: model,
                            sourceName: metricScopeName,
                            definition: definition
                        )
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BrandPalette.cardAlt.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(BrandPalette.primary.opacity(0.16), lineWidth: 1)
                        )
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandPalette.background.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BrandPalette.primary.opacity(0.16), lineWidth: 1)
                )
        )
    }
}
