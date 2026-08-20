import Foundation

/// Realtime 미션 주문의 상품명과 수량 표현을 로컬에서 정규화한다.
public enum RainbowSmoothieMissionOrder: Sendable {
    public static let quantity = 1

    /// Function calling의 유일한 미션 상품은 전체 상품명인
    /// "레인보우 마카롱 스무디"다.
    public static func isExactMissionItemMention(in userText: String) -> Bool {
        let normalized = normalize(userText)
        let mentionsExactItem = [
            "레인보우마카롱스무디",
            "rainbowmacaronsmoothie",
        ].contains(where: normalized.contains)
        let rejectsItem = [
            "레인보우마카롱스무디말고",
            "레인보우마카롱스무디는말고",
            "레인보우마카롱스무디취소",
            "레인보우마카롱스무디아니",
            "레인보우마카롱스무디안",
        ].contains(where: normalized.contains)
        return mentionsExactItem && !rejectsItem
    }

    static func mentionsDifferentItem(in userText: String) -> Bool {
        let normalized = userText.lowercased()
        return [
            "아메리카노", "라떼", "에스프레소", "카푸치노", "모카", "콜드브루",
            "주스", "에이드", "차", "티", "딸기 스무디", "망고 스무디",
        ].contains(where: normalized.contains)
    }

    static func requestedQuantity(in userText: String) -> Int? {
        let normalized = normalize(userText)
        let wordQuantities: [(tokens: [String], quantity: Int)] = [
            // 음성 전사에서 잔→장으로 잘못 잡히는 경우와 자연스러운 컵 표현을
            // 주문 수량 문맥에서 같은 단위로 취급한다.
            (["한잔", "한장", "한개", "한컵", "하나", "일잔", "일장", "일개", "일컵"], 1),
            (["두잔", "두장", "두개", "두컵", "둘", "이잔", "이장", "이개", "이컵"], 2),
            (["세잔", "세장", "세개", "세컵", "셋", "삼잔", "삼장", "삼개", "삼컵"], 3),
            (["네잔", "네장", "네개", "네컵", "넷", "사잔", "사장", "사개", "사컵"], 4),
        ]
        for entry in wordQuantities where entry.tokens.contains(where: normalized.contains) {
            return entry.quantity
        }

        guard let match = normalized.range(
            of: #"[0-9]+(잔|장|개|컵)"#,
            options: .regularExpression
        ) else { return nil }
        let digits = normalized[match].prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
