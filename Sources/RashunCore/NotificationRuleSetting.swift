import Foundation

public struct NotificationRuleSetting: Codable {
    public var ruleId: String
    public var isEnabled: Bool
    public var inputValues: [String: Double]

    public init(ruleId: String, isEnabled: Bool, inputValues: [String: Double]) {
        self.ruleId = ruleId
        self.isEnabled = isEnabled
        self.inputValues = inputValues
    }
}
