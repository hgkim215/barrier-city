import DialogueKit

/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환하고, response.done까지
/// 기다려야 하는 상태를 소유한다. NPCDialogueController는 UI/대화 수명주기에 집중한다.
struct RealtimeMissionCoordinator {
    struct FunctionCall {
        let callID: String
        let output: String
    }

    private var pendingEvent: MissionEvent?
    private var pendingFunctionCall: FunctionCall?
    private var orderProgress: RainbowSmoothieMissionProgress

    init(personality: ClerkPersonality = .hurried) {
        orderProgress = RainbowSmoothieMissionProgress(personality: personality)
    }

    mutating func reset() {
        pendingEvent = nil
        pendingFunctionCall = nil
        orderProgress.reset()
    }

    mutating func observe(userTranscript: String) {
        orderProgress.observe(userTranscript: userTranscript)
    }

    /// 즉시 게시할 이벤트를 반환한다. 주문 완료·대화 종료는 tool 결과를 모델에 보낸 뒤
    /// response.done에서 세션을 닫아야 하므로 pendingEvent로 보관한다.
    mutating func register(name: String, callID: String, arguments: String) -> MissionEvent? {
        let output: String
        let immediateEvent: MissionEvent?
        switch name {
        case "complete_order":
            let isValidOrder = orderProgress.canComplete
                && RainbowSmoothieMissionOrder.validates(toolArgumentsJSON: arguments)
            pendingEvent = isValidOrder ? .orderPlaced : nil
            immediateEvent = nil
            output = isValidOrder
                ? #"{"success":true,"message":"order recorded"}"#
                : #"{"success":false,"message":"order item or quantity did not match the confirmed mission order"}"#
        case "request_help":
            immediateEvent = .helpRequested
            output = #"{"success":true,"message":"help requested"}"#
        case "end_conversation":
            pendingEvent = .exited
            immediateEvent = nil
            output = #"{"success":true,"message":"conversation may close"}"#
        default:
            immediateEvent = nil
            output = #"{"success":false,"message":"unknown function"}"#
        }
        pendingFunctionCall = FunctionCall(callID: callID, output: output)
        return immediateEvent
    }

    mutating func takeFunctionCall() -> FunctionCall? {
        defer { pendingFunctionCall = nil }
        return pendingFunctionCall
    }

    mutating func takeCompletedEvent() -> MissionEvent? {
        defer { pendingEvent = nil }
        return pendingEvent
    }
}
