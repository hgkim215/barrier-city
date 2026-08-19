/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환하고, response.done까지
/// 기다려야 하는 상태를 소유한다. 네트워크와 UI에 의존하지 않는 순수 상태 로직이다.
public struct RealtimeMissionCoordinator: Sendable {
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

    public init(personality: ClerkPersonality = .hurried) {
        orderProgress = RainbowSmoothieMissionProgress(personality: personality)
    }

    public mutating func reset() {
        pendingEvent = nil
        pendingFunctionCall = nil
        orderProgress.reset()
        orderWasPlaced = false
    }

    /// WebRTC encounter에만 속한 미완료 호출과 종료 이벤트를 제거한다.
    /// 주문 진행과 아직 전달되지 않은 주문 완료 이벤트는 immersive session 동안 보존한다.
    public mutating func clearEncounterTransientState() {
        pendingFunctionCall = nil
        if pendingEvent == .exited { pendingEvent = nil }
    }

    public var snapshot: Snapshot {
        Snapshot(order: orderProgress.snapshot, orderPlaced: orderWasPlaced)
    }

    @discardableResult
    public mutating func observe(
        userTranscript: String
    ) -> RainbowSmoothieOrderDecision {
        let decision = orderProgress.observe(userTranscript: userTranscript)
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

    public mutating func takeFunctionCall() -> FunctionCall? {
        defer { pendingFunctionCall = nil }
        return pendingFunctionCall
    }

    public mutating func takeCompletedEvent() -> MissionEvent? {
        defer { pendingEvent = nil }
        return pendingEvent
    }
}
