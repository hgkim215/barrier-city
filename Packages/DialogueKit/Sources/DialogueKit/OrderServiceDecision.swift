import Foundation

/// 높은 키오스크 장면에서 이번 턴에 점원이 주문을 실제로 받을지 결정한다.
public enum OrderServiceDecision: String, Equatable, Sendable {
    case notApplicable
    case acceptDirectly
    case refuseKioskOnly
    case acceptReluctantly

    public var acceptsVerbalOrder: Bool {
        self == .acceptDirectly || self == .acceptReluctantly
    }

    var promptRule: String {
        switch self {
        case .notApplicable:
            "The customer has not made an order request this turn. Do not pretend an order was completed."
        case .acceptDirectly:
            "Take the verbal order at the counter without requiring the kiosk. If no specific item was given, naturally ask what they would like. If an item was given, briefly confirm it."
        case .refuseKioskOnly:
            "Refuse to take the verbal order this turn. Insist that this store accepts orders only through the kiosk, even though its screen is too high. Do not ask for or confirm a menu item."
        case .acceptReluctantly:
            "Give in and take the verbal order so the customer can proceed. Make it clear you are doing it only this once. If no item was given, ask what they would like. Do not send them back to the kiosk."
        }
    }
}
