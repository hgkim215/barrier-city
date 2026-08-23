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

/// 착석 가능한 좌석 하나. Furnitures 하위의 "SittingPoint" 마커에서 만들어진다.
struct GuestSeat {
    let position: SIMD2<Float>
    /// 착석 시 바라볼 방향(가장 가까운 테이블 쪽). Tripo로 생성된 의자 메시의 로컬
    /// 회전은 신뢰할 수 없어 마커 자신의 authored 회전 대신 이 값을 쓴다.
    let facing: SIMD2<Float>
}

/// 손님 NPC를 관리한다. 매 프레임 각자 자유롭게 배회·착석시키고, 유저가 키오스크에
/// 접근하면 대기줄 후보 중 랜덤 2명을 유저 뒤에 줄 세운다.
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
        /// 항상 배회만 하는 손님 수(대기줄 후보).
        static let wandererCount = 1
        /// 배회↔착석↔기립을 반복하는 손님 수(대기줄 후보).
        static let cyclerCount = 3
        /// 입장 시 가능하면 이미 앉아있는 상태로 시작하는 손님 수(대기줄 제외).
        /// 실제 좌석 수보다 많으면 초과분은 배회로 시작해 빈 좌석이 생기면 자연스럽게
        /// 합류한다.
        static let seatedPoolCount = 4
        /// 테이블·의자 군집 주변을 배회 목적지에서 제외할 때 두는 여백(m).
        static let seatClusterExclusionMargin: Float = 0.9
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

    /// wandererCount + cyclerCount + seatedPoolCount(1+3+4=8)에 맞춘 인원 구성.
    private static let genderGroups: [GenderGroup] = [
        GenderGroup(templateName: "Female", displayNames: ["Guest_Female_1", "Guest_Female_2", "Guest_Female_3", "Guest_Female_4"]),
        GenderGroup(templateName: "MaleIdle", displayNames: ["Guest_Male_1", "Guest_Male_2", "Guest_Male_3", "Guest_Male_4"]),
    ]

    private var guests: [NPCGuestController] = []
    private var floorArea: NPCGuestArea?
    private var exclusionAreas: [NPCGuestArea] = []
    /// Furnitures 하위 "SittingPoint" 마커에서 찾은 좌석. 개수는 씬 authoring에 따라
    /// 달라지며 하드코딩하지 않는다(discoverSeats 참고).
    private var seats: [GuestSeat] = []
    /// seats와 같은 길이. 각 자리를 점유 중인 guests 인덱스, 비어 있으면 nil.
    private var seatOccupants: [Int?] = []
    private var queuerIndices: Set<Int> = []
    private var wasOrdering = false
    /// 줄서기 시작 순간에 고정하는 대기줄 기준선(키오스크 원점 + 방향 + 유저까지의
    /// 거리). 매 프레임 라이브 유저 위치로 다시 계산하면 유저가 트리거 반경 안에서
    /// 조금만 움직여도 줄 전체가 다시 정렬되며 흔들리므로, 시작 시점에만 캡처해
    /// 이후에는 키오스크 기준으로 고정한다.
    private var queueOrigin: SIMD2<Float>?
    private var queueDirection: SIMD2<Float>?
    private var queueBaseDistance: Float = 0

    /// Indoor 진입 시 손님 엔티티를 찾아 배치하고, "_floor"에서 배회 영역을,
    /// "AreaK"/"AreaB"에서 제외 영역을 계산한다. 좌석은 씬을 스캔해 동적으로 찾고,
    /// 손님마다 역할(항상 배회/배회-착석 순환/입장부터 착석 시도)을 무작위로 나눈다.
    func enterIndoor(worldRoot: Entity, indoorMap: Entity) {
        tearDownForOutdoor()

        floorArea = resolveArea(named: "_floor", in: indoorMap, relativeTo: worldRoot, margin: Tuning.floorMargin)
        exclusionAreas = ["AreaK", "AreaB"].compactMap {
            resolveArea(named: $0, in: indoorMap, relativeTo: worldRoot, margin: 0)
        }
        guard let floorArea else { return }

        seats = discoverSeats(in: indoorMap, relativeTo: worldRoot)
        seatOccupants = Array(repeating: nil, count: seats.count)
        if let seatClusterExclusion = makeSeatClusterExclusion(from: seats) {
            exclusionAreas.append(seatClusterExclusion)
        }

        var roles: [NPCGuestRole] = []
        roles += Array(repeating: .alwaysWandering, count: Tuning.wandererCount)
        roles += Array(repeating: .cycler, count: Tuning.cyclerCount)
        roles += Array(repeating: .seatedPool, count: Tuning.seatedPoolCount)
        roles.shuffle()
        var nextRoleIndex = 0

        var spawnedPositions: [SIMD2<Float>] = []
        for group in Self.genderGroups {
            guard let template = indoorMap.findEntity(named: group.templateName) else { continue }
            for (index, displayName) in group.displayNames.enumerated() {
                // 첫 번째 손님은 원본 엔티티를 그대로 쓰고(place()가 removeFromParent로
                // 떼어간다), 나머지는 원본을 복제한다. 복제를 먼저 해야 원본이 아직
                // indoorMap에 붙어 있어 clone()이 콜리전을 포함한 컴포넌트를 그대로 상속한다.
                let entity = index == 0 ? template : template.clone(recursive: true)
                entity.name = displayName
                let role = nextRoleIndex < roles.count ? roles[nextRoleIndex] : .cycler
                nextRoleIndex += 1
                let guest = NPCGuestController(name: displayName, role: role)

                if role == .seatedPool, let seatIndex = seatOccupants.firstIndex(where: { $0 == nil }) {
                    seatOccupants[seatIndex] = guests.count
                    guest.placeSeated(entity: entity, worldRoot: worldRoot, seatIndex: seatIndex, seat: seats[seatIndex])
                } else {
                    let spawn = randomSpawnPoint(in: floorArea, excluding: exclusionAreas, keepingAwayFrom: spawnedPositions)
                    spawnedPositions.append(spawn)
                    guest.place(entity: entity, worldRoot: worldRoot, at: spawn)
                }
                guests.append(guest)
            }
        }
    }

    /// Furnitures 하위의 모든 "SittingPoint" 마커를 좌석으로 등록한다. 의자 이름이나
    /// 개수를 하드코딩하지 않아 나중에 의자가 추가되어도 코드 수정 없이 좌석이 늘어난다.
    private func discoverSeats(in indoorMap: Entity, relativeTo worldRoot: Entity) -> [GuestSeat] {
        let tableAnchors = collectAnchors(containing: "Table", in: indoorMap, relativeTo: worldRoot)
        var seats: [GuestSeat] = []
        collectSittingPoints(in: indoorMap, relativeTo: worldRoot, tableAnchors: tableAnchors, into: &seats)
        return seats
    }

    private func collectSittingPoints(in entity: Entity,
                                      relativeTo worldRoot: Entity,
                                      tableAnchors: [SIMD2<Float>],
                                      into seats: inout [GuestSeat]) {
        if entity.name == "SittingPoint" {
            let world = entity.position(relativeTo: worldRoot)
            let position = SIMD2<Float>(world.x, world.z)
            let nearestTable = tableAnchors.min {
                simd_distance($0, position) < simd_distance($1, position)
            }
            let facing: SIMD2<Float>
            if let nearestTable, simd_distance(nearestTable, position) > 0.01 {
                facing = simd_normalize(nearestTable - position)
            } else {
                facing = SIMD2(0, 1)
            }
            seats.append(GuestSeat(position: position, facing: facing))
        }
        for child in entity.children {
            collectSittingPoints(in: child, relativeTo: worldRoot, tableAnchors: tableAnchors, into: &seats)
        }
    }

    /// 이름에 keyword가 포함된 모든 엔티티의 월드 XZ 위치를 모은다(테이블 앵커 탐색용).
    private func collectAnchors(containing keyword: String, in entity: Entity, relativeTo worldRoot: Entity) -> [SIMD2<Float>] {
        var anchors: [SIMD2<Float>] = []
        func walk(_ candidate: Entity) {
            if candidate.name.contains(keyword) {
                let world = candidate.position(relativeTo: worldRoot)
                anchors.append(SIMD2(world.x, world.z))
            }
            for child in candidate.children { walk(child) }
        }
        walk(entity)
        return anchors
    }

    /// 모든 좌석을 감싸는 AABB에 여백을 더해 배회 목적지에서 제외한다. 배회 중인
    /// 손님이 앉아있는 손님이나 테이블을 관통해 걷지 않도록 하기 위함이다. 좌석에
    /// 실제로 다가가는 착석 이동(move toward seat.position)은 exclusionAreas를
    /// 확인하지 않으므로 이 제외 구역의 영향을 받지 않는다.
    private func makeSeatClusterExclusion(from seats: [GuestSeat]) -> NPCGuestArea? {
        guard !seats.isEmpty else { return nil }
        let xs = seats.map(\.position.x)
        let zs = seats.map(\.position.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let margin = Tuning.seatClusterExclusionMargin
        let center = SIMD2<Float>((minX + maxX) * 0.5, (minZ + maxZ) * 0.5)
        let halfWidth = (maxX - minX) * 0.5 + margin
        let halfDepth = (maxZ - minZ) * 0.5 + margin
        return NPCGuestArea(center: center, axisU: SIMD2(halfWidth, 0), axisV: SIMD2(0, halfDepth))
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
        seats.removeAll()
        seatOccupants.removeAll()
        queuerIndices.removeAll()
        wasOrdering = false
        queueOrigin = nil
        queueDirection = nil
        queueBaseDistance = 0
    }

    /// - Parameters:
    ///   - isOrdering: 유저가 키오스크 트리거 반경 안에 있는지(= 주문 중으로 간주).
    ///   - kioskCenter: 키오스크 중심 맵 좌표. isOrdering이 true일 때만 유효.
    func update(deltaTime: Float, appModel: AppModel, isOrdering: Bool, kioskCenter: SIMD2<Float>?) {
        guard let floorArea else { return }

        let playerPosition = SIMD2(appModel.motion.positionX, appModel.motion.positionZ)

        if isOrdering, !wasOrdering {
            // 착석 지향(seatedPool) 손님은 대기줄 후보에서 제외한다. 이동 중이거나
            // 이미 앉아있는 손님도 그 자리에서 갑자기 대기줄로 끌려가지 않게 뺀다.
            let eligible = guests.indices.filter { guests[$0].isQueueEligible }
            queuerIndices = Set(eligible.shuffled().prefix(min(2, eligible.count)))
            if let kioskCenter {
                captureQueueLine(kioskCenter: kioskCenter, playerPosition: playerPosition)
            }
        }
        if !isOrdering {
            queuerIndices.removeAll()
            queueOrigin = nil
            queueDirection = nil
            queueBaseDistance = 0
        }
        wasOrdering = isOrdering

        let orderedQueuers = queuerIndices.sorted()
        // 프레임 시작 시 스냅샷을 만들어 업데이트 순서에 따라 뒤쪽 NPC만 더 강하게
        // 반응하는 편향을 없앤다.
        let positions = guests.map(\.currentPosition)
        let anchors = guests.map(\.crowdAnchor)

        for (index, guest) in guests.enumerated() {
            var slot: SIMD2<Float>?
            var facing: SIMD2<Float>?
            if isOrdering, let kioskCenter, let rank = orderedQueuers.firstIndex(of: index) {
                slot = queueSlot(rank: rank + 1)
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

            // 좌석 점유/해제는 이 프레임의 update() 결과를 반영해 처리한다: 방금
            // 일어선 자리를 같은 프레임에 바로 다른 손님에게 내줄 수 있어 빈 프레임
            // 없이 자연스럽게 이어진다.
            if let vacatedIndex = guest.takeVacatedSeatIndex(), vacatedIndex < seatOccupants.count {
                seatOccupants[vacatedIndex] = nil
            }
            if guest.takeSeatRequest(), let freeSeatIndex = seatOccupants.firstIndex(where: { $0 == nil }) {
                seatOccupants[freeSeatIndex] = index
                guest.grantSeat(index: freeSeatIndex, seat: seats[freeSeatIndex])
            }
        }
    }

    /// 줄서기 시작 순간의 키오스크→유저 방향과 거리를 고정 기준선으로 캡처한다.
    /// 이후 매 프레임 이 스냅샷을 그대로 재사용하므로, 유저가 트리거 반경 안에서
    /// 조금씩 움직여도 대기줄이 다시 정렬되며 흔들리지 않는다.
    private func captureQueueLine(kioskCenter: SIMD2<Float>, playerPosition: SIMD2<Float>) {
        var direction = playerPosition - kioskCenter
        let distance = simd_length(direction)
        if distance < 0.001 { direction = SIMD2(0, 1) }
        queueOrigin = kioskCenter
        queueDirection = simd_normalize(direction)
        queueBaseDistance = distance
    }

    /// 고정된 키오스크 기준선(queueOrigin + queueDirection) 위에서, 유저가 서 있는
    /// 지점(queueBaseDistance)보다 rank칸 더 뒤로 줄을 세운다.
    private func queueSlot(rank: Int) -> SIMD2<Float> {
        guard let queueOrigin, let queueDirection else { return .zero }
        let distance = queueBaseDistance + Tuning.queueSpacing * Float(rank)
        return queueOrigin + queueDirection * distance
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
