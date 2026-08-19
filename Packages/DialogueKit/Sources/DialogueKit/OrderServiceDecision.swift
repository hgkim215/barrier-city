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
            "Agree to take the verbal order at the counter without requiring the kiosk. This acceptance only opens counter service and never completes an order; follow the separate collection behavior for item and quantity."
        case .refuseKioskOnly:
            "Refuse to take the verbal order this turn. Use exactly two short, natural Korean sentences and insist curtly that this store accepts orders only through the kiosk, even though its screen is too high. Do not apologize, ask for or confirm a menu item, offer help, or suggest another ordering method."
        case .acceptReluctantly:
            "Give in and take the verbal order so the customer can proceed. Make it clear you are doing it only this once. This only opens counter service; follow the separate collection behavior for item and quantity. Do not send them back to the kiosk."
        }
    }
}
