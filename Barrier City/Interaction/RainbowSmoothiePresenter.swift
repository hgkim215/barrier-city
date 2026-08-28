import RealityKit

@MainActor
final class RainbowSmoothiePresenter: RainbowSmoothiePresenting {
    private(set) var smoothieEntity: Entity?
    private var servingAnchor: Entity?
    private var authoredOrientation: simd_quatf = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

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
        authoredOrientation = smoothie.orientation

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

        setupInteractivity(for: smoothie)

        return true
    }

    private func setupInteractivity(for smoothie: Entity) {
        smoothie.generateCollisionShapes(recursive: true)

        let localBounds = smoothie.visualBounds(relativeTo: smoothie)
        if RainbowSmoothiePlacement.hasFiniteOrderedBounds(minimum: localBounds.min, maximum: localBounds.max) {
            let boxShape = ShapeResource.generateBox(
                size: SIMD3<Float>(localBounds.extents.x * 1.4, localBounds.extents.y * 1.4, localBounds.extents.z * 1.4)
            ).offsetBy(translation: localBounds.center)
            smoothie.components.set(CollisionComponent(shapes: [boxShape], isStatic: true))
        }

        func applyInputTargetRecursively(_ e: Entity) {
            e.components.set(InputTargetComponent(allowedInputTypes: .all))
            e.components.set(HoverEffectComponent())
            for child in e.children {
                applyInputTargetRecursively(child)
            }
        }
        applyInputTargetRecursively(smoothie)
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

        // 손에 든 뒤에는 더 이상 장애물도, 탭 대상도 아니다.
        //
        // setupInteractivity가 붙여둔 콜리전 박스는 시각 크기의 1.4배라 휠체어
        // 바로 앞에서 주행용 벽 광선(WheelchairMovementSystem.wallRayY)에 걸린다.
        // 그러면 매 프레임 stopAtObstacle이 좌우 바퀴 속도를 0으로 만들어
        // 휠체어가 기어가듯 움직인다. 수령이 끝났으니 상호작용 컴포넌트도 함께 뗀다.
        Self.stripInteraction(from: smoothieEntity)

        smoothieEntity.removeFromParent()
        smoothieEntity.position = .zero
        smoothieEntity.orientation = authoredOrientation
        lapAnchor.addChild(smoothieEntity)
        smoothieEntity.isEnabled = true

        return true
    }

    private static func stripInteraction(from entity: Entity) {
        entity.components.remove(CollisionComponent.self)
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(HoverEffectComponent.self)
        entity.components.remove(PhysicsBodyComponent.self)
        for child in entity.children {
            stripInteraction(from: child)
        }
    }

    func reset() {
        smoothieEntity?.removeFromParent()
        servingAnchor?.removeFromParent()
        smoothieEntity = nil
        servingAnchor = nil
    }
}
