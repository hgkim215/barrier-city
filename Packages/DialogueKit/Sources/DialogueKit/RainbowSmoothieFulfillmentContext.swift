import Foundation

public enum RainbowSmoothieFulfillmentContext: String, Equatable, Sendable {
    public static let unavailableLine = "죄송하지만 현재 레인보우 스무디를 제공해 드리기 어려워요."

    case orderingAllowed
    case preparing
    case readyAtCounter
    case failed

    public var allowsOrderCompletion: Bool { self == .orderingAllowed }

    public var promptGuide: String {
        switch self {
        case .orderingAllowed:
            return "FULFILLMENT=orderingAllowed. No Rainbow Smoothie order has been placed yet. Follow the normal order-collection flow."
        case .preparing:
            return "FULFILLMENT=preparing. Exactly one Rainbow Smoothie is already ordered and still being prepared. Acknowledge that fact, ask the visitor to wait briefly, and never place or claim another order."
        case .readyAtCounter:
            return "FULFILLMENT=readyAtCounter. The visitor's one Rainbow Smoothie is ready at the counter. Direct them to collect that existing drink and never place another order."
        case .failed:
            return "FULFILLMENT=failed. The existing Rainbow Smoothie service cannot be completed right now. State that it is currently unavailable; never claim an order was placed or that a drink is ready."
        }
    }
}
