import Foundation
import RealityKit
import simd

/// 회전된 사각형 영역(월드 XZ 평면). AreaK 계산(NPCClerkController)과 동일한 축-투영
/// 방식으로, 배회 가능 영역과 "제외" 영역(AreaK/AreaB) 판정에 함께 쓴다.
struct NPCGuestArea {
    let center: SIMD2<Float>
    let axisU: SIMD2<Float>
    let axisV: SIMD2<Float>

    func point(u: Float, v: Float) -> SIMD2<Float> {
        center + axisU * u + axisV * v
    }

    /// point가 이 사각형(평행사변형) 내부에 있는지 판정한다.
    func contains(_ point: SIMD2<Float>) -> Bool {
        let offset = point - center
        let determinant = axisU.x * axisV.y - axisU.y * axisV.x
        guard abs(determinant) > 0.000001 else { return false }
        let u = (offset.x * axisV.y - offset.y * axisV.x) / determinant
        let v = (axisU.x * offset.y - axisU.y * offset.x) / determinant
        return abs(u) <= 1 && abs(v) <= 1
    }
}

/// 손님 NPC 6명(female 3 + male 3)을 관리한다. 매 프레임 각자 자유롭게 배회시키고,
/// 유저가 키오스크에 접근하면 그중 랜덤 2명을 유저 뒤에 줄 세운다.
///
/// NPCClerkController(대화 상대 1명)와 책임을 분리했다: 이쪽은 대화·근접 감지 없이
/// 순수하게 다수 NPC의 동선만 담당한다.
@MainActor
final class NPCGuestCoordinator {
    private enum Tuning {
        /// _floor 바깥쪽(벽)에 붙어 걷지 않도록 배회 영역에 두는 여백.
        static let floorMargin: Float = 0.5
        /// 대기줄 앞뒤 간격(m).
        static let queueSpacing: Float = 0.85
        /// 스폰 시 손님끼리 서로 떨어뜨리려는 최소 거리(m).
        static let minimumSpawnSeparation: Float = 2.0
    }

    /// Indoor.usda에는 성별당 원본 엔티티가 하나씩만 있다("Female", "MaleIdle").
    /// 손님 6명은 코드에서 entity.clone(recursive:)로 이 원본을 복제해 만든다 —
    /// usda에 직접 6개의 중복 def 블록을 추가하는 대신 단일 소스를 유지한다.
    /// 콜리전은 원본 authoring과 무관하게 place()에서 매번 코드로 부여한다
    /// (Entity.applyNPCBodyCollision 참고).
    private struct GenderGroup {
        let templateName: String
        let displayNames: [String]
    }

    private static let genderGroups: [GenderGroup] = [
        GenderGroup(templateName: "Female", displayNames: ["Guest_Female_1", "Guest_Female_2", "Guest_Female_3"]),
        GenderGroup(templateName: "MaleIdle", displayNames: ["Guest_Male_1", "Guest_Male_2", "Guest_Male_3"]),
    ]

    private var guests: [NPCGuestController] = []
    private var floorArea: NPCGuestArea?
    private var exclusionAreas: [NPCGuestArea] = []
    private var queuerIndices: Set<Int> = []
    private var wasOrdering = false

    /// Indoor 진입 시 손님 엔티티를 찾아 배치하고, "_floor"에서 배회 영역을,
    /// "AreaK"/"AreaB"에서 제외 영역을 계산한다.
    func enterIndoor(worldRoot: Entity, indoorMap: Entity) {
        tearDownForOutdoor()

        floorArea = resolveArea(named: "_floor", in: indoorMap, relativeTo: worldRoot, margin: Tuning.floorMargin)
        exclusionAreas = ["AreaK", "AreaB"].compactMap {
            resolveArea(named: $0, in: indoorMap, relativeTo: worldRoot, margin: 0)
        }
        guard let floorArea else { return }

        var spawnedPositions: [SIMD2<Float>] = []
        for group in Self.genderGroups {
            guard let template = indoorMap.findEntity(named: group.templateName) else { continue }
            for (index, displayName) in group.displayNames.enumerated() {
                // 첫 번째 손님은 원본 엔티티를 그대로 쓰고(place()가 removeFromParent로
                // 떼어간다), 나머지는 원본을 복제한다. 복제를 먼저 해야 원본이 아직
                // indoorMap에 붙어 있어 clone()이 콜리전을 포함한 컴포넌트를 그대로 상속한다.
                let entity = index == 0 ? template : template.clone(recursive: true)
                entity.name = displayName
                let guest = NPCGuestController(name: displayName)
                let spawn = randomSpawnPoint(in: floorArea, excluding: exclusionAreas, keepingAwayFrom: spawnedPositions)
                spawnedPositions.append(spawn)
                guest.place(entity: entity, worldRoot: worldRoot, at: spawn)
                guests.append(guest)
            }
        }
    }

    /// 제외 영역을 피하고, 이미 배치된 손님들과도 최소 거리를 두는 스폰 지점을 고른다.
    /// 못 찾으면(공간이 좁으면) 그나마 가장 멀리 떨어진 후보로 절충한다.
    private func randomSpawnPoint(in area: NPCGuestArea,
                                  excluding exclusions: [NPCGuestArea],
                                  keepingAwayFrom others: [SIMD2<Float>]) -> SIMD2<Float> {
        var bestCandidate = area.center
        var bestSeparation: Float = -1
        for _ in 0..<20 {
            let candidate = area.point(u: Float.random(in: -1...1), v: Float.random(in: -1...1))
            if exclusions.contains(where: { $0.contains(candidate) }) { continue }
            let separation = others.map { simd_distance($0, candidate) }.min() ?? .greatestFiniteMagnitude
            if separation >= Tuning.minimumSpawnSeparation { return candidate }
            if separation > bestSeparation {
                bestSeparation = separation
                bestCandidate = candidate
            }
        }
        return bestCandidate
    }

    func tearDownForOutdoor() {
        for guest in guests { guest.teardown() }
        guests.removeAll()
        floorArea = nil
        exclusionAreas.removeAll()
        queuerIndices.removeAll()
        wasOrdering = false
    }

    /// - Parameters:
    ///   - isOrdering: 유저가 키오스크 트리거 반경 안에 있는지(= 주문 중으로 간주).
    ///   - kioskCenter: 키오스크 중심 맵 좌표. isOrdering이 true일 때만 유효.
    func update(deltaTime: Float, appModel: AppModel, isOrdering: Bool, kioskCenter: SIMD2<Float>?) {
        guard let floorArea else { return }

        if isOrdering, !wasOrdering {
            queuerIndices = Set(guests.indices.shuffled().prefix(min(2, guests.count)))
        }
        if !isOrdering {
            queuerIndices.removeAll()
        }
        wasOrdering = isOrdering

        let playerPosition = SIMD2(appModel.motion.positionX, appModel.motion.positionZ)
        let orderedQueuers = queuerIndices.sorted()
        // 프레임 시작 시 스냅샷을 만들어 업데이트 순서에 따라 뒤쪽 NPC만 더 강하게
        // 반응하는 편향을 없앤다.
        let positions = guests.map(\.currentPosition)
        let anchors = guests.map(\.crowdAnchor)

        for (index, guest) in guests.enumerated() {
            var slot: SIMD2<Float>?
            var facing: SIMD2<Float>?
            if isOrdering, let kioskCenter, let rank = orderedQueuers.firstIndex(of: index) {
                slot = queueSlot(kioskCenter: kioskCenter, playerPosition: playerPosition, rank: rank + 1)
                facing = kioskCenter
            }
            let neighboringPositions = positions.enumerated().compactMap {
                $0.offset == index ? nil : $0.element
            }
            let occupiedAnchors = anchors.enumerated().compactMap {
                $0.offset == index ? nil : $0.element
            }
            guest.update(deltaTime: deltaTime,
                        wanderArea: floorArea,
                        exclusions: exclusionAreas,
                        queueSlot: slot,
                        facing: facing,
                        playerPosition: playerPosition,
                        neighboringPositions: neighboringPositions,
                        occupiedAnchors: occupiedAnchors)
        }
    }

    /// 키오스크→유저 방향을 그대로 연장해 유저 뒤로 줄을 세운다.
    private func queueSlot(kioskCenter: SIMD2<Float>, playerPosition: SIMD2<Float>, rank: Int) -> SIMD2<Float> {
        var direction = playerPosition - kioskCenter
        if simd_length(direction) < 0.001 { direction = SIMD2(0, 1) }
        let normalized = simd_normalize(direction)
        return playerPosition + normalized * (Tuning.queueSpacing * Float(rank))
    }

    /// AreaK 계산(NPCClerkController.makeWorkArea)과 동일하게, authored marker의 회전·
    /// 비균일 스케일을 유지한 채 월드 XZ에 가장 크게 투영되는 두 축을 골라낸다.
    private func resolveArea(named entityName: String,
                             in indoorMap: Entity,
                             relativeTo worldRoot: Entity,
                             margin: Float) -> NPCGuestArea? {
        guard let area = indoorMap.findEntity(named: entityName) else { return nil }
        let bounds = area.visualBounds(relativeTo: area)
        let localCenter = bounds.center
        let halfExtents = (bounds.max - bounds.min) * 0.5
        let worldCenter3 = area.convert(position: localCenter, to: worldRoot)
        let worldCenter = SIMD2<Float>(worldCenter3.x, worldCenter3.z)
        let localAxes = [
            SIMD3<Float>(halfExtents.x, 0, 0),
            SIMD3<Float>(0, halfExtents.y, 0),
            SIMD3<Float>(0, 0, halfExtents.z),
        ]
        let projected = localAxes.map { localAxis -> SIMD2<Float> in
            let endpoint = area.convert(position: localCenter + localAxis, to: worldRoot)
            return SIMD2(endpoint.x - worldCenter.x, endpoint.z - worldCenter.y)
        }.sorted { simd_length_squared($0) > simd_length_squared($1) }

        guard projected.count >= 2,
              simd_length(projected[0]) > 0.001,
              simd_length(projected[1]) > 0.001 else { return nil }

        func inset(_ axis: SIMD2<Float>) -> SIMD2<Float> {
            let length = simd_length(axis)
            let usableLength = max(0.01, length - margin)
            return axis * (usableLength / length)
        }
        return NPCGuestArea(center: worldCenter, axisU: inset(projected[0]), axisV: inset(projected[1]))
    }
}
