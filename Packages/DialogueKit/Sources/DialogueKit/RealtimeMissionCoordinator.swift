import Foundation

/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환하고, response.done까지
/// 기다려야 하는 상태를 소유한다. 네트워크와 UI에 의존하지 않는 순수 상태 로직이다.
public struct RealtimeMissionCoordinator: Sendable {
    public struct OrderToolEvaluation: Equatable, Sendable {
        public enum Outcome: String, Equatable, Sendable {
            case agreement
            case missedProposal
            case prematureProposal
            case invalidProposal
        }

        public let outcome: Outcome
        public let localOrderReady: Bool
        public let modelProposedOrder: Bool
        public let argumentsValid: Bool?
    }

    public struct Snapshot: Equatable, Sendable {
        public let order: RainbowSmoothieMissionProgress.Snapshot
        public let orderPlaced: Bool

        public var isPristine: Bool { order.isPristine && !orderPlaced }

        public var promptGuide: String {
            let quantity = order.requestedQuantity.map(String.init) ?? "missing"
            return """
            # Authoritative immersive conversation state
            - ACCESS_BARRIER_EXPLAINED=\(order.hasExplainedAccessBarrier)
            - RELEVANT_SERVICE_ATTEMPTS=\(order.relevantOrderAttempts)/\(order.requiredOrderAttempts)
            - COUNTER_SERVICE_ACCEPTED=\(order.counterOrderAccepted)
            - ITEM=\(order.hasMissionItem ? "Rainbow Smoothie" : "missing")
            - QUANTITY=\(quantity)
            - ORDER_PLACED=\(orderPlaced)
            Treat these values as more authoritative than assumptions from the current Realtime session.
            Never restart a resolved accessibility dispute or ask again for a known order field.
            """
        }
    }

    public struct FunctionCall: Sendable {
        public let callID: String
        public let output: String
        public let followUpInstructions: String
    }

    private var pendingEvent: MissionEvent?
    private var pendingFunctionCall: FunctionCall?
    private var orderProgress: RainbowSmoothieMissionProgress
    private var orderWasPlaced = false
    private var localOrderReadyForCurrentTurn: Bool?
    private var orderToolWasProposed = false
    private var orderToolArgumentsWereValid: Bool?

    public init(personality: ClerkPersonality = .hurried) {
        orderProgress = RainbowSmoothieMissionProgress(personality: personality)
    }

    public mutating func reset() {
        pendingEvent = nil
        pendingFunctionCall = nil
        orderProgress.reset()
        orderWasPlaced = false
        clearOrderToolEvaluation()
    }

    /// WebRTC encounter에만 속한 미완료 호출과 종료 이벤트를 제거한다.
    /// 주문 진행과 아직 전달되지 않은 주문 완료 이벤트는 immersive session 동안 보존한다.
    public mutating func clearEncounterTransientState() {
        pendingFunctionCall = nil
        if pendingEvent == .exited { pendingEvent = nil }
        clearOrderToolEvaluation()
    }

    public var snapshot: Snapshot {
        Snapshot(order: orderProgress.snapshot, orderPlaced: orderWasPlaced)
    }

    @discardableResult
    public mutating func observe(
        userTranscript: String
    ) -> RainbowSmoothieOrderDecision {
        let decision = orderProgress.observe(userTranscript: userTranscript)
        localOrderReadyForCurrentTurn = decision == .completeOrder
        orderToolWasProposed = false
        orderToolArgumentsWereValid = nil
        if decision == .completeOrder {
            pendingEvent = .orderPlaced
            orderWasPlaced = true
        }
        return decision
    }

    /// 즉시 게시할 이벤트를 반환한다. 대화 종료는 tool 결과를 모델에 보낸 뒤
    /// response.done에서 세션을 닫아야 하므로 pendingEvent로 보관한다. 주문 완료는
    /// `observe`가 로컬 슬롯을 채우는 순간 별도로 보관한다.
    public mutating func register(
        name: String,
        callID: String,
        arguments: String
    ) -> MissionEvent? {
        let output: String
        let followUpInstructions: String
        let immediateEvent: MissionEvent?
        switch name {
        case "place_order":
            orderToolWasProposed = true
            let argumentsAreValid = validatePlaceOrderArguments(arguments)
            orderToolArgumentsWereValid = argumentsAreValid
            let locallyReady = orderProgress.canComplete
            immediateEvent = nil
            if locallyReady {
                output = #"{"success":true,"mode":"shadow","message":"proposal matched app order state"}"#
                followUpInstructions = """
                  The app has already recorded the one-cup Rainbow Smoothie order. Briefly confirm it in
                  natural Korean, say the visitor will be notified when it is ready, then stop.
                  """
            } else {
                output = #"{"success":false,"mode":"shadow","message":"order fields or service state are incomplete"}"#
                followUpInstructions = """
                  The app rejected the order proposal because authoritative fields are incomplete. Do not
                  claim an order was placed. Ask only for the next missing detail in natural Korean.
                  """
            }
        case "request_help":
            immediateEvent = .helpRequested
            output = #"{"success":true,"message":"help requested"}"#
            followUpInstructions = """
              Tools are disabled for this response. Briefly acknowledge in Korean that another employee
              has been requested, then stop and wait for the visitor.
              """
        case "end_conversation":
            pendingEvent = .exited
            immediateEvent = nil
            output = #"{"success":true,"message":"conversation may close"}"#
            followUpInstructions = """
              Tools are disabled for this response. Give one short natural Korean farewell and stop.
              """
        default:
            immediateEvent = nil
            output = #"{"success":false,"message":"unknown function"}"#
            followUpInstructions = """
              Tools are disabled for this response. Briefly continue the conversation in Korean without
              mentioning tools, then stop and wait for the visitor.
              """
        }
        pendingFunctionCall = FunctionCall(
            callID: callID,
            output: output,
            followUpInstructions: followUpInstructions
        )
        return immediateEvent
    }

    /// 한 모델 응답에서 나온 주문 제안과 로컬 판정을 비교한다. transcript나 개인정보를
    /// 포함하지 않아 앱의 metrics sink가 안전하게 집계할 수 있다.
    public mutating func finishOrderToolEvaluation() -> OrderToolEvaluation? {
        guard let localOrderReady = localOrderReadyForCurrentTurn else { return nil }
        let outcome: OrderToolEvaluation.Outcome
        if localOrderReady {
            if !orderToolWasProposed {
                outcome = .missedProposal
            } else if orderToolArgumentsWereValid == true {
                outcome = .agreement
            } else {
                outcome = .invalidProposal
            }
        } else {
            outcome = orderToolWasProposed ? .prematureProposal : .agreement
        }
        let evaluation = OrderToolEvaluation(
            outcome: outcome,
            localOrderReady: localOrderReady,
            modelProposedOrder: orderToolWasProposed,
            argumentsValid: orderToolArgumentsWereValid
        )
        clearOrderToolEvaluation()
        return evaluation
    }

    public mutating func takeFunctionCall() -> FunctionCall? {
        defer { pendingFunctionCall = nil }
        return pendingFunctionCall
    }

    public mutating func takeCompletedEvent() -> MissionEvent? {
        defer { pendingEvent = nil }
        return pendingEvent
    }

    private func validatePlaceOrderArguments(_ arguments: String) -> Bool {
        struct Arguments: Decodable {
            let item: String
            let quantity: Int
        }
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return false
        }
        return decoded.item == "rainbow_smoothie"
            && decoded.quantity == RainbowSmoothieMissionOrder.quantity
    }

    private mutating func clearOrderToolEvaluation() {
        localOrderReadyForCurrentTurn = nil
        orderToolWasProposed = false
        orderToolArgumentsWereValid = nil
    }
}
