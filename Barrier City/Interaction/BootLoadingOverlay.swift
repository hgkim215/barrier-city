import RealityKit
import SwiftUI
import UIKit

/// 몰입 공간 진입 직후, Outdoor 표시 + Indoor/Realtime 프리로드가 끝날 때까지 화면을
/// 어둡게 가리고 안내 문구를 띄운다. SceneFadeOverlay와 같은 head-anchor 기법을 쓰되,
/// 씬 전환용 짧은 페이드가 아니라 로딩 중 계속 떠 있는 화면이라 반경을 더 넉넉히 두고
/// 텍스트를 눈앞 편한 거리에 별도로 배치한다.
@MainActor
final class BootLoadingOverlay {
    static let shared = BootLoadingOverlay()

    private enum Tuning {
        static let radius: Float = 3.0
        static let textDistance: Float = -1.4
    }

    private var anchor: Entity?

    private init() {}

    /// ImmersiveView의 RealityView make 클로저 맨 앞에서 한 번 호출한다.
    func install(content: RealityViewContent, textAttachment: Entity?) {
        let anchor = AnchorEntity(.head)
        anchor.name = "BootLoadingOverlay"

        let mesh = MeshResource.generateSphere(radius: Tuning.radius)
        var material = UnlitMaterial(color: .black)
        material.faceCulling = .front   // 시야가 구 안쪽에 있으므로 안쪽 면을 렌더링한다.
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        anchor.addChild(sphere)

        if let textAttachment {
            textAttachment.setPosition([0, 0, Tuning.textDistance], relativeTo: anchor)
            anchor.addChild(textAttachment)
        }

        content.add(anchor)
        self.anchor = anchor
    }

    /// 모든 프리로드가 끝나면 호출해 화면을 걷어낸다.
    func remove() {
        anchor?.removeFromParent()
        anchor = nil
    }
}
