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

        return true
    }

    func revealAtCounter() -> Bool {
        guard isInstalled, let smoothieEntity else { return false }
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
