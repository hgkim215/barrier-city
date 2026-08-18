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

        let barBounds = barTable.visualBounds(relativeTo: barTable)
        let anchor = Entity()
        anchor.name = "BarTableServingAnchor"
        anchor.position = RainbowSmoothiePlacement.counterPosition(
            minimum: barBounds.min,
            maximum: barBounds.max)
        barTable.addChild(anchor)

        let authoredBounds = smoothie.visualBounds(relativeTo: smoothie)
        let scale = RainbowSmoothiePlacement.uniformScale(
            assetHeight: authoredBounds.extents.y)
        smoothie.scale = SIMD3(repeating: scale)
        anchor.addChild(smoothie)
        let scaledBounds = smoothie.visualBounds(relativeTo: anchor)
        smoothie.position.y -= scaledBounds.min.y
        smoothie.isEnabled = false

        servingAnchor = anchor
        smoothieEntity = smoothie
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
