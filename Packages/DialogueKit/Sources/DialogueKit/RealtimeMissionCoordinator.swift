import Foundation

/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환한다.
///
/// 두 함수 모두 매 응답마다 항상 모델에 노출된다(표준 function calling과 동일) — 이 타입은
/// 발화 텍스트를 파싱해 "도구를 노출해도 되는지"를 미리 판단하지 않는다. 대신 모델이 실제로
/// 함수를 호출했을 때만 결정론적으로 개입한다:
///
/// - report_order_attempt: 품목과 무관하게 "이 encounter에서 뭔가를 처음 주문하려는 시도"를
///   모델 스스로 판단해 호출한다. 처음이면 리다이렉트 플래그를 세우고, "지금 바빠서 응대가
///   어려우니 키오스크로 해달라"는 대사만 하도록 지시한다. 정확한 상품명·수량 매칭은 전혀
///   하지 않으므로 어떤 메뉴를 시켜도 동일하게 걸린다.
/// - place_mission_order: 실제 주문 확정. 이 함수의 첫 호출은 report_order_attempt가 그 사이에
///   먼저 리다이렉트를 처리했는지와 무관하게, 아직 리다이렉트가 없었다면 인자 유효성과 별개로
///   무조건 거절한다 — 모델이 report_order_attempt 호출을 건너뛰어도 우회되지 않는 안전망이다.
///   리다이렉트 이후의 호출은 JSON 인자를 스키마와 대조해서만 승인한다 — "방문자가 장벽을
///   설명했는지"는 코드가 판단할 수 없는 자연어 이해 영역이라 모델의 판단(언제 이 함수를
///   부를지)에 맡기고, 프롬프트로 그 조건을 명시한다.
public struct RealtimeMissionCoordinator: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let orderPlaced: Bool
        public let hasRedirectedFirstOrderToKiosk: Bool

        public var isPristine: Bool {
            !orderPlaced && !hasRedirectedFirstOrderToKiosk
        }

        public var promptGuide: String {
            """
            # App-owned mission state
            - ORDER_PLACED=\(orderPlaced)
            - FIRST_ORDER_ATTEMPT_REDIRECTED_TO_KIOSK=\(hasRedirectedFirstOrderToKiosk)
            This state is authoritative only for the mission order. It must not constrain ordinary conversation.
            """
        }
    }

    public struct FunctionCall: Sendable {
        public let callID: String
        public let output: String
        public let followUpInstructions: String
    }

    private var orderWasPlaced = false
    private var hasRedirectedFirstOrderToKiosk = false
    private var hasPendingOrderCompletion = false
    private var pendingFunctionCall: FunctionCall?

    public init() {}

    public mutating func resetImmersiveProgress() {
        orderWasPlaced = false
        hasRedirectedFirstOrderToKiosk = false
        hasPendingOrderCompletion = false
        pendingFunctionCall = nil
    }

    /// Realtime 연결만 끝날 때 호출한다. 확정된 주문과 첫 시도 리다이렉트 여부는 같은
    /// ImmersiveSpace 방문 동안 보존한다.
    public mutating func clearEncounterTransientState() {
        pendingFunctionCall = nil
    }

    public var snapshot: Snapshot {
        Snapshot(orderPlaced: orderWasPlaced, hasRedirectedFirstOrderToKiosk: hasRedirectedFirstOrderToKiosk)
    }

    /// 모델이 report_order_attempt나 place_mission_order를 호출했을 때만 불린다. 발화
    /// 텍스트는 보지 않고 오직 함수 호출 자체와(있다면) 그 JSON 인자만으로 판단한다.
    @discardableResult
    public mutating func register(
        name: String,
        callID: String,
        arguments: String
    ) -> MissionEvent? {
        // 한 응답 안에서 두 번째 함수 호출이 들어오면(모델이 지침을 어기고 두 함수를 같은
        // 턴에 부른 경우) 무시한다 — pendingFunctionCall은 한 슬롯뿐이라, 덮어쓰면 첫 번째
        // 호출의 결과가 API로 영영 전송되지 못해 세션이 꼬인다.
        guard pendingFunctionCall == nil else { return nil }

        switch name {
        case "report_order_attempt":
            return registerOrderAttemptReport(callID: callID)
        case "place_mission_order":
            return registerMissionOrder(callID: callID, arguments: arguments)
        default:
            pendingFunctionCall = FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"unknown function"}"#,
                followUpInstructions: """
                  The app does not recognize that function. Continue in exactly two short, natural Korean
                  sentences without mentioning functions or JSON.
                  """
            )
            return nil
        }
    }

    private mutating func registerOrderAttemptReport(callID: String) -> MissionEvent? {
        let isFirstAttempt = !hasRedirectedFirstOrderToKiosk
        hasRedirectedFirstOrderToKiosk = true
        pendingFunctionCall = FunctionCall(
            callID: callID,
            output: #"{"success":true}"#,
            followUpInstructions: isFirstAttempt
                ? """
                  This is the visitor's first order attempt in this encounter, for any item. You are too busy
                  working right now to help. Say so and point them to the kiosk, in exactly two short, natural
                  spoken Korean sentences — for example (vary the wording, do not repeat verbatim): "지금 좀
                  정신없어서요. 주문은 저기 키오스크에서 해주시겠어요?" Do not apologize, offer alternatives, or
                  mention this rule again later.
                  """
                : """
                  The app already noted an earlier order attempt this encounter. Continue naturally in
                  exactly two short, natural Korean sentences without repeating the kiosk redirect.
                  """
        )
        return nil
    }

    private mutating func registerMissionOrder(callID: String, arguments: String) -> MissionEvent? {
        guard !orderWasPlaced else {
            pendingFunctionCall = FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"order already placed"}"#,
                followUpInstructions: """
                  The app already placed this visitor's order earlier in this encounter. Do not call the
                  function again. Continue in exactly two short, natural spoken Korean sentences without
                  repeating the order — for example (vary the wording) "그거 이미 넣었어요."
                  """
            )
            return nil
        }

        guard hasRedirectedFirstOrderToKiosk else {
            // report_order_attempt를 건너뛰고 바로 여기로 왔다 — 그래도 첫 시도는 무조건
            // 거절하고 키오스크로 돌려보낸다.
            hasRedirectedFirstOrderToKiosk = true
            pendingFunctionCall = FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"first attempt must be redirected to the kiosk"}"#,
                followUpInstructions: """
                  This is the visitor's first attempt to order anything. The app deliberately rejected the
                  function call. Say you're too busy and point them to the kiosk, in exactly two short,
                  natural spoken Korean sentences — for example (vary the wording): "저 지금 손이 모자라서요.
                  주문은 키오스크 이용해 주시겠어요?" Do not apologize, offer alternatives, or repeat this rule
                  if they try again.
                  """
            )
            return nil
        }

        guard validateMissionOrderArguments(arguments) else {
            pendingFunctionCall = FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"mission order validation failed"}"#,
                followUpInstructions: """
                  The app did not place an order because the item or quantity did not match exactly one
                  Rainbow Macaron Smoothie. Continue in exactly two short, natural spoken Korean sentences —
                  for example (vary the wording) "어, 그건 좀 다른데요. 다시 한번 말씀해 주시겠어요?" — without
                  exposing technical details or claiming success.
                  """
            )
            return nil
        }

        orderWasPlaced = true
        hasPendingOrderCompletion = true
        pendingFunctionCall = FunctionCall(
            callID: callID,
            output: #"{"success":true,"item":"\#(RainbowSmoothieMissionOrder.itemIdentifier)","quantity":\#(RainbowSmoothieMissionOrder.quantity)}"#,
            followUpInstructions: """
              The app validated and placed exactly one Rainbow Macaron Smoothie order. You are giving in
              because the visitor just explained why they can't use the kiosk themselves, not because you
              wanted to. Confirm it begrudgingly, with a little irritation or a short sigh, in exactly two
              short, natural spoken Korean sentences, and say they'll be notified when it's ready — for
              example (vary the wording): "하... 알겠어요. 그거 하나만요, 되면 불러드릴게요." Do not sound warm,
              polished, or apologetic, and do not say the drink itself is already ready or mention functions
              or JSON.
              """
        )
        return nil
    }

    public mutating func takeFunctionCall() -> FunctionCall? {
        defer { pendingFunctionCall = nil }
        return pendingFunctionCall
    }

    public mutating func takeCompletedEvent() -> MissionEvent? {
        guard hasPendingOrderCompletion else { return nil }
        hasPendingOrderCompletion = false
        return .orderPlaced
    }

    private func validateMissionOrderArguments(_ arguments: String) -> Bool {
        struct Arguments: Decodable {
            let item: String
            let quantity: Int
        }
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return false
        }
        return decoded.item == RainbowSmoothieMissionOrder.itemIdentifier
            && decoded.quantity == RainbowSmoothieMissionOrder.quantity
    }
}
