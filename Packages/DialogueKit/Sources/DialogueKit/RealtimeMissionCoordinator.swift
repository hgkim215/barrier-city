/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환하고, response.done까지
/// 기다려야 하는 상태를 소유한다. 네트워크와 UI에 의존하지 않는 순수 상태 로직이다.
public struct RealtimeMissionCoordinator: Sendable {
    public struct FunctionCall: Sendable {
        public let callID: String
        public let output: String
        public let followUpInstructions: String
    }

    private var pendingEvent: MissionEvent?
    private var pendingFunctionCall: FunctionCall?
    private var orderProgress: RainbowSmoothieMissionProgress

    public init(personality: ClerkPersonality = .hurried) {
        orderProgress = RainbowSmoothieMissionProgress(personality: personality)
    }

    public mutating func reset() {
        pendingEvent = nil
        pendingFunctionCall = nil
        orderProgress.reset()
    }

    public mutating func observe(userTranscript: String) {
        orderProgress.observe(userTranscript: userTranscript)
    }

    /// 즉시 게시할 이벤트를 반환한다. 주문 완료·대화 종료는 tool 결과를 모델에 보낸 뒤
    /// response.done에서 세션을 닫아야 하므로 pendingEvent로 보관한다.
    public mutating func register(
        name: String,
        callID: String,
        arguments: String
    ) -> MissionEvent? {
        let output: String
        let followUpInstructions: String
        let immediateEvent: MissionEvent?
        switch name {
        case "complete_order":
            let isValidOrder = orderProgress.canComplete
                && RainbowSmoothieMissionOrder.validates(toolArgumentsJSON: arguments)
            pendingEvent = isValidOrder ? .orderPlaced : nil
            immediateEvent = nil
            output = isValidOrder
                ? #"{"success":true,"message":"order recorded"}"#
                : #"{"success":false,"message":"order requirements are incomplete; ask the visitor for the missing confirmation and wait"}"#
            followUpInstructions = isValidOrder
                ? """
                  Tools are disabled for this response. In one short natural Korean sentence, confirm that
                  exactly one Rainbow Smoothie has been ordered. Do not say it is still processing, do not
                  ask another question, and then stop.
                  """
                : """
                  Tools are disabled for this response. The order was NOT recorded. In one or two short
                  natural Korean sentences, say that the order is not complete and ask for one missing
                  confirmation required by the conversation flow. Never claim that it is processing or
                  retry any tool. Then stop and wait for the visitor.
                  """
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
