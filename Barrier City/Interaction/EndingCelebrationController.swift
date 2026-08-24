import RealityKit

@MainActor
final class EndingCelebrationController {
    private var emitter: Entity?
    private weak var hudPanel: Entity?
    private var playbackState = ExperienceCelebrationState()

    /// 파티클을 퀘스트 HUD와 같은 좌표계에 둬 엔딩 팝업을 따라다니게 한다.
    func attach(to hudPanel: Entity) {
        self.hudPanel = hudPanel
        placeEmitterIfReady()
    }

    @discardableResult
    func install(in indoorMap: Entity) -> Bool {
        stop()
        emitter?.removeFromParent()
        emitter = nil
        guard let emitter = indoorMap.findEntity(named: "ParticleEmitter") else {
            return false
        }
        emitter.isEnabled = false
        self.emitter = emitter
        placeEmitterIfReady()
        return true
    }

    /// Indoor 에셋의 반복 설정을 그대로 사용해 확인 버튼을 누를 때까지 재생한다.
    func playUntilStopped() {
        guard let emitter,
              playbackState.begin() != nil else { return }

        placeEmitterIfReady()
        emitter.isEnabled = true
    }

    func stop() {
        emitter?.isEnabled = false
        playbackState.stop()
    }

    func reset() {
        stop()
        emitter?.removeFromParent()
        emitter = nil
        hudPanel = nil
        playbackState.reset()
    }

    private func placeEmitterIfReady() {
        guard let emitter, let hudPanel else { return }
        if emitter.parent !== hudPanel {
            emitter.removeFromParent()
            hudPanel.addChild(emitter)
        }

        // 900 x 716 pt 팝업보다 조금 넓은 방출 평면을 패널 뒤에 둔다.
        // 중앙 입자는 불투명 패널에 가려지고 가장자리 바깥 입자만 보인다.
        emitter.position = SIMD3<Float>(0, 0, -0.06)
        emitter.orientation = simd_quatf()
        emitter.scale = SIMD3<Float>(1.08, 0.86, 1)
    }
}
