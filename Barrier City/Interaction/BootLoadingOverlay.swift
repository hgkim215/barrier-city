import RealityKit
import SwiftUI

/// 몰입 공간 진입 직후, Outdoor 표시 + Indoor/Realtime 프리로드가 끝날 때까지 화면을
/// 검은 구체로 가린다. SceneFadeOverlay와 같은 head-anchor 기법을 쓰되, 씬 전환용
/// 짧은 페이드가 아니라 로딩 중 계속 떠 있는 화면이라 반경을 더 넉넉히 둔다.
///
/// 스플래시 이미지(Splash_1/2)는 더 이상 여기서 그리지 않는다 — RealityKit 평면 +
/// 텍스처로 그렸을 때 투명 배경/블렌딩 처리 때문에 실기에서 안 보이는 문제를 겪은
/// 뒤, 볼륨 윈도우(SplashOverlayView, "splash" WindowGroup)로 옮겨 SwiftUI Image가
/// 투명 PNG를 있는 그대로 그리게 했다. 그 창의 열기/닫기는 ControlPanelView(연
/// 시점)와 ImmersiveView(닫는 시점)가 맡는다.
@MainActor
final class BootLoadingOverlay {
    static let shared = BootLoadingOverlay()

    private enum Tuning {
        static let radius: Float = 3.0
    }

    private var anchor: Entity?

    private init() {}

    /// ImmersiveView의 RealityView make 클로저 맨 앞에서 한 번 호출한다.
    func install(content: RealityViewContent) {
        // 빠른 재진입이나 RealityView 재생성에도 이전 anchor가 남지 않게 한다.
        remove()

        let anchor = AnchorEntity(.head)
        anchor.name = "BootLoadingOverlay"

        let sphereMesh = MeshResource.generateSphere(radius: Tuning.radius)
        var sphereMaterial = UnlitMaterial(color: .black)
        sphereMaterial.faceCulling = .front   // 시야가 구 안쪽에 있으므로 안쪽 면을 렌더링한다.
        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        anchor.addChild(sphere)

        content.add(anchor)
        self.anchor = anchor
    }

    /// 모든 프리로드가 끝나면 호출해 화면을 걷어낸다.
    func remove() {
        anchor?.removeFromParent()
        anchor = nil
    }
}
