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
            return "FULFILLMENT=orderingAllowed. 아직 레인보우 스무디 주문이 접수되지 않았다. 평소대로 주문을 받는 흐름을 따르라."
        case .preparing:
            return "FULFILLMENT=preparing. 레인보우 스무디 한 잔이 이미 주문 접수되어 아직 준비 중이다. 그 사실을 인지하고 방문자에게 잠깐 기다려 달라고 말하되, 다른 주문을 접수하거나 접수했다고 말하지 마라."
        case .readyAtCounter:
            return "FULFILLMENT=readyAtCounter. 방문자의 레인보우 스무디 한 잔이 카운터에 준비되어 있다. 이미 있는 그 음료를 가져가라고 안내하고, 다른 주문은 절대 접수하지 마라."
        case .failed:
            return "FULFILLMENT=failed. 기존 레인보우 스무디 서비스를 지금은 완료할 수 없다. 현재 제공이 어렵다고 말하되, 주문이 접수됐다거나 음료가 준비됐다고 절대 말하지 마라."
        }
    }
}
