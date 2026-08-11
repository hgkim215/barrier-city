import RealityKit
import simd

enum KioskScreenPlacement {
    case attached(plane: Entity, halfSize: SIMD2<Float>)
    case billboardFallback
}

enum KioskScreenTuning {
    static let fill: Float = 0.98
    static let surfaceOffset: Float = 0.002
    static let faceRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
}

@MainActor
enum KioskScreenPresenter {
    static func install(
        attachment: Entity,
        in indoor: Entity,
        worldRoot: Entity
    ) -> KioskScreenPlacement {
        guard let screen = indoor.findEntity(named: "Screen"),
              let plane = screen.findEntity(named: "Plane") else {
            print("⚠️ Indoor Screen/Plane을 찾지 못해 키오스크 빌보드 사용")
            return installBillboardFallback(attachment, in: worldRoot)
        }

        attachment.scale = .one
        attachment.orientation = KioskScreenTuning.faceRotation

        let planeBounds = plane.visualBounds(relativeTo: plane)
        let attachmentBounds = attachment.visualBounds(relativeTo: attachment)
        let planeSize = SIMD2<Float>(planeBounds.extents.x, planeBounds.extents.y)
        let attachmentSize = SIMD2<Float>(attachmentBounds.extents.x, attachmentBounds.extents.y)

        guard let scale = KioskScreenLayout.uniformScale(
            planeSize: planeSize,
            attachmentSize: attachmentSize,
            fill: KioskScreenTuning.fill) else {
            print("⚠️ Screen/attachment bounds가 유효하지 않아 키오스크 빌보드 사용")
            return installBillboardFallback(attachment, in: worldRoot)
        }

        attachment.removeFromParent()
        plane.addChild(attachment)
        attachment.scale = SIMD3<Float>(repeating: scale)
        attachment.orientation = KioskScreenTuning.faceRotation
        attachment.position = SIMD3<Float>(
            planeBounds.center.x,
            planeBounds.center.y,
            planeBounds.max.z + KioskScreenTuning.surfaceOffset)
        attachment.isEnabled = true

        print("키오스크 Screen UI 배치 완료: plane=\(planeSize), scale=\(scale)")
        return .attached(plane: plane, halfSize: planeSize * 0.5)
    }

    private static func installBillboardFallback(
        _ attachment: Entity,
        in worldRoot: Entity
    ) -> KioskScreenPlacement {
        attachment.removeFromParent()
        worldRoot.addChild(attachment)
        attachment.scale = .one
        attachment.orientation = .init()
        attachment.isEnabled = false
        return .billboardFallback
    }
}
