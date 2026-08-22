import RealityKit
import SwiftUI
import UIKit

/// 실외↔실내처럼 애셋 준비 시간이 필요한 장면 전환을 화면 fade로 자연스럽게 가린다.
/// AnchorEntity(.head)로 시야에 고정해, worldRoot 이동/회전과 무관하게 항상 전체 시야를 덮는다.
@MainActor
final class SceneFadeOverlay {
    static let shared = SceneFadeOverlay()

    private enum Tuning {
        static let radius: Float = 0.3
        /// 초당 opacity 변화량(1/rate ≈ 페이드 소요 시간).
        static let rate: Float = 3.0
    }

    private var overlay: Entity?
    private var opacity: Float = 0
    private var targetOpacity: Float = 0

    private init() {}

    /// InteractionSetup.install()에서 매 진입마다 호출. 이전 세션의 엔티티는 이미
    /// content와 함께 사라졌으므로 항상 새로 만든다.
    func install(content: RealityViewContent) {
        let mesh = MeshResource.generateSphere(radius: Tuning.radius)
        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .front   // 시야가 구 안쪽에 있으므로 안쪽 면을 렌더링한다.
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        sphere.name = "SceneFadeOverlay"
        sphere.components.set(OpacityComponent(opacity: 0))

        let anchor = AnchorEntity(.head)
        anchor.addChild(sphere)
        content.add(anchor)

        overlay = sphere
        opacity = 0
        targetOpacity = 0
    }

    func fadeOut() { targetOpacity = 1 }
    func fadeIn() { targetOpacity = 0 }

    /// InteractionSetup.tick()에서 매 프레임 호출.
    func update(deltaTime: Float) {
        guard let overlay, abs(opacity - targetOpacity) > 0.001 else { return }
        let step = Tuning.rate * deltaTime
        opacity += targetOpacity > opacity
            ? min(step, targetOpacity - opacity)
            : -min(step, opacity - targetOpacity)
        overlay.components.set(OpacityComponent(opacity: opacity))
    }
}
