import DialogueKit

extension CafeOrderPhase {
    var dialogueFulfillmentContext: RainbowSmoothieFulfillmentContext {
        switch self {
        case .notOrdered: .orderingAllowed
        case .preparing: .preparing
        case .readyAtCounter: .readyAtCounter
        case .failed: .failed
        }
    }
}
