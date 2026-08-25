import Foundation

/// Realtime 미션 주문의 유일한 상품 정의. 발화 텍스트를 파싱하는 로직은 여기 두지 않는다 —
/// 주문 성립 여부는 이제 모델의 place_mission_order 호출과 그 JSON 인자로만 판단한다
/// (RealtimeMissionCoordinator.register 참고).
public enum RainbowSmoothieMissionOrder: Sendable {
    public static let quantity = 1
    public static let itemIdentifier = "rainbow_macaron_smoothie"
    public static let displayName = "레인보우 마카롱 스무디"
}
