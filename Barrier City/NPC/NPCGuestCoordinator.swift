import Foundation
import RealityKit
import os
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
    /// 착석 시 바라볼 방향. SittingPoint 마커의 실제 authored 회전(디자이너가 각
    /// 의자 복제본을 배치하며 직접 돌려놓은 값)에서 뽑아낸다.
    let facing: SIMD2<Float>
    /// 착석 시 로코모션 루트(발 기준 정렬)에 적용할 Y 오프셋. 의자 종류마다 실제
    /// 좌석 높이가 다르다 — SittingPoint 마커의 authored 월드 Y를 실측해보면 Chair는
    /// ~0.48m, WoodChair는 ~0.53m, LongChair(긴 벤치)는 ~0.565m로 8.5cm 넘게 차이
    /// 난다. 심지어 Chair는 전체 바운즈 상단(~0.80m)이 등받이라 그걸 쓰면 오히려
    /// 틀린다. enterIndoor가 이 씬 전체 좌석의 평균 SittingPoint 높이 대비 이 좌석이
    /// 얼마나 높은지/낮은지를 계산해 채운다 — 하드코딩된 단일 상수 대신 의자마다
    /// 다르게 보정된다.
    let sittingHeightOffset: Float
}

/// 손님 NPC를 관리한다. 매 프레임 각자 자유롭게 배회·착석시키고, 유저가 키오스크에
/// 접근하면 대기줄 후보 중 랜덤 2명을 유저 뒤에 줄 세운다.
///
/// NPCClerkController(대화 상대 1명)와 책임을 분리했다: 이쪽은 대화·근접 감지 없이
/// 순수하게 다수 NPC의 동선만 담당한다.
@MainActor
final class NPCGuestCoordinator {
    private static let seatingLogger = Logger(
        subsystem: "com.Television.Barrier-City",
        category: "GuestSeating"
    )

    private enum Tuning {
        /// _floor 바깥쪽(벽)에 붙어 걷지 않도록 배회 영역에 두는 여백.
        static let floorMargin: Float = 0.5
        /// 유저와 대기줄 맨 앞사람 사이 간격(m). "바로 뒤"라는 느낌을 주기 위해
        /// 대기줄 내부 간격(queueSpacing)보다 훨씬 좁게 둔다.
        static let queueFrontGap: Float = 0.45
        /// 대기줄 안에서 사람과 사람 사이 간격(m). 맨 앞사람과 유저 사이에는 안 쓰고
        /// (queueFrontGap 참고) 그 뒤부터 이 간격으로 늘어선다.
        static let queueSpacing: Float = 0.85
        /// 스폰 시 손님끼리 서로 떨어뜨리려는 최소 거리(m).
        static let minimumSpawnSeparation: Float = 2.0
        /// 항상 배회만 하는 손님 수(대기줄 후보).
        static let wandererCount = 1
        /// 배회↔착석↔기립을 반복하는 손님 수(대기줄 후보).
        static let cyclerCount = 3
        /// 입장 시 가능하면 이미 앉아있는 상태로 시작하는 손님 수(대기줄 제외, 한 번
        /// 앉으면 계속 앉아있는다). 실제 좌석 수보다 많으면 초과분은 배회로 시작해
        /// 빈 좌석이 생기면 자연스럽게 합류한다.
        static let seatedPoolCount = 6
        /// seatedPool 인원을 나눠 서로 다른 테이블에 앉힐 그룹 크기(합이
        /// seatedPoolCount와 같아야 한다).
        static let seatedPoolGroupSizes: [Int] = [1, 2, 3]
        /// cycler가 입장 즉시 확정 배정받은 좌석 근처(반경 이내)에 스폰돼, 배회 없이
        /// 곧장 좌석으로 걸어가게 한다. 착석 + 디저트 생성이 입장 후 10초 안에 보이도록
        /// 보장하기 위한 값으로, moveSpeed 최저치(0.68m/s)로도 최악의 경우(4.0m) 약
        /// 5.9초면 도착해 회전·군중 회피 여유를 남긴다. 이전엔 5초 기준으로 1.2m였는데,
        /// 기준이 늘어난 만큼 반경도 넓혀 방을 가로질러 걸어오는 좀 더 자연스러운
        /// 그림이 나오게 했다.
        static let cyclerSpawnRadius: Float = 4.0
        /// cycler 중 이 비율만 입장 즉시 좌석으로 직행하고, 나머지는 배회를 한 바퀴
        /// 마친 뒤 좌석으로 향한다(reserveSeat) — 전원이 일제히 좌석으로 직행하면
        /// 너무 빨리 앉는 것처럼 보인다는 피드백으로, 일부는 방을 둘러보다 앉는
        /// 자연스러운 그림을 섞는다.
        static let cyclerImmediateSeatChance: Float = 0.4
        /// 테이블·의자 군집 주변을 배회 목적지에서 제외할 때 두는 여백(m).
        static let seatClusterExclusionMargin: Float = 0.9
        /// 키오스크 주변에 배회 목적지가 잡히지 않도록 두는 반경(m). 대기줄이 아닌
        /// 손님이 우연히 키오스크 앞에 서서 막고 있는 문제를 막는다.
        static let kioskExclusionRadius: Float = 1.2
        /// 착석 시 로코모션 루트에 적용할 Y 오프셋의 기준값(m) — 씬 전체 좌석의 평균
        /// SittingPoint 높이를 가진 "평균적인" 의자라면 이 값을 그대로 쓴다. 실제로
        /// 시각 확인하며 튜닝한 값으로, GuestSeat.sittingHeightOffset이 이 값에
        /// 의자별 편차(SittingPoint 높이 - 평균)를 더해 최종 오프셋을 계산한다.
        static let baselineSittingHeightOffset: Float = 0.05
    }

    /// Indoor.usda에는 성별당 원본 엔티티가 하나씩만 있다("Female", "MaleIdle").
    /// 손님 6명은 코드에서 entity.clone(recursive:)로 이 원본을 복제해 만든다 —
    /// usda에 직접 6개의 중복 def 블록을 추가하는 대신 단일 소스를 유지한다.
    /// 콜리전은 원본 authoring과 무관하게 place()에서 매번 코드로 부여한다
    /// (Entity.applyNPCBodyCollision 참고).
    private struct GenderGroup {
        let templateName: String
        let gender: NPCGuestGender
        let displayNames: [String]
    }

    /// wandererCount + cyclerCount + seatedPoolCount(1+3+6=10)에 맞춘 인원 구성.
    private static let genderGroups: [GenderGroup] = [
        GenderGroup(templateName: "Female", gender: .female, displayNames: ["Guest_Female_1", "Guest_Female_2", "Guest_Female_3", "Guest_Female_4", "Guest_Female_5"]),
        GenderGroup(templateName: "MaleIdle", gender: .male, displayNames: ["Guest_Male_1", "Guest_Male_2", "Guest_Male_3", "Guest_Male_4", "Guest_Male_5"]),
    ]

    private var guests: [NPCGuestController] = []
    private var floorArea: NPCGuestArea?
    private var exclusionAreas: [NPCGuestArea] = []
    /// Furnitures 하위 "SittingPoint" 마커에서 찾은 좌석. 개수는 씬 authoring에 따라
    /// 달라지며 하드코딩하지 않는다.
    private var seats: [GuestSeat] = []
    /// seats와 같은 길이. 각 자리를 점유 중인 guests 인덱스, 비어 있으면 nil.
    private var seatOccupants: [Int?] = []
    /// seats 인덱스를 "같은 테이블" 단위로 묶은 것 — 좌석이 "가장 가까운 테이블"로 연결된
    /// 엔티티(tripo_mesh_* 리프 하나, collectSittingPoints 참고)가 같으면 같은 그룹이다.
    /// 좌석 위치 거리로 묶는 방식(예전)도 시도해봤는데, Indoor.usda를 실측해보니 tripo_mesh_*
    /// 리프 하나하나가 이미 "물리적 테이블 인스턴스 하나"와 정확히 대응해서(상판/다리로 쪼개진
    /// 게 아니라, 예를 들어 작은 2인용 테이블 14개 + 긴 벤치 2개가 각각 리프 하나씩) 거리
    /// 클러스터링은 오히려 가까이 붙여둔 서로 다른 물리적 테이블들을 하나로 잘못 합쳐버렸다
    /// (예: linkDistance 1.6m 안에 있는 옆 테이블까지 같은 그룹으로 묶여, 그 그룹의 디저트
    /// 표면 높이가 가장 큰/작은 테이블 기준으로 뒤섞여 케이크가 공중에 뜨는 등 오배치가
    /// 발생했다). 그래서 entity identity 기준으로 되돌렸다 — seatedPool 그룹(1/2/3명)
    /// 배정과 디저트 테이블 배정 모두 이 배열 하나로 통일한다(아래
    /// seatIndexToTableGroupIndex/tableSurfaceBoundsByGroupIndex 참고).
    private var seatTableGroups: [[Int]] = []
    private var queuerIndices: Set<Int> = []
    private var wasOrdering = false
    /// 줄서기 시작 순간에 고정하는 대기줄 기준선(키오스크 원점 + 방향 + 유저까지의
    /// 거리). 매 프레임 라이브 유저 위치로 다시 계산하면 유저가 트리거 반경 안에서
    /// 조금만 움직여도 줄 전체가 다시 정렬되며 흔들리므로, 시작 시점에만 캡처해
    /// 이후에는 유저가 서 있던 지점 기준으로 고정한다.
    private var queueOrigin: SIMD2<Float>?
    private var queueDirection: SIMD2<Float>?
    /// 이번 대기줄에서 자리에 도착하면 한숨을 재생할 손님(줄서기 시작 시 무작위 선정).
    private var sighingGuestIndex: Int?
    /// 직원 구역(AreaK/AreaB)만 담은 목록. exclusionAreas 전체(키오스크 주변 배회
    /// 제외 반경 + 테이블별 좌석 클러스터 제외 구역 포함) 대신 이걸 써야 하는 곳이
    /// 두 군데 있다: (1) queueSlot(rank:) — 키오스크 제외 반경까지 같이 피하게 하면
    /// 유저가 키오스크 가까이 서 있을 때 대기줄 첫 자리가 그 반경을 벗어날 때까지
    /// 계속 밀려나 유저 뒤에 못 붙었다. (2) 좌석으로 걸어가는 이동(NPCGuestController
    /// updateMovingToSeat) — 좌석 자체가 그 테이블의 좌석 클러스터 제외 구역 안에
    /// 있어서, 제외 구역 전체를 넘기면 목적지와 반대 방향으로 계속 밀려나 영원히
    /// 도착 못 하고 Walk만 반복 재생했다(cycler가 배회 후 앉지 못하던 원인).
    private var staffAreaExclusions: [NPCGuestArea] = []
    /// seats와 같은 길이. 좌석 인덱스 → seatTableGroups에서 그 좌석이 속한 그룹 인덱스
    /// (seatTableGroups의 역인덱스일 뿐이라 매 프레임 배열을 훑지 않고 바로 찾을 수 있다).
    private var seatIndexToTableGroupIndex: [Int?] = []
    /// 테이블 그룹 인덱스별로, 그 그룹 좌석들이 연결된 tripo_mesh_* 앵커 엔티티(그룹 내
    /// 전부 동일)의 바운즈(min/max, worldRoot 기준) — 디저트를 놓을 표면 계산
    /// (spawnDessertProps)에 쓴다.
    private var tableSurfaceBoundsByGroupIndex: [(min: SIMD3<Float>, max: SIMD3<Float>)?] = []
    /// 이미 디저트를 배정한 테이블 그룹 인덱스(같은 테이블에 손님이 여러 명 앉아도 한 번만).
    private var dessertAssignedTableGroups: Set<Int> = []
    /// 배치한 디저트 prop들. tearDownForOutdoor에서 정리한다.
    private var placedDessertProps: [Entity] = []
    private var worldRoot: Entity?
    private var cakeTemplate: Entity?
    private var latteTemplate: Entity?

    private enum DessertTuning {
        /// 케이크/라떼를 이 높이(m)로 균일 스케일한다(원본 에셋 크기가 제각각이라 맞춰준다).
        static let targetCakeHeight: Float = 0.10
        /// 라떼가 눈에 띄게 커 보인다는 피드백으로 기존 값(0.16)의 0.5배로 줄였다.
        /// 균일 스케일(targetHeight/authoredHeight)이라 너비·깊이도 함께 절반이 되고,
        /// 배치 위치는 spawnDessertProps가 스케일 적용 후 바운즈를 다시 재서 표면에
        /// 맞추므로 이 값만 바꿔도 자동으로 정확히 안착한다.
        static let targetLatteHeight: Float = 0.08
        /// 테이블 상단면 바로 위로 살짝 띄우는 여백.
        static let surfaceClearance: Float = 0.005
        /// 케이크+라떼를 함께 놓을 때, 손님 쪽을 바라보는 축에 수직으로 서로 반대쪽에
        /// 떨어뜨리는 거리(나란히 놓기).
        static let pairOffset: Float = 0.12
        /// 테이블 중심에서 무작위로 살짝 어긋나게 둬 기계적으로 보이지 않게 한다.
        static let placementJitter: Float = 0.03
        /// 테이블 가장자리에 걸치지 않도록 바운즈 절반 폭에서 빼는 여백.
        static let edgeMargin: Float = 0.06
        /// 테이블 중심에서 손님이 앉은 쪽으로 당기는 비율(0=중앙, 1=여백을 뺀 가장자리까지).
        static let towardDinersPullFraction: Float = 0.55
    }

    /// Indoor 진입 시 손님 엔티티를 찾아 배치하고, "_floor"에서 배회 영역을,
    /// "AreaK"/"AreaB"에서 제외 영역을 계산한다. 좌석은 씬을 스캔해 동적으로 찾고,
    /// 손님마다 역할(항상 배회/배회-착석 순환/입장부터 착석 시도)을 무작위로 나눈다.
    func enterIndoor(worldRoot: Entity, indoorMap: Entity,
                     cakeTemplate: Entity? = nil, latteTemplate: Entity? = nil) {
        tearDownForOutdoor()

        self.worldRoot = worldRoot
        self.cakeTemplate = cakeTemplate
        self.latteTemplate = latteTemplate

        floorArea = resolveArea(named: "_floor", in: indoorMap, relativeTo: worldRoot, margin: Tuning.floorMargin)
        staffAreaExclusions = ["AreaK", "AreaB"].compactMap {
            resolveArea(named: $0, in: indoorMap, relativeTo: worldRoot, margin: 0)
        }
        exclusionAreas = staffAreaExclusions
        // 대기줄이 아닌 손님이 키오스크 앞에 우연히 배회 목적지를 잡아 막고 서 있지
        // 않도록 작은 반경을 배회 제외 구역에 더한다.
        if let kiosk = indoorMap.findEntity(named: "Kiosk") {
            let world = kiosk.position(relativeTo: worldRoot)
            let radius = Tuning.kioskExclusionRadius
            exclusionAreas.append(NPCGuestArea(center: SIMD2(world.x, world.z),
                                               axisU: SIMD2(radius, 0),
                                               axisV: SIMD2(0, radius)))
        }
        guard let floorArea else { return }

        // authoring 상 실수로 좌석이 직원 구역(AreaK/AreaB) 안에 놓였다면 손님이
        // 그쪽으로 걸어 들어가지 않도록 애초에 좌석 후보에서 뺀다. seatTableEntities는
        // seats와 인덱스가 대응해야 하므로 같은 필터를 동시에 적용한다.
        let sittingPoints = collectSittingPoints(in: indoorMap, relativeTo: worldRoot)
        var filteredSeats: [GuestSeat] = []
        var filteredSeatTableEntities: [Entity?] = []
        for (seat, tableEntity) in zip(sittingPoints.seats, sittingPoints.seatTableEntities) {
            guard !exclusionAreas.contains(where: { $0.contains(seat.position) }) else { continue }
            filteredSeats.append(seat)
            filteredSeatTableEntities.append(tableEntity)
        }
        // 각 좌석의 sittingHeightOffset은 지금까지 SittingPoint의 raw authored 월드 Y를
        // 담고 있다(위 collectSittingPoints 참고). 이 씬 전체 좌석의 평균 높이를 구해,
        // 그 평균보다 얼마나 높은/낮은 의자인지를 baselineSittingHeightOffset(기존에
        // 시각 확인으로 튜닝한 값) 기준으로 보정한 최종 오프셋으로 다시 채운다 —
        // 의자 종류마다 다른 높이가 하드코딩 없이 자동으로 반영된다.
        let averageSeatHeight = filteredSeats.isEmpty ? 0
            : filteredSeats.map(\.sittingHeightOffset).reduce(0, +) / Float(filteredSeats.count)
        filteredSeats = filteredSeats.map { seat in
            GuestSeat(position: seat.position, facing: seat.facing,
                     sittingHeightOffset: Tuning.baselineSittingHeightOffset
                         + (seat.sittingHeightOffset - averageSeatHeight))
        }
        seats = filteredSeats
        seatOccupants = Array(repeating: nil, count: seats.count)

        // seatTableGroups는 "가장 가까운 테이블" 엔티티 identity로 묶는다(위 프로퍼티
        // 주석 참고 — 좌석 위치 거리 클러스터링은 서로 다른 물리적 테이블을 잘못 합쳤다).
        var groupIndexByAnchor: [ObjectIdentifier: Int] = [:]
        var groupsBuilder: [[Int]] = []
        for (seatIndex, anchor) in filteredSeatTableEntities.enumerated() {
            guard let anchor else { continue }
            let key = ObjectIdentifier(anchor)
            if let existing = groupIndexByAnchor[key] {
                groupsBuilder[existing].append(seatIndex)
            } else {
                groupIndexByAnchor[key] = groupsBuilder.count
                groupsBuilder.append([seatIndex])
            }
        }
        seatTableGroups = groupsBuilder

        seatIndexToTableGroupIndex = Array(repeating: nil, count: seats.count)
        for (groupIndex, seatIndices) in seatTableGroups.enumerated() {
            for seatIndex in seatIndices { seatIndexToTableGroupIndex[seatIndex] = groupIndex }
        }
        tableSurfaceBoundsByGroupIndex = seatTableGroups.map { seatIndices -> (min: SIMD3<Float>, max: SIMD3<Float>)? in
            guard let firstSeatIndex = seatIndices.first,
                  let anchor = filteredSeatTableEntities[firstSeatIndex] else { return nil }
            let bounds = anchor.visualBounds(relativeTo: worldRoot)
            return (min: bounds.min, max: bounds.max)
        }
        // 긴 벤치형 WoodTable 하나는 실측해보니 authored 바운즈 상단이 약 1.2m로, 다른
        // 일반 테이블(약 0.77m)보다 훨씬 높았다 — 단일 리프 메시라 상판과 별개 부분을
        // 나눠 인식할 방법이 없어, 씬을 고치는 대신 나머지 테이블들의 중앙값 높이에서
        // 크게 벗어나는 테이블만 그 중앙값으로 보정해 디저트가 공중에 뜨지 않게 한다.
        let measuredHeights = tableSurfaceBoundsByGroupIndex.compactMap { $0?.max.y }.sorted()
        if let medianHeight = measuredHeights.isEmpty ? nil : measuredHeights[measuredHeights.count / 2] {
            let outlierTolerance: Float = 0.25
            for index in tableSurfaceBoundsByGroupIndex.indices {
                guard var bounds = tableSurfaceBoundsByGroupIndex[index],
                      abs(bounds.max.y - medianHeight) > outlierTolerance else { continue }
                Self.seatingLogger.notice("테이블 그룹 \(index) 표면 높이 이상치 보정: \(bounds.max.y)m → \(medianHeight)m")
                bounds.max.y = medianHeight
                tableSurfaceBoundsByGroupIndex[index] = bounds
            }
        }
        let seatDescription = seats.map { seat in "(\(seat.position.x), \(seat.position.y))" }.joined(separator: ", ")
        Self.seatingLogger.notice("발견된 좌석 \(self.seats.count)개(테이블 \(self.seatTableGroups.count)개): \(seatDescription)")
        // 테이블마다 각자 좌석 주변에만 작은 배회 제외 구역을 둔다. 모든 좌석을 하나의
        // 큰 바운딩 박스로 묶으면(예전 방식) 방 전체를 뒤덮을 만큼 넓어져 배회 가능한
        // 공간이 거의 안 남아 NPC가 목적지를 못 찾고 그 자리에 멈춰있는 문제가 있었다.
        for group in seatTableGroups {
            if let exclusion = makeSeatClusterExclusion(from: group.map { seats[$0] }) {
                exclusionAreas.append(exclusion)
            }
        }

        var roles: [NPCGuestRole] = []
        roles += Array(repeating: .alwaysWandering, count: Tuning.wandererCount)
        roles += Array(repeating: .cycler, count: Tuning.cyclerCount)
        roles += Array(repeating: .seatedPool, count: Tuning.seatedPoolCount)
        roles.shuffle()
        var nextRoleIndex = 0

        // seatedPool을 groupSizes(1/2/3명)대로 서로 다른 테이블에 배정하기 위한 좌석
        // 큐. 앞에서부터 하나씩 꺼내 쓰고, 다 떨어지면(테이블이 부족하면)
        // bestFreeSeatIndex()로 폴백한다.
        var seatedPoolSeatQueue = makeSeatedPoolGroupQueue(groupSizes: Tuning.seatedPoolGroupSizes)

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
                let guest = NPCGuestController(name: displayName, role: role, gender: group.gender)

                let seatIndex: Int? = role == .seatedPool
                    ? (!seatedPoolSeatQueue.isEmpty ? seatedPoolSeatQueue.removeFirst() : bestFreeSeatIndex())
                    : nil
                if role == .seatedPool, let seatIndex, seatOccupants.indices.contains(seatIndex),
                   seatOccupants[seatIndex] == nil {
                    seatOccupants[seatIndex] = guests.count
                    guest.placeSeated(entity: entity, worldRoot: worldRoot, seatIndex: seatIndex, seat: seats[seatIndex])
                    maybeSpawnDessert(forSeatIndex: seatIndex)
                } else if role == .cycler, let seatIndex = bestFreeSeatIndex() {
                    // 배회하다 우연히 좌석을 원할 확률(sitDesireChance)에 기대면 유저가
                    // 카페에 들어온 뒤 몇 초 안에 착석·디저트가 보인다는 보장이 안 된다.
                    // 그래서 cycler는 입장 즉시 이 좌석을 확정 배정받고, 좌석 바로 뒤
                    // (테이블 반대쪽, cyclerSpawnRadius 이내)에서만 스폰해 이동 거리를
                    // 짧게 둔다. 도중에 실제 장애물에 막혀 updateMovingToSeat가 자리를
                    // 반납하면(seatState = .none), 기존 배회→확률적 재시도 경로가
                    // 자연스럽게 이어받는다. 디저트는 여기서 바로 놓지 않는다 —
                    // update()가 takeSeatedArrivalSeatIndex()로 실제 도착을 확인한
                    // 뒤에 놓아야, 걸어가다 막혀 자리를 반납해도 아무도 없는 테이블에
                    // 디저트만 남는 일이 없다.
                    //
                    // 전원이 곧장 좌석으로 직행하면 너무 빨리 앉는 것처럼 보여,
                    // cyclerImmediateSeatChance 비율만 즉시 걸어가고 나머지는 배회를
                    // 한 바퀴 마친 뒤 좌석으로 향한다(reserveSeat) — moveSpeed
                    // 최저치(0.68m/s)로도 최악의 경우(4.0m) 약 5.9초면 도착해 10초
                    // 기준 안에서 여유가 있다.
                    seatOccupants[seatIndex] = guests.count
                    let seat = seats[seatIndex]
                    let spawn = seat.position - seat.facing * Float.random(in: 1.0...Tuning.cyclerSpawnRadius)
                    spawnedPositions.append(spawn)
                    guest.place(entity: entity, worldRoot: worldRoot, at: spawn)
                    if Float.random(in: 0...1) < Tuning.cyclerImmediateSeatChance {
                        guest.grantSeat(index: seatIndex, seat: seat)
                        Self.seatingLogger.notice("\(displayName) 입장 시 좌석 \(seatIndex) 즉시 착석 배정: spawn=(\(spawn.x), \(spawn.y)) seat=(\(seat.position.x), \(seat.position.y)) 거리=\(simd_distance(spawn, seat.position))m")
                    } else {
                        guest.reserveSeat(index: seatIndex, seat: seat)
                        Self.seatingLogger.notice("\(displayName) 좌석 \(seatIndex) 예약(배회 후 착석): spawn=(\(spawn.x), \(spawn.y)) seat=(\(seat.position.x), \(seat.position.y))")
                    }
                } else {
                    let spawn = randomSpawnPoint(in: floorArea, excluding: exclusionAreas, keepingAwayFrom: spawnedPositions)
                    spawnedPositions.append(spawn)
                    guest.place(entity: entity, worldRoot: worldRoot, at: spawn)
                }
                guests.append(guest)
            }
        }

        let seatedCount = guests.filter { $0.role == .seatedPool }.count
        let actuallySeated = seatOccupants.compactMap { $0 }.count
        Self.seatingLogger.notice("입장 시 착석: seatedPool \(seatedCount)명 중 \(actuallySeated)명 실제 착석(나머지는 배회로 시작해 빈 좌석이 생기면 합류)")
    }

    /// 빈 좌석 중 현재 앉아있는 손님들과 가장 멀리 떨어진 자리를 고른다. 그냥 첫 번째
    /// 빈 인덱스를 쓰면 씬 authoring 순서상 같은 테이블의 좌석들이 배열에서 이웃해
    /// 있어(예: Chair 복제본 19개가 한 테이블에 연달아 있음) 손님들이 한 테이블에만
    /// 몰려 앉게 된다. 앉은 사람이 아직 없으면 무작위로 고른다.
    private func bestFreeSeatIndex() -> Int? {
        let freeIndices = seatOccupants.indices.filter { seatOccupants[$0] == nil }
        guard !freeIndices.isEmpty else { return nil }
        let occupiedPositions = seatOccupants.indices.compactMap { idx -> SIMD2<Float>? in
            seatOccupants[idx] != nil ? seats[idx].position : nil
        }
        guard !occupiedPositions.isEmpty else { return freeIndices.randomElement() }
        return freeIndices.max { lhs, rhs in
            let lhsDistance = occupiedPositions.map { simd_distance($0, seats[lhs].position) }.min() ?? 0
            let rhsDistance = occupiedPositions.map { simd_distance($0, seats[rhs].position) }.min() ?? 0
            return lhsDistance < rhsDistance
        }
    }

    /// Furnitures 하위의 모든 "SittingPoint" 마커를 좌석으로 모으고, 각 좌석에서
    /// 가장 가까운 테이블 인스턴스 쪽을 바라보게 한다.
    ///
    /// 방향을 SittingPoint의 authored 회전에서 뽑아내려 해봤는데(디자이너가 의자
    /// 복제본마다 직접 돌려놓은 값이라 믿을만해 보였다), 의자 종류(Chair/WoodChair)
    /// 마다 마커 로컬 축 관례가 달라 보여 실제 배치와 안 맞는 경우가 있었다.
    /// 대신 "가장 가까운 테이블 인스턴스를 바라본다"는, 씬 구조에 덜 의존하는
    /// 기하학적 규칙으로 되돌렸다 — 다만 Table도 Chair와 똑같이 하나의 def 안에
    /// 여러 인스턴스가 참조로 중첩돼 있어서(예: WoodChair도 실제로는 12개 복제본),
    /// "Table"/"WoodTable"이라는 이름의 엔티티 하나의 위치만 보면 안 되고 그 밑의
    /// 개별 tripo_mesh_* 리프(복제본 하나하나)를 전부 앵커로 모아야 한다.
    private func collectSittingPoints(
        in entity: Entity, relativeTo worldRoot: Entity
    ) -> (seats: [GuestSeat], seatTableEntities: [Entity?]) {
        let tableAnchors = collectTableAnchors(in: entity, relativeTo: worldRoot)
        var seats: [GuestSeat] = []
        var seatTableEntities: [Entity?] = []
        func walk(_ candidate: Entity) {
            // 이름 동등 비교라 같은 이름의 마커가 씬 안에 몇 개든(서로 다른 부모 밑에
            // 있는 한) 전부 개별 좌석으로 잡힌다. RCP는 형제 간 이름이 겹칠 때만
            // "SittingPoint_1"처럼 접미사를 붙이므로 그 패턴도 함께 인식한다.
            if candidate.name == "SittingPoint" || candidate.name.hasPrefix("SittingPoint_") {
                let world = candidate.position(relativeTo: worldRoot)
                let position = SIMD2<Float>(world.x, world.z)
                let nearestTable = tableAnchors.min {
                    simd_distance($0.position, position) < simd_distance($1.position, position)
                }
                let facing: SIMD2<Float>
                if let nearestTable, simd_distance(nearestTable.position, position) > 0.01 {
                    facing = simd_normalize(nearestTable.position - position)
                } else {
                    facing = SIMD2(0, 1)
                }
                // sittingHeightOffset은 여기서는 SittingPoint의 raw authored 월드 Y를
                // 그대로 담아 두고(아직 씬 전체 평균을 모르니 보정 전 값), enterIndoor가
                // 필터링을 마친 뒤 전체 평균 대비 보정된 최종 오프셋으로 다시 채운다.
                seats.append(GuestSeat(position: position, facing: facing, sittingHeightOffset: world.y))
                // 이 좌석이 실제로 속한 테이블(디저트를 얹을 표면)도 같은 "가장 가까운
                // 테이블" 판정으로 같이 기록해 둔다 — facing 계산과 동일한 근거라
                // 좌석 클러스터 중심을 거치는 간접 매칭보다 테이블을 놓칠 일이 적다.
                seatTableEntities.append(nearestTable?.entity)
                // SittingPoint는 좌석 위치·방향을 뽑기 위한 순수 마커라 실제로 보이면 안
                // 된다. authored material(</Root/invisible>)이 이 앱의 로딩 경로에서는
                // 반영되지 않아(Entity.applyNPCBodyCollision 주석의 콜리전 미반영과 같은
                // 원인) 코드에서 직접 꺼야 한다.
                candidate.isEnabled = false
            }
            for child in candidate.children { walk(child) }
        }
        walk(entity)
        return (seats, seatTableEntities)
    }

    /// "Table"/"WoodTable" 계열 서브트리 안의 모든 tripo_mesh_* 리프(실제 배치된
    /// 테이블 인스턴스 하나하나에 대응)와 그 월드 위치를 모은다. 좌석 방향 계산과 디저트를
    /// 얹을 테이블 표면 찾기(spawnDessertProps) 양쪽에서 같이 쓴다.
    private func collectTableAnchors(
        in entity: Entity, relativeTo worldRoot: Entity, insideTable: Bool = false
    ) -> [(entity: Entity, position: SIMD2<Float>)] {
        let isTableRoot = entity.name == "Table" || entity.name == "WoodTable"
            || entity.name.hasPrefix("Table_") || entity.name.hasPrefix("WoodTable_")
        let inTableSubtree = insideTable || isTableRoot

        var anchors: [(entity: Entity, position: SIMD2<Float>)] = []
        if inTableSubtree, entity.name.hasPrefix("tripo_mesh_") {
            let world = entity.position(relativeTo: worldRoot)
            anchors.append((entity, SIMD2(world.x, world.z)))
        }
        for child in entity.children {
            anchors.append(contentsOf: collectTableAnchors(
                in: child, relativeTo: worldRoot, insideTable: inTableSubtree))
        }
        return anchors
    }

    /// seatedPoolCount 인원을 groupSizes(예: [1, 2, 3])대로 나눠, 각 그룹을 서로 다른
    /// 테이블(seatTableGroups)에 배정한다. 좌석 순서대로 배열해 반환하며, 호출부가
    /// 앞에서부터 하나씩 꺼내 쓴다.
    private func makeSeatedPoolGroupQueue(groupSizes: [Int]) -> [Int] {
        let shuffledGroups = seatTableGroups.indices.shuffled()
        var usedTableGroups: Set<Int> = []
        var usedSeats: Set<Int> = []
        var queue: [Int] = []
        for size in groupSizes.sorted(by: >) {
            guard let groupIndex = shuffledGroups.first(where: { idx in
                !usedTableGroups.contains(idx)
                    && seatTableGroups[idx].filter({ !usedSeats.contains($0) }).count >= size
            }) else { continue }
            usedTableGroups.insert(groupIndex)
            let chosen = seatTableGroups[groupIndex]
                .filter { !usedSeats.contains($0) }
                .shuffled()
                .prefix(size)
            usedSeats.formUnion(chosen)
            queue.append(contentsOf: chosen)
        }
        return queue
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
        staffAreaExclusions.removeAll()
        seats.removeAll()
        seatOccupants.removeAll()
        seatTableGroups.removeAll()
        queuerIndices.removeAll()
        wasOrdering = false
        queueOrigin = nil
        queueDirection = nil
        sighingGuestIndex = nil
        seatIndexToTableGroupIndex.removeAll()
        tableSurfaceBoundsByGroupIndex.removeAll()
        dessertAssignedTableGroups.removeAll()
        for prop in placedDessertProps { prop.removeFromParent() }
        placedDessertProps.removeAll()
        worldRoot = nil
        cakeTemplate = nil
        latteTemplate = nil
    }

    // MARK: - Table desserts

    /// 방금 점유된 좌석이 속한 테이블에 아직 디저트가 없으면 케이크/라떼 중 하나 또는 둘 다를
    /// 무작위로 얹는다. 같은 테이블에 손님이 여러 명 앉아도 테이블당 한 번만 배정한다.
    private func maybeSpawnDessert(forSeatIndex seatIndex: Int) {
        guard let worldRoot,
              seatIndexToTableGroupIndex.indices.contains(seatIndex),
              let groupIndex = seatIndexToTableGroupIndex[seatIndex],
              !dessertAssignedTableGroups.contains(groupIndex),
              tableSurfaceBoundsByGroupIndex.indices.contains(groupIndex),
              let surfaceBounds = tableSurfaceBoundsByGroupIndex[groupIndex] else { return }
        dessertAssignedTableGroups.insert(groupIndex)
        let tableCenter = SIMD2((surfaceBounds.min.x + surfaceBounds.max.x) * 0.5,
                                (surfaceBounds.min.z + surfaceBounds.max.z) * 0.5)
        let groupSeatIndices = seatTableGroups.indices.contains(groupIndex) ? seatTableGroups[groupIndex] : []
        let seatCentroid = groupSeatIndices.isEmpty
            ? tableCenter
            : groupSeatIndices.reduce(SIMD2<Float>.zero) { $0 + seats[$1].position } / Float(groupSeatIndices.count)
        spawnDessertProps(surfaceMin: surfaceBounds.min, surfaceMax: surfaceBounds.max,
                          towardDiners: seatCentroid - tableCenter, worldRoot: worldRoot)
    }

    /// 테이블 표면 바운즈(=maybeSpawnDessert가 seatTableGroups 기준으로 합친 앵커 부피) 상단
    /// 높이를 구해, 그 위에 케이크·라떼 템플릿을 복제해 자연스럽게 얹는다.
    /// RainbowSmoothiePresenter가 카운터 위에 스무디를 놓을 때 쓰는 것과 같은 방식(바닥
    /// 기준점 정렬)을 그대로 따른다. towardDiners는 테이블 중심에서 그 테이블에 앉은
    /// 손님들 쪽을 향하는 벡터로, 긴 테이블에서도 디저트가 손님과 먼 반대편이 아니라 앞쪽
    /// 가장자리 근처에 오게 한다.
    private func spawnDessertProps(surfaceMin: SIMD3<Float>, surfaceMax: SIMD3<Float>,
                                   towardDiners direction: SIMD2<Float>, worldRoot: Entity) {
        guard RainbowSmoothiePlacement.hasFiniteOrderedBounds(minimum: surfaceMin, maximum: surfaceMax) else { return }
        let surfaceY = surfaceMax.y + DessertTuning.surfaceClearance
        let centerX = (surfaceMin.x + surfaceMax.x) * 0.5
        let centerZ = (surfaceMin.z + surfaceMax.z) * 0.5
        let insetHalfWidth = max(0, (surfaceMax.x - surfaceMin.x) * 0.5 - DessertTuning.edgeMargin)
        let insetHalfDepth = max(0, (surfaceMax.z - surfaceMin.z) * 0.5 - DessertTuning.edgeMargin)

        let forward = simd_length(direction) > 0.001 ? simd_normalize(direction) : SIMD2<Float>(0, 1)
        let right = SIMD2<Float>(forward.y, -forward.x)
        let forwardPull = min(insetHalfWidth, insetHalfDepth) * DessertTuning.towardDinersPullFraction

        enum DessertCase: CaseIterable { case cakeOnly, latteOnly, both }
        var placements: [(template: Entity, targetHeight: Float, lateralOffset: Float)] = []
        switch DessertCase.allCases.randomElement() ?? .both {
        case .cakeOnly:
            if let cakeTemplate {
                placements = [(cakeTemplate, DessertTuning.targetCakeHeight, 0)]
            }
        case .latteOnly:
            if let latteTemplate {
                placements = [(latteTemplate, DessertTuning.targetLatteHeight, 0)]
            }
        case .both:
            if let cakeTemplate {
                placements.append((cakeTemplate, DessertTuning.targetCakeHeight, -DessertTuning.pairOffset))
            }
            if let latteTemplate {
                placements.append((latteTemplate, DessertTuning.targetLatteHeight, DessertTuning.pairOffset))
            }
        }
        guard !placements.isEmpty else { return }

        for (template, targetHeight, lateralOffset) in placements {
            let prop = template.clone(recursive: true)
            worldRoot.addChild(prop)
            // Entity.load 결과를 직접 조사해 보면 Cake/Latte의 루트 엔티티에는 RainbowSmoothie와
            // 완전히 동일한 회전(X축 -90°)이 authored돼 있다 — Tripo가 Z-up으로 내보낸 원본을
            // RealityKit이 임포트하며 항상 붙이는 표준 Z-up→Y-up 보정이라, 세 에셋 모두 이
            // 회전이 있어야 정상적으로 세워진다. 실제 mesh bounds(로컬)도 세로축이 Z이고
            // 바닥이 정확히 Z=0에 붙어 있어(케이크 0~0.912, 라떼 0~0.603), 이 회전을 그대로
            // 두면 world Y 바운즈 하단이 이미 0에 온다 — 여기서 다시 회전을 만지면(예전의
            // identity 리셋) 오히려 이 보정을 지워버려 옆으로 누운 것처럼 보인다. 그래서
            // RainbowSmoothiePresenter와 마찬가지로 orientation은 아예 건드리지 않는다.
            let authoredHeight = prop.visualBounds(relativeTo: worldRoot).extents.y
            guard authoredHeight.isFinite, authoredHeight > 0.0001 else {
                prop.removeFromParent()
                continue
            }
            prop.scale *= SIMD3(repeating: targetHeight / authoredHeight)

            let jitterX = Float.random(in: -DessertTuning.placementJitter...DessertTuning.placementJitter)
            let jitterZ = Float.random(in: -DessertTuning.placementJitter...DessertTuning.placementJitter)
            let offsetXZ = forward * forwardPull + right * lateralOffset
            let x = min(max(centerX + offsetXZ.x + jitterX, centerX - insetHalfWidth), centerX + insetHalfWidth)
            let z = min(max(centerZ + offsetXZ.y + jitterZ, centerZ - insetHalfDepth), centerZ + insetHalfDepth)

            prop.setPosition([x, surfaceY, z], relativeTo: worldRoot)
            // 스케일을 반영한 실측 바운즈 하단을 테이블 표면에 맞춰, 모델 원점이 바닥과
            // 어긋나 있어도(제각각인 에셋 원점) 붕 뜨거나 파묻히지 않게 한다.
            let restingOffset = surfaceY - prop.visualBounds(relativeTo: worldRoot).min.y
            prop.position.y += restingOffset

            placedDessertProps.append(prop)
        }
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
                let slot1 = queueSlot(rank: 1)
                Self.seatingLogger.notice("대기줄 1번 자리: 유저로부터 \(simd_distance(slot1, playerPosition))m (좌표 \(slot1.x), \(slot1.y))")
            }
            // 대기줄 중 한 명을 무작위로 골라, 그 손님이 자리에 도착하면 한숨을
            // 재생해 뒤에 사람이 기다린다는 압박감을 준다.
            sighingGuestIndex = queuerIndices.randomElement()
        }
        if !isOrdering {
            queuerIndices.removeAll()
            queueOrigin = nil
            queueDirection = nil
            sighingGuestIndex = nil
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
                        staffExclusions: staffAreaExclusions,
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
                Self.seatingLogger.notice("\(guest.name) 좌석 \(vacatedIndex) 접근 실패(막힘)로 반납, 위치=(\(guest.currentPosition.x), \(guest.currentPosition.y))")
            }
            if guest.takeSeatRequest(), let freeSeatIndex = bestFreeSeatIndex() {
                seatOccupants[freeSeatIndex] = index
                guest.grantSeat(index: freeSeatIndex, seat: seats[freeSeatIndex])
            }
            // 디저트는 배정(grantSeat) 시점이 아니라 실제로 걸어가 도착한 시점에
            // 놓는다 — 걸어가다 막혀 자리를 반납하면 아무도 없는 테이블에 디저트만
            // 남는 문제를 막는다.
            if let arrivedSeatIndex = guest.takeSeatedArrivalSeatIndex() {
                maybeSpawnDessert(forSeatIndex: arrivedSeatIndex)
                Self.seatingLogger.notice("\(guest.name) 좌석 \(arrivedSeatIndex) 착석 완료")
            }
            if index == sighingGuestIndex, guest.takeQueueArrivalSignal() {
                guest.playSigh()
            }
        }
    }

    /// 줄서기 시작 순간의 키오스크→유저 방향과 거리를 고정 기준선으로 캡처한다.
    /// 이후 매 프레임 이 스냅샷을 그대로 재사용하므로, 유저가 트리거 반경 안에서
    /// 조금씩 움직여도 대기줄이 다시 정렬되며 흔들리지 않는다.
    /// 유저가 서 있는 지점을 기준선 원점으로 캡처한다(방향은 키오스크→유저를 그대로
    /// 연장). 원점을 키오스크가 아니라 유저 위치로 잡아야 대기줄 첫 번째 자리가
    /// 유저 바로 뒤(queueFrontGap만큼)에 오지, 키오스크까지의 거리만큼 밀려나지 않는다.
    private func captureQueueLine(kioskCenter: SIMD2<Float>, playerPosition: SIMD2<Float>) {
        var direction = playerPosition - kioskCenter
        if simd_length(direction) < 0.001 { direction = SIMD2(0, 1) }
        queueOrigin = playerPosition
        queueDirection = simd_normalize(direction)
    }

    /// 고정된 기준선(queueOrigin=유저 위치 + queueDirection) 위에서 rank번째 자리를
    /// 계산한다. 1번은 유저에게서 queueFrontGap만큼만 떨어지고(대기줄 내부 간격보다
    /// 훨씬 좁게), 그 뒤로는 queueSpacing 간격으로 늘어선다. 키오스크가 직원
    /// 구역(AreaK) 가까이 있으면 이 기준선이 AreaK를 가로지를 수 있어, 계산된 자리가
    /// 제외 구역 안이면 같은 방향으로 한 칸씩 더 밀어 구역 밖으로 나갈 때까지
    /// 반복한다.
    private func queueSlot(rank: Int) -> SIMD2<Float> {
        guard let queueOrigin, let queueDirection else { return .zero }
        var distance = Tuning.queueFrontGap + Tuning.queueSpacing * Float(rank - 1)
        var candidate = queueOrigin + queueDirection * distance
        var attempts = 0
        while staffAreaExclusions.contains(where: { $0.contains(candidate) }), attempts < 20 {
            distance += Tuning.queueSpacing * 0.5
            candidate = queueOrigin + queueDirection * distance
            attempts += 1
        }
        return candidate
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
