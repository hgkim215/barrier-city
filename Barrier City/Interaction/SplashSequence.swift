import Foundation

/// 부팅 스플래시의 리소스 순서와 표시 시간을 한곳에서 정의한다.
/// 렌더러와 회귀 테스트가 같은 계약을 사용해 둘 사이의 값이 어긋나지 않게 한다.
enum SplashSequence {
    static let resourceNames = ["Splash_1", "Splash_2"]
    static let frameDuration: Duration = .milliseconds(500)

    static func resourceName(atFrame frame: Int) -> String? {
        guard frame >= 0, !resourceNames.isEmpty else { return nil }
        return resourceNames[frame % resourceNames.count]
    }
}
