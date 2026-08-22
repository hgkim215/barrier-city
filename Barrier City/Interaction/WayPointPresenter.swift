import RealityKit
import Foundation

@MainActor
final class WayPointPresenter {
    private(set) var waypointEntity: Entity?
    private(set) var destinationPosition: SIMD3<Float> = SIMD3<Float>(6.524, 0.02, 4.264)
    private var highlightTask: Task<Void, Never>?
    private var baseScale: SIMD3<Float> = SIMD3<Float>(0.2, 0.2, 0.4)

    /// 도착 판정 반경 (1.24m 직경 비콘 마커 기준 자연스러운 휠체어 진입 허용 반경: 1.0m)
    var arrivalRadius: Float = 1.0

    var isInstalled: Bool {
        waypointEntity != nil && waypointEntity?.parent != nil
    }

    @discardableResult
    func install(in indoorMap: Entity) -> Bool {
        reset()
        guard let waypoint = indoorMap.findEntity(named: "WayPoint") else {
            return false
        }

        let bounds = waypoint.visualBounds(relativeTo: indoorMap)
        destinationPosition = SIMD3<Float>(bounds.center.x, bounds.min.y, bounds.center.z)
        baseScale = waypoint.scale
        waypoint.isEnabled = false
        waypointEntity = waypoint
        return true
    }

    /// 테스트용 호환 install 메소드
    @discardableResult
    func install(waypoint: Entity?, in indoorMap: Entity) -> Bool {
        if let waypoint, waypoint.parent !== indoorMap {
            indoorMap.addChild(waypoint)
        }
        return install(in: indoorMap)
    }

    /// 미션 6 시작 시 1.5초간 펄스/바운스 강조 연출 후 바닥 마커로 유지
    func showWithHighlight() {
        guard let waypointEntity else { return }
        highlightTask?.cancel()
        waypointEntity.isEnabled = true

        highlightTask = Task { @MainActor [weak self] in
            guard let self, let entity = self.waypointEntity else { return }
            let base = self.baseScale
            for step in 0..<15 {
                let progress = Float(step) / 15.0
                let pulse = 1.0 + 0.35 * sin(progress * .pi)
                entity.scale = base * pulse
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            entity.scale = base
            self.highlightTask = nil
        }
    }

    func hide() {
        highlightTask?.cancel()
        highlightTask = nil
        waypointEntity?.isEnabled = false
    }

    func reset() {
        highlightTask?.cancel()
        highlightTask = nil
        waypointEntity = nil
    }
}
