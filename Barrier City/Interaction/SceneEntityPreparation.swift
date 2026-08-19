import RealityKit

/// 작성된 장면을 시각용 엔티티와 고정 충돌용 엔티티로 분리한다.
/// 시각용 엔티티의 authored material은 건드리지 않는다.
@MainActor
enum SceneEntityPreparation {
    static func prepareVisible(_ entity: Entity) {
        removePhysics(from: entity)
        hideCollisionGeometry(in: entity)
    }

    @discardableResult
    static func prepareCollision(
        _ entity: Entity,
        includeSceneGeometry: Bool = false
    ) async -> Int {
        removePhysics(from: entity)
        let shapeCount = await addStaticCollision(
            to: entity,
            includeSceneGeometry: includeSceneGeometry)
        removeRendering(from: entity)
        return shapeCount
    }

    /// authored Collision/Cube_1의 실제 월드축 바닥 범위와 높이를 보존한다.
    /// 스폰과 접지 fallback이 씬 에셋과 동일한 좌표를 사용하게 한다.
    static func groundLayout(in entity: Entity) -> SceneGroundLayout? {
        guard let collisionRoot = entity.findEntity(named: "Collision"),
              let ground = collisionRoot.findEntity(named: "Cube_1") else { return nil }
        let bounds = ground.visualBounds(relativeTo: entity)
        guard bounds.max.x > bounds.min.x, bounds.max.z > bounds.min.z else { return nil }
        return SceneGroundLayout(
            minimum: SIMD2(bounds.min.x, bounds.min.z),
            maximum: SIMD2(bounds.max.x, bounds.max.z),
            height: bounds.max.y)
    }

    /// authored ground mesh 변환이 실패해도 접지가 사라지지 않도록 같은 bounds의 얇은
    /// 런타임 바닥을 만든다. 경사로와 계단은 더 높은 실제 메시가 먼저 raycast된다.
    static func makeGroundFallback(_ layout: SceneGroundLayout) -> Entity {
        let thickness: Float = 0.1
        let shape = ShapeResource.generateBox(
            width: layout.size.x,
            height: thickness,
            depth: layout.size.y)
        let ground = Entity()
        ground.name = "authoredGroundFallback"
        ground.position = [layout.center.x, layout.height - thickness * 0.5, layout.center.y]
        var collision = CollisionComponent(shapes: [shape])
        collision.filter = CollisionFilter(group: AppModel.groundGroup, mask: .all)
        ground.components.set(collision)
        return ground
    }

    /// 기본은 authored collision 트리만 사용하고, Outdoor에서는 보이는 지형까지 포함한다.
    private static func addStaticCollision(
        to entity: Entity,
        includeSceneGeometry: Bool,
        inherited: Bool = false
    ) async -> Int {
        let isCollider = inherited || entity.name.lowercased().contains("collision")
        var count = 0
        if (isCollider || includeSceneGeometry),
           let model = entity.components[ModelComponent.self],
           let shape = try? await ShapeResource.generateStaticMesh(from: model.mesh) {
            var collision = CollisionComponent(shapes: [shape])
            collision.filter = CollisionFilter(group: AppModel.groundGroup, mask: .all)
            entity.components.set(collision)
            count += 1
        }
        for child in entity.children {
            count += await addStaticCollision(
                to: child,
                includeSceneGeometry: includeSceneGeometry,
                inherited: isCollider)
        }
        return count
    }

    /// 물리와 충돌은 런타임에서 일관되게 다시 구성한다.
    private static func removePhysics(from entity: Entity) {
        entity.components.remove(PhysicsBodyComponent.self)
        entity.components.remove(PhysicsMotionComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            removePhysics(from: child)
        }
    }

    /// 시각 장면에서는 authored collision 프록시의 메시만 숨긴다.
    private static func hideCollisionGeometry(
        in entity: Entity,
        inherited: Bool = false
    ) {
        let isCollider = inherited || entity.name.lowercased().contains("collision")
        if isCollider {
            entity.components.remove(ModelComponent.self)
        }
        for child in entity.children {
            hideCollisionGeometry(in: child, inherited: isCollider)
        }
    }

    /// 충돌 사본에서는 렌더 컴포넌트만 제거해 transform과 충돌 형상을 보존한다.
    private static func removeRendering(from entity: Entity) {
        entity.components.remove(ModelComponent.self)
        for child in entity.children {
            removeRendering(from: child)
        }
    }
}
