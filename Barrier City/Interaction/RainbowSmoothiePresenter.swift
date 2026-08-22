import RealityKit

@MainActor
final class RainbowSmoothiePresenter: RainbowSmoothiePresenting {
    private(set) var smoothieEntity: Entity?
    private var servingAnchor: Entity?

    var isInstalled: Bool {
        smoothieEntity != nil && servingAnchor?.parent != nil
    }

    @discardableResult
    func install(smoothie: Entity?, in indoorMap: Entity) -> Bool {
        reset()
        guard let smoothie,
              let barTable = indoorMap.findEntity(named: ImmersiveSceneCatalog.barTable) else {
            return false
        }

        let barBounds = barTable.visualBounds(relativeTo: indoorMap)
        let posEntity = indoorMap.findEntity(named: "Payment")
        let showcaseEntity = indoorMap.findEntity(named: "Showcase_1") ?? indoorMap.findEntity(named: "Showcase")
        let posBounds = posEntity.map { $0.visualBounds(relativeTo: indoorMap) }
        let showcaseBounds = showcaseEntity.map { $0.visualBounds(relativeTo: indoorMap) }

        guard let anchorPosition = RainbowSmoothiePlacement.counterPosition(
            barMinimum: barBounds.min,
            barMaximum: barBounds.max,
            posBounds: posBounds.map { (min: $0.min, max: $0.max) },
            showcaseBounds: showcaseBounds.map { (min: $0.min, max: $0.max) }) else {
            return false
        }
        let anchor = Entity()
        anchor.name = "BarTableServingAnchor"
        barTable.addChild(anchor)
        anchor.setTransformMatrix(matrix_identity_float4x4, relativeTo: indoorMap)
        anchor.setPosition(anchorPosition, relativeTo: indoorMap)

        smoothie.isEnabled = false
        anchor.addChild(smoothie)
        servingAnchor = anchor
        smoothieEntity = smoothie

        let authoredBounds = smoothie.visualBounds(relativeTo: indoorMap)
        guard RainbowSmoothiePlacement.hasFiniteOrderedBounds(
            minimum: authoredBounds.min,
            maximum: authoredBounds.max) else {
            reset()
            return false
        }
        let scale = RainbowSmoothiePlacement.uniformScale(
            assetHeight: authoredBounds.extents.y)
        smoothie.scale *= SIMD3(repeating: scale)

        let scaledBounds = smoothie.visualBounds(relativeTo: indoorMap)
        guard RainbowSmoothiePlacement.hasFiniteOrderedBounds(
            minimum: scaledBounds.min,
            maximum: scaledBounds.max) else {
            reset()
            return false
        }
        var smoothiePosition = smoothie.position(relativeTo: indoorMap)
        smoothiePosition.y += anchorPosition.y - scaledBounds.min.y
        smoothie.setPosition(smoothiePosition, relativeTo: indoorMap)

        // 탭 인터랙션을 위한 충돌체 및 인풋 타깃 설정
        let collisionShape = ShapeResource.generateBox(
            size: SIMD3<Float>(0.35, 0.45, 0.35)
        )
        smoothie.components.set(CollisionComponent(shapes: [collisionShape]))
        smoothie.components.set(InputTargetComponent(allowedInputTypes: .all))

        return true
    }

    func revealAtCounter() -> Bool {
        guard isInstalled, let smoothieEntity else { return false }
        smoothieEntity.isEnabled = true
        return true
    }

    /// 사용자가 카운터의 쟁반/스무디를 탭했을 때 휠체어 무릎 앞쪽 트레이로 리페어런팅
    @discardableResult
    func pickupToWheelchair(wheelchair: Entity) -> Bool {
        guard let smoothieEntity else { return false }

        let lapAnchor: Entity
        if let existing = wheelchair.findEntity(named: "WheelchairTrayAnchor") {
            lapAnchor = existing
        } else {
            let anchor = Entity()
            anchor.name = "WheelchairTrayAnchor"
            wheelchair.addChild(anchor)
            anchor.position = ServingPlacementTuning.wheelchairTrayPosition
            anchor.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            lapAnchor = anchor
        }

        smoothieEntity.removeFromParent()
        smoothieEntity.position = .zero
        smoothieEntity.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        lapAnchor.addChild(smoothieEntity)
        smoothieEntity.isEnabled = true

        return true
    }

    func reset() {
        smoothieEntity?.removeFromParent()
        servingAnchor?.removeFromParent()
        smoothieEntity = nil
        servingAnchor = nil
    }
}
