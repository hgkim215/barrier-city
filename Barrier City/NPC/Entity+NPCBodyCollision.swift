import RealityKit

extension Entity {
    /// Indoor.usda에 RealityKitComponent "Collider"로 authoring된 콜리전은 Entity(named:)로
    /// 개별 서브트리를 불러오는 이 앱의 로딩 경로에서는 런타임에 전혀 반영되지 않는다
    /// (Barista 포함, 진단 로그로 확인됨). 대신 엔티티 자신의 로컬 시각적 바운드로 박스를
    /// 만들어 코드에서 직접 붙인다.
    func applyNPCBodyCollision(group: CollisionGroup) {
        let localBounds = visualBounds(relativeTo: self)
        let shape = ShapeResource.generateBox(size: localBounds.extents)
            .offsetBy(translation: localBounds.center)
        components.set(CollisionComponent(shapes: [shape], mode: .default,
                                          filter: CollisionFilter(group: group, mask: .all)))
    }
}
