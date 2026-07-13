import Foundation

public struct WebPushSubscription: Sendable, Equatable {
    public let endpoint: URL
    public let clientPublicKey: Data
    public let authSecret: Data

    public init(endpoint: URL, clientPublicKey: Data, authSecret: Data) {
        self.endpoint = endpoint
        self.clientPublicKey = clientPublicKey
        self.authSecret = authSecret
    }
}

public struct WebPushSubscriptionRecord: Sendable, Equatable {
    public let credentialID: UUID
    public let subscription: WebPushSubscription

    public init(credentialID: UUID, subscription: WebPushSubscription) {
        self.credentialID = credentialID
        self.subscription = subscription
    }
}
