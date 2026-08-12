import Foundation

/// 미션 주문의 단일 진실원. 모델의 tool 호출과 로컬 의도 판정 모두 같은 조건을 사용한다.
public enum RainbowSmoothieMissionOrder: Sendable {
    public static let canonicalItem = "rainbow_smoothie"
    public static let quantity = 1

    private struct ToolArguments: Decodable {
        let item: String
        let quantity: Int
    }

    public static func matches(userText: String) -> Bool {
        let normalized = userText.lowercased()
            .replacingOccurrences(of: " ", with: "")
        let mentionsMissionItem = mentionsItem(in: normalized)
        let rejectsMissionItem = [
            "레인보우스무디말고", "레인보우스무디는말고", "레인보우스무디취소",
            "레인보우스무디아니", "레인보우스무디안",
        ].contains(where: normalized.contains)
        let mentionsMultipleItemsByWord = [
            "두잔", "두개", "세잔", "세개", "네잔", "네개", "다섯잔", "다섯개",
            "여섯잔", "여섯개", "일곱잔", "일곱개", "여덟잔", "여덟개",
            "아홉잔", "아홉개", "열잔", "열개", "여러잔", "여러개",
        ].contains(where: normalized.contains)
        let mentionsMultipleItemsByNumber = normalized.range(
            of: #"[2-9][0-9]*(잔|개)"#,
            options: .regularExpression
        ) != nil
        return mentionsMissionItem
            && !rejectsMissionItem
            && !mentionsMultipleItemsByWord
            && !mentionsMultipleItemsByNumber
    }

    static func mentionsItem(in userText: String) -> Bool {
        let normalized = userText.lowercased()
            .replacingOccurrences(of: " ", with: "")
        return normalized.contains("레인보우스무디")
            || normalized.contains("rainbowsmoothie")
    }

    static func mentionsDifferentItem(in userText: String) -> Bool {
        let normalized = userText.lowercased()
        return [
            "아메리카노", "라떼", "에스프레소", "카푸치노", "모카", "콜드브루",
            "주스", "에이드", "차", "티", "딸기 스무디", "망고 스무디",
        ].contains(where: normalized.contains)
    }

    public static func validates(toolArgumentsJSON: String) -> Bool {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ToolArguments.self, from: data) else {
            return false
        }
        return arguments.item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == canonicalItem
            && arguments.quantity == quantity
    }
}

/// Realtime 모델의 주장과 별개로 사용자 transcript와 성격별 설득 단계를 로컬에서 추적한다.
public struct RainbowSmoothieMissionProgress: Sendable {
    private let requiredOrderAttempts: Int
    private var hasExplainedAccessBarrier = false
    private var relevantOrderAttempts = 0
    private var hasRequestedSingleMissionItem = false

    public init(personality: ClerkPersonality) {
        requiredOrderAttempts = personality.verbalOrderAcceptanceAttempt
    }

    public var canComplete: Bool {
        hasExplainedAccessBarrier
            && relevantOrderAttempts >= requiredOrderAttempts
            && hasRequestedSingleMissionItem
    }

    public mutating func reset() {
        hasExplainedAccessBarrier = false
        relevantOrderAttempts = 0
        hasRequestedSingleMissionItem = false
    }

    public mutating func observe(userTranscript: String) {
        let router = IntentRouter()
        let continuesExplainedRequest = hasExplainedAccessBarrier
            && router.continuesAccessRequest(in: userTranscript)
        if router.describesKioskAccessBarrier(in: userTranscript) {
            hasExplainedAccessBarrier = true
        }

        let intent = router.infer(from: userTranscript)
        let isOrderIntent = intent.kind == .orderRequest || intent.kind == .orderComplete
        if hasExplainedAccessBarrier && (isOrderIntent || continuesExplainedRequest) {
            relevantOrderAttempts += 1
        }

        if RainbowSmoothieMissionOrder.mentionsItem(in: userTranscript) {
            hasRequestedSingleMissionItem = RainbowSmoothieMissionOrder.matches(
                userText: userTranscript
            )
        } else if RainbowSmoothieMissionOrder.mentionsDifferentItem(in: userTranscript) {
            hasRequestedSingleMissionItem = false
        }
    }
}
