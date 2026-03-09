import SwiftUI
import RashunCore

struct RuleRowView: View {
    @ObservedObject var model: PreferencesViewModel
    let sourceName: String
    let definition: NotificationDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(definition.title, isOn: Binding(
                    get: { model.isRuleEnabled(sourceName: sourceName, ruleId: definition.id) },
                    set: { model.setRuleEnabled(sourceName: sourceName, ruleId: definition.id, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(BrandPalette.textPrimary)

                Spacer(minLength: 4)

                ForEach(definition.inputs, id: \.id) { input in
                    HStack(spacing: 5) {
                        BrandNumericField(
                            text: Binding(
                                get: { model.ruleInputText(sourceName: sourceName, ruleId: definition.id, input: input) },
                                set: { model.setRuleInputDraft(sourceName: sourceName, ruleId: definition.id, inputId: input.id, text: $0) }
                            ),
                            width: 66,
                            onCommit: {
                                model.commitRuleInput(sourceName: sourceName, ruleId: definition.id, input: input)
                            }
                        )

                        if let unit = input.unit, !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(BrandPalette.textSecondary)
                        }
                    }
                }
            }

            if !definition.detail.isEmpty {
                Text(definition.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(BrandPalette.textSecondary.opacity(0.88))
                    .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandPalette.background.opacity(0.22))
        )
    }
}
