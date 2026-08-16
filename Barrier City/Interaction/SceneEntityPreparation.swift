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
    static func prepareCollision(_ entity: Entity) async -> Int {
        removePhysics(from: entity)
        let shapeCount = await addStaticCollision(to: entity)
        removeRendering(from: entity)
        return shapeCount
    }

    /// 이름에 "collision"이 들어간 엔티티와 하위 메시만 고정 충돌로 변환한다.
    private static func addStaticCollision(
        to entity: Entity,
        inherited: Bool = false
    ) async -> Int {
        let isCollider = inherited || entity.name.lowercased().contains("collision")
        var count = 0
        if isCollider,
           let model = entity.components[ModelComponent.self],
           let shape = try? await ShapeResource.generateStaticMesh(from: model.mesh) {
            var collision = CollisionComponent(shapes: [shape])
            collision.filter = CollisionFilter(group: AppModel.groundGroup, mask: .all)
            entity.components.set(collision)
            count += 1
        }
        for child in entity.children {
            count += await addStaticCollision(to: child, inherited: isCollider)
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
