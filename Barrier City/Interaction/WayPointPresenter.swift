import RealityKit
import Foundation

@MainActor
final class WayPointPresenter {
    private(set) var waypointEntity: Entity?
    private var highlightTask: Task<Void, Never>?

    /// 지정 좌석 목적지 좌표 (Indoor 맵 좌표계)
    static let destinationPosition = SIMD3<Float>(1.5, 0.02, -0.8)
    /// 도착 판정 반경 (미터)
    static let arrivalRadius: Float = 1.2
    /// WayPoint 기본 스케일
    static let baseScale: Float = 0.12

    var isInstalled: Bool {
        waypointEntity != nil && waypointEntity?.parent != nil
    }

    @discardableResult
    func install(waypoint: Entity?, in indoorMap: Entity) -> Bool {
        reset()
        guard let waypoint else { return false }

        waypoint.scale = SIMD3(repeating: Self.baseScale)
        waypoint.position = Self.destinationPosition
        waypoint.isEnabled = false
        indoorMap.addChild(waypoint)
        waypointEntity = waypoint
        return true
    }

    /// 미션 6 시작 시 1.5초간 펄스/바운스 강조 연출 후 바닥 마커로 유지
    func showWithHighlight() {
        guard let waypointEntity else { return }
        highlightTask?.cancel()
        waypointEntity.isEnabled = true

        highlightTask = Task { @MainActor [weak self] in
            guard let self, let entity = self.waypointEntity else { return }
            let base = Self.baseScale
            for step in 0..<15 {
                let progress = Float(step) / 15.0
                let pulse = base * (1.0 + 0.35 * sin(progress * .pi))
                entity.scale = SIMD3(repeating: pulse)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            entity.scale = SIMD3(repeating: base)
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
        waypointEntity?.removeFromParent()
        waypointEntity = nil
    }
}
