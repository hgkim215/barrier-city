import Foundation
import RealityKit
import simd
import OSLog

/// Indoor.usda의 Guest_* AnimationLibrary에 등록된 애니메이션 키.
/// Idle은 Barista와 동일하게 *Idle.usdz의 default subtree animation을 그대로 쓴다.
/// "Sit_to_Stand"는 AnimationLibrary def 블록 이름을 그대로 쓴 것으로, authored된
/// "Sit to Stand"라는 표시용 name과는 다르다(라이브러리 조회는 def 이름 기준).
enum NPCGuestAnimationCue: String {
    case idle = "Idle"
    case walk = "Walk"
    case sitting = "Sitting"
    case sitToStand = "Sit_to_Stand"
    case angry = "Angry"

    var repeats: Bool {
        switch self {
        case .idle, .walk, .sitting, .angry: true
        case .sitToStand: false
        }
    }
}

/// 손님 한 명이 대기줄/착석 행동에 참여하는 방식. 세 역할은 서로 섞이지 않는
/// 고정된 카테고리다.
enum NPCGuestRole {
    /// 절대 앉지 않고 계속 배회한다. 대기줄 후보.
    case alwaysWandering
    /// 좌석 이동↔착석을 반복한다: 좌석을 찾아 앉고, 15~20초(NPCGuestTuning.
    /// sittingDurationRange) 뒤 자동으로 일어나 즉시 다음 좌석으로 이동한다.
    /// 좌석 순환을 우선하므로 대기줄 후보에서는 제외된다.
    case cycler
    /// 입장 시 가능하면 이미 앉은 채로 시작하고, 한 번 앉으면 다시 일어나지 않는
    /// "그냥 앉아만 있는" 손님이다. 좌석이 부족해 배회로 시작하더라도 자리를
    /// 잡으면 그 뒤로는 영구히 앉아있는다. 대기줄 후보에서는 항상 제외된다.
    case seatedPool
}

/// 성별에 따라 재생할 한숨(sigh) 효과음 리소스가 갈린다.
enum NPCGuestGender {
    case male
    case female

    var sighResourceName: String {
        switch self {
        case .male: "male_sigh"
        case .female: "female_sigh"
        }
    }
}

/// 좌석 요청과 함께 현재 순회에서 이미 배정받았던 좌석들을 전달한다. 가능한 좌석이
/// 남아 있으면 모두 피해서 cycler가 두 자리만 왕복하지 않고 새로운 자리로 이동한다.
struct NPCGuestSeatRequest {
    let excludedSeatIndices: Set<Int>
}

/// 손님 NPC 한 명의 배치·이동·애니메이션을 담당한다. 대화·근접 감지는 다루지 않는
/// 순수 동선 담당 컨트롤러로, 대화까지 책임지는 NPCClerkController와 역할을 분리한다.
@MainActor
final class NPCGuestController {
    enum NPCGuestTuning {
        static let turnResponse: Float = 6
        static let arrivalDistance: Float = 0.05
        static let queueArrivalDistance: Float = 0.12
        static let minimumRoamDistance: Float = 0.8
        /// Blender/RealityKit 축 변환 보정용. 모델의 정면이 다르면 이 값을 조정한다.
        static let forwardYawOffset: Float = .pi
        /// 가구 회피 레이 폭 방향 샘플 간격(콜리전 박스 절반 폭과 대략 맞춘다).
        static let bodyHalfWidth: Float = 0.2
        /// 원하는 이동 폭 대비 실제로 이동 가능한 폭이 이 비율보다 작으면 "막혔다"로
        /// 보고 현재 목적지를 버려 벽/가구 앞에서 제자리걸음하지 않게 한다. 너무 낮으면
        /// (예전 0.15) 가구 모서리에 살짝 걸려 15~35%만 전진하는 경우를 "막힘"으로 못
        /// 잡아내, 실제로는 거의 못 나아가면서도 Walk 애니메이션만 계속 재생되는 것처럼
        /// 보였다.
        static let blockedStepFraction: Float = 0.4
        /// 이 시간(초) 동안의 순 이동 거리가 stallMinimumDistance보다 작으면 "제자리
        /// 걸음"으로 본다. blockedStepFraction은 프레임 하나만 보지만, 장애물에 얕은
        /// 각도로 걸려 매 프레임 방향이 조금씩 상쇄되면(예: 밀렸다 되밀렸다) 프레임별
        /// 이동량은 40%를 넘어 "막힘"으로 안 잡히면서도 몇 초간 순 이동은 거의 없는
        /// 경우가 있었다 — Walk 애니메이션은 계속 재생되는데 실제로는 흔들리기만 하고
        /// 거의 안 나아가는 것처럼 보였다.
        static let stallCheckInterval: Float = 1.2
        /// 가장 느린 손님(moveSpeed 0.68m/s)도 이 시간 동안 정상적으로는 훨씬 더
        /// 멀리 가므로, 이보다 적게 나아갔으면 확실히 막힌 것으로 본다.
        static let stallMinimumDistance: Float = 0.15
        /// 자유 배회 목적지끼리 이 정도 간격을 우선 확보한다.
        static let preferredTargetSeparation: Float = 1.35
        /// 막힘 후 주변 360도를 탐색할 거리와, 실제 escape로 인정할 최소 이동 거리.
        /// 좌석 배정 여부와 무관하게 이 거리만큼 안전한 방향으로 먼저 빠져나간 뒤
        /// 원래 행동(다음 좌석 요청/배회/대기줄)을 재개한다.
        static let escapeProbeDistance: Float = 1.0
        static let escapeMinimumDistance: Float = 0.2
        /// 좌석으로 가는 A* 경로가 군중 조향 때문에 가구 경계에 밀렸을 때 좌석을 바로
        /// 반납하지 않고, 열린 옆 방향으로 빠진 뒤 같은 좌석 경로를 다시 잡는 최대 횟수.
        static let maximumSeatGeometryRecoveryAttempts = 3
        /// cycler가 한 좌석에 계속 앉아있는 시간(초). 이 시간이 지나면 자동으로
        /// 일어나 즉시 다음 좌석을 찾는다 — 카페가 계속 사람이 들고 나는 느낌을
        /// 주기 위함이다. cycler는 2명이라 이 순환에 참여하는 인원이 동시에 2명을
        /// 넘는 일은 구조적으로 없다.
        static let sittingDurationRange: ClosedRange<Float> = 15...20
        /// 애니메이션 리소스의 duration을 읽지 못했을 때만 쓰는 착석/기립 전환 시간.
        /// 정상 경로에서는 Sit_to_Stand 클립의 실측 duration을 양방향 모두 사용한다.
        static let seatingTransitionFallbackDuration: Float = 1.0
    }

    private enum SeatState {
        case none
        case movingToSeat
        /// Sit_to_Stand를 역재생해 서 있는 자세에서 앉은 자세로 전환하는 구간.
        case sittingDown
        case sitting
        /// Sit_to_Stand 정방향 애니메이션이 재생되는 짧은 구간. 실제 클립 duration
        /// 동안 다음 좌석 이동을 시작하지 않아 애니메이션이 끊기지 않는다.
        case standingUp
    }

    /// 전원이 같은 속도와 정지 주기로 움직이면 군무처럼 보인다. 손님마다 생성 시 한 번
    /// 서로 다른 보행 성향을 부여해 이후 프레임에서는 안정적으로 유지한다.
    private struct MovementProfile {
        let moveSpeed: Float
        let pauseRange: ClosedRange<Float>
        let personalSpace: Float
        let separationStrength: Float
        let separationSide: Float
        /// 좌석 부족으로 배회 중인 seatedPool이 목적지에 도착했을 때 착석을 다시
        /// 시도할 확률. cycler는 확률 없이 항상 즉시 다음 좌석을 요청한다.
        let sitDesireChance: Float

        static func random() -> MovementProfile {
            let pauseMinimum = Float.random(in: 0.7...2.2)
            return MovementProfile(
                moveSpeed: Float.random(in: 0.68...1.02),
                pauseRange: pauseMinimum...Float.random(in: 3.8...7.0),
                personalSpace: Float.random(in: 0.62...0.82),
                separationStrength: Float.random(in: 0.85...1.25),
                separationSide: Bool.random() ? 1 : -1,
                sitDesireChance: Float.random(in: 0.55...0.9))
        }
    }

    private static let movementLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "NPCGuestMovement")

    private(set) var name: String
    let role: NPCGuestRole
    let gender: NPCGuestGender
    private var locomotionRoot: Entity?
    private var modelEntity: Entity?
    private var animationPlayback: AnimationPlaybackController?
    private var currentCue: NPCGuestAnimationCue?
    private var wanderTarget: SIMD2<Float>?
    /// NPCGuestPathfinder가 찾은, wanderTarget(또는 좌석)까지 순서대로 밟아갈 웨이포인트
    /// 목록. 첫 번째 원소가 다음 목표이고, 마지막 원소는 항상 최종 목적지와 같다.
    /// moveAlongPath가 도착한 웨이포인트를 하나씩 지워 나간다.
    private var activePath: [SIMD2<Float>] = []
    /// 막힘이 발생하면 좌석 배정/역할보다 우선하는 명시적 탈출 단계로 들어간다.
    /// escapeTarget은 주변 레이 검사로 실제 뚫린 방향에서만 고르고, 도착하기 전에는
    /// cycler도 새 좌석을 요청하지 않는다.
    private var escapeRequested = false
    private var escapeTarget: SIMD2<Float>?
    /// 방금 막힌 이동 방향. escape 후보가 같은 방향을 다시 고르지 않도록 보존한다.
    private var lastBlockedDirection: SIMD2<Float>?
    private var pauseRemaining: Float = 0
    /// "제자리걸음" 감지용(NPCGuestTuning.stallCheckInterval 참고). move()의 목적지가
    /// 바뀌면(새 배회 목적지, 좌석 이동 시작 등) 그 즉시 리셋해, 정상적으로 도착한 뒤
    /// 다음 다리를 걷기 시작하는 것까지 오탐하지 않게 한다.
    private var stallCheckTarget: SIMD2<Float>?
    private var stallCheckTimer: Float = 0
    private var stallCheckStartPosition: SIMD2<Float>?
    private let movementProfile: MovementProfile

    private var seatState: SeatState = .none
    private var claimedSeatIndex: Int?
    private var claimedSeat: GuestSeat?
    /// 착석 경로 중 sceneGeometry에 막혀 좌석 소유권을 유지한 채 수행한 국소 우회 횟수.
    /// 새 좌석을 배정받거나 실제 착석을 시작하면 0으로 초기화한다.
    private var seatGeometryRecoveryAttempts = 0
    /// cycler가 현재 좌석 순회에서 이미 배정받은 좌석들. 실제 착석 전에 접근에
    /// 실패한 자리도 포함해 같은 막힌 자리를 곧장 다시 배정받는 루프를 끊는다.
    /// 코디네이터가 이 집합 밖의 빈 좌석을 모두 소진해 폴백 좌석을 배정하면
    /// grantSeat에서 새 순회로 리셋한다.
    private var visitedSeatIndices: Set<Int> = []
    /// seatState == .sittingDown 동안 Sit_to_Stand 역재생이 끝날 때까지 남은 시간.
    private var sittingDownRemaining: Float?
    private var sittingDownDuration: Float?
    /// 착석/기립 전환 중 실제 좌석과 보행 가능한 접근점 사이 XZ 보간의 서 있는 쪽 끝점.
    private var seatTransitionStandingPosition: SIMD2<Float>?
    /// cycler가 착석한 뒤 자동으로 일어날 때까지 남은 시간(초). role == .cycler로
    /// 착석했을 때만 값이 채워진다 — seatedPool은 영구 착석이라 항상 nil이다.
    private var sittingRemaining: Float?
    /// seatState == .standingUp 동안 Sit_to_Stand 애니메이션이 끊기지 않도록 두는
    /// 남은 시간(초).
    private var standingUpRemaining: Float?
    private var standingUpDuration: Float?
    /// 코디네이터가 다음 프레임에 한 번만 소비하는 원샷 신호. 착석을 원한다는 요청과,
    /// 방금 자리를 비웠다는 통지에 쓴다(takeSeatRequest/takeVacatedSeatIndex 참고).
    private var pendingSeatRequest: NPCGuestSeatRequest?
    private var pendingVacatedSeatIndex: Int?
    /// 좌석까지 실제로 걸어가 도착한(=진짜로 앉은) 프레임에 한 번만 서는 원샷 신호
    /// (takeSeatedArrivalSeatIndex). grantSeat 시점이 아니라 이 시점에 코디네이터가
    /// 디저트를 놓아야, 걸어가다 막혀 자리를 반납해도(vacate) 아무도 없는 테이블에
    /// 디저트만 남는 일이 없다.
    private var pendingSeatedArrivalIndex: Int?
    /// 대기줄 자리에 막 도착한 프레임에 한 번만 서는 원샷 신호(takeQueueArrivalSignal).
    private var pendingQueueArrival = false
    /// pendingQueueArrival을 한 번만 세우기 위한 상태 추적(도착해 있는 동안 매 프레임
    /// 다시 세우지 않도록).
    private var hasReportedQueueArrival = false
    /// 이번 프레임까지의 "실제" 이동 속도(m/s, 바닥 평면). commanded 속도
    /// (movementProfile.moveSpeed)가 아니라 update() 전후 위치 변화량 기반으로
    /// 매 프레임 갱신된다(updateVelocity 참고) — 장애물에 막혀 실제로는 거의 못
    /// 움직이는 NPC가 다른 NPC의 예측 회피(NPCGuestLocalAvoidance)에는 "빠르게
    /// 다가오는 대상"으로 잘못 보이지 않게 하기 위함이다. NPCGuestCoordinator.update가
    /// 프레임 시작 시점에 전원의 값을 한 번에 스냅샷해 이웃 배열로 넘긴다.
    private(set) var velocity: SIMD2<Float> = .zero
    private static var cachedSighResources: [NPCGuestGender: AudioFileResource] = [:]

    init(name: String, role: NPCGuestRole = .cycler, gender: NPCGuestGender = .female) {
        self.name = name
        self.role = role
        self.gender = gender
        movementProfile = .random()
    }

    /// cycler는 항상 다음 좌석을 우선하므로 대기줄로 전환하지 않는다. 순수 배회 역할만
    /// 대기줄 후보가 된다.
    var isQueueEligible: Bool {
        role == .alwaysWandering && seatState == .none
    }

    /// 코디네이터가 이번 프레임에 착석 요청을 한 번 읽고 소비한다. cycler 요청이 빈
    /// 좌석 부족으로 처리되지 못하면 다음 프레임에 다시 생성되어 유실되지 않는다.
    func takeSeatRequest() -> NPCGuestSeatRequest? {
        defer { pendingSeatRequest = nil }
        return pendingSeatRequest
    }

    /// 코디네이터가 빈 좌석을 찾아 배정할 때 호출한다.
    func grantSeat(index: Int, seat: GuestSeat) {
        if role == .cycler {
            if visitedSeatIndices.contains(index) {
                // 현재 비어 있는 미방문 좌석을 모두 소진해 코디네이터가 폴백한
                // 경우다. 이번 좌석을 새 순회의 첫 자리로 삼는다.
                visitedSeatIndices = [index]
            } else {
                visitedSeatIndices.insert(index)
            }
        }
        claimedSeatIndex = index
        claimedSeat = seat
        seatState = .movingToSeat
        seatGeometryRecoveryAttempts = 0
        sittingDownRemaining = nil
        sittingDownDuration = nil
        sittingRemaining = nil
        standingUpRemaining = nil
        standingUpDuration = nil
        wanderTarget = nil
        activePath = []
        escapeRequested = false
        escapeTarget = nil
        lastBlockedDirection = nil
        pauseRemaining = 0
        seatTransitionStandingPosition = nil
        pendingSeatRequest = nil
        pendingSeatedArrivalIndex = nil
    }

    /// 방금 자리를 비웠으면 그 좌석 인덱스를 반환하고 소비한다. 코디네이터가 이걸로
    /// seatOccupants를 비운다.
    func takeVacatedSeatIndex() -> Int? {
        defer { pendingVacatedSeatIndex = nil }
        return pendingVacatedSeatIndex
    }

    /// 방금 좌석에 실제로 도착해 앉았으면 그 좌석 인덱스를 반환하고 소비한다.
    /// 코디네이터가 이걸로 그제서야 디저트를 배정한다.
    func takeSeatedArrivalSeatIndex() -> Int? {
        defer { pendingSeatedArrivalIndex = nil }
        return pendingSeatedArrivalIndex
    }

    /// 대기줄 자리에 막 도착했으면(이번 대기 세션 중 처음 한 번만) true를 반환하고
    /// 소비한다.
    func takeQueueArrivalSignal() -> Bool {
        defer { pendingQueueArrival = false }
        return pendingQueueArrival
    }

    /// 성별에 맞는 한숨 소리를 자신의 위치에서 한 번 재생한다(공간 음향이라 유저
    /// 뒤에서 나는 것처럼 들린다). 리소스는 타입 전체가 공유하는 캐시에 한 번만
    /// 로드해 재사용한다.
    func playSigh() {
        guard let root = locomotionRoot else { return }
        let gender = self.gender
        Task { @MainActor in
            let resource: AudioFileResource
            if let cached = Self.cachedSighResources[gender] {
                resource = cached
            } else {
                guard let url = Bundle.main.url(forResource: gender.sighResourceName, withExtension: "mp3"),
                      let loaded = try? await AudioFileResource(
                        contentsOf: url, configuration: .init(shouldLoop: false)) else { return }
                resource = loaded
                Self.cachedSighResources[gender] = loaded
            }
            root.playAudio(resource)
        }
    }

    /// locomotion wrapper 생성과 발 기준 정렬을 공통화한다(place/placeSeated 공용).
    private func setUpLocomotionRoot(entity: Entity, worldRoot: Entity, at position: SIMD2<Float>) {
        entity.removeFromParent()

        let locomotion = Entity()
        locomotion.name = "\(name)LocomotionRoot"
        locomotion.position = [position.x, 0, position.y]

        let modelAlignment = Entity()
        modelAlignment.name = "\(name)ModelAlignment"
        modelAlignment.addChild(entity)
        locomotion.addChild(modelAlignment)
        let bounds = entity.visualBounds(relativeTo: modelAlignment)
        modelAlignment.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]

        entity.applyNPCBodyCollision(group: AppModel.npcGroup)

        worldRoot.addChild(locomotion)
        locomotionRoot = locomotion
        modelEntity = entity
        wanderTarget = nil
    }

    /// Indoor.usda에서 찾은 손님 엔티티를 이동 wrapper로 감싸 worldRoot에 배치한다.
    /// Barista 배치(NPCClerkController.enterIndoor)와 동일한 발 기준 정렬 방식을 쓴다.
    func place(entity: Entity, worldRoot: Entity, at position: SIMD2<Float>) {
        setUpLocomotionRoot(entity: entity, worldRoot: worldRoot, at: position)
        // 진입 직후 전원이 동시에 걷기 시작하지 않도록 첫 출발 시점을 넓게 흩뜨린다.
        pauseRemaining = Float.random(in: 0...4.5)
        playAnimation(.idle)
    }

    /// 입장 시점부터 이미 지정된 좌석에 앉아있는 상태로 배치한다(seatedPool 역할용).
    /// 걸어가는 과정 없이 좌석 위치/방향으로 바로 배치한다. 한 번 앉으면 다시
    /// 일어나지 않으므로 별도의 착석 지속 시간은 두지 않는다.
    func placeSeated(entity: Entity, worldRoot: Entity, seatIndex: Int, seat: GuestSeat) {
        setUpLocomotionRoot(entity: entity, worldRoot: worldRoot, at: seat.position)
        pauseRemaining = 0
        claimedSeatIndex = seatIndex
        claimedSeat = seat
        seatState = .sitting
        seatGeometryRecoveryAttempts = 0
        sittingDownRemaining = nil
        sittingDownDuration = nil
        sittingRemaining = nil
        standingUpRemaining = nil
        standingUpDuration = nil
        seatTransitionStandingPosition = nil
        pendingSeatRequest = nil
        face(direction: seat.facing, deltaTime: 999)
        playAnimation(.sitting)
        locomotionRoot?.position.y = seat.sittingHeightOffset
    }

    func teardown() {
        animationPlayback?.stop()
        animationPlayback = nil
        locomotionRoot?.removeFromParent()
        locomotionRoot = nil
        modelEntity = nil
        currentCue = nil
        wanderTarget = nil
        activePath = []
        escapeRequested = false
        escapeTarget = nil
        lastBlockedDirection = nil
        seatState = .none
        claimedSeatIndex = nil
        claimedSeat = nil
        seatGeometryRecoveryAttempts = 0
        visitedSeatIndices = []
        sittingDownRemaining = nil
        sittingDownDuration = nil
        sittingRemaining = nil
        standingUpRemaining = nil
        standingUpDuration = nil
        seatTransitionStandingPosition = nil
        pendingSeatRequest = nil
        pendingVacatedSeatIndex = nil
        pendingSeatedArrivalIndex = nil
        pendingQueueArrival = false
        hasReportedQueueArrival = false
        velocity = .zero
    }

    var currentPosition: SIMD2<Float> {
        guard let root = locomotionRoot else { return .zero }
        return SIMD2(root.position.x, root.position.z)
    }

    /// 다른 손님이 다음 목적지를 고를 때 현재 위치뿐 아니라 이미 선택된 목적지도 피한다.
    var crowdAnchor: SIMD2<Float> { wanderTarget ?? currentPosition }

    /// 지금 실제로 Walk 애니메이션 중인지. 코디네이터가 동시 배회 인원(최대 3명)을
    /// 세는 데 쓴다.
    var isWalking: Bool { currentCue == .walk }

    /// queueSlot이 있으면 그 지점으로 이동해 대기하고, 없으면 movementContext가
    /// 이동 의도별로 선택한 제외 구역을 적용한다. 호출부는 더 이상 roaming/staff
    /// 배열을 따로 넘기지 않아 좌석 접근에 잘못된 목록을 전달할 수 없다.
    func update(deltaTime: Float,
               movementContext: NPCGuestMovementContext,
               pathGrid: NPCGuestPathfinder.WalkableGrid?,
               queueSlot: SIMD2<Float>?,
               facing facingTarget: SIMD2<Float>?,
               playerPosition: SIMD2<Float>,
               neighboringPositions: [SIMD2<Float>],
               neighboringVelocities: [SIMD2<Float>],
               occupiedAnchors: [SIMD2<Float>],
               allowNewWander: Bool) {
        guard locomotionRoot != nil else { return }

        // update()의 어느 분기로 빠지든(착석/기립/대기줄/배회/좌석 이동) 공통으로
        // "이번 호출에서 실제로 얼마나 움직였는지"를 재서 velocity를 갱신한다.
        // 각 분기마다 따로 호출하는 대신 defer 하나로 모든 반환 경로를 커버한다.
        let positionBeforeUpdate = currentPosition
        defer { updateVelocity(from: positionBeforeUpdate, deltaTime: deltaTime) }

        switch seatState {
        case .movingToSeat:
            updateMovingToSeat(deltaTime: deltaTime,
                               movementContext: movementContext,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               neighboringVelocities: neighboringVelocities,
                               pathGrid: pathGrid)
            return
        case .sittingDown:
            guard var remaining = sittingDownRemaining else {
                finishSittingDown()
                return
            }
            remaining -= deltaTime
            updateSeatTransitionPose(
                remaining: remaining,
                duration: sittingDownDuration,
                isSittingDown: true)
            if remaining > 0 {
                sittingDownRemaining = remaining
                return
            }
            finishSittingDown()
            return
        case .sitting:
            // seatedPool은 sittingRemaining이 nil이라 여기서 끝 — 영구 착석.
            guard var remaining = sittingRemaining else { return }
            remaining -= deltaTime
            if remaining > 0 {
                sittingRemaining = remaining
                return
            }
            standUpAndResumeWandering()
            return
        case .standingUp:
            guard var remaining = standingUpRemaining else {
                completeStandingUp()
                return
            }
            remaining -= deltaTime
            updateSeatTransitionPose(
                remaining: remaining,
                duration: standingUpDuration,
                isSittingDown: false)
            if remaining > 0 {
                standingUpRemaining = remaining
                return
            }
            completeStandingUp()
            return
        case .none:
            break
        }

        // 외부 transform 변경이나 막힘 후 회피는 역할/좌석 배정/대기줄보다 우선한다.
        // cycler가 좌석을 반납한 직후에도 먼저 안전한 방향으로 빠져나간 뒤에야 새
        // 좌석을 요청한다.
        let requiresRecovery = !NPCGuestNavigation.isValid(
            currentPosition,
            inside: movementContext.floor,
            excluding: movementContext.exclusions(for: .roaming))
        if requiresRecovery, !escapeRequested, escapeTarget == nil {
            beginEscape()
        }
        if escapeRequested || escapeTarget != nil {
            updateEscaping(
                deltaTime: deltaTime,
                movementContext: movementContext,
                playerPosition: playerPosition,
                neighboringPositions: neighboringPositions,
                neighboringVelocities: neighboringVelocities)
            return
        }

        // cycler는 배회/확률 판정을 거치지 않는다. 좌석이 잠시 부족하더라도 매 프레임
        // 요청을 복구해 빈 자리가 생기는 즉시 곧장 이동한다.
        if role == .cycler {
            if pendingSeatRequest == nil {
                pendingSeatRequest = NPCGuestSeatRequest(excludedSeatIndices: visitedSeatIndices)
            }
            playAnimation(.idle)
            return
        }

        if let queueSlot {
            // 대기줄은 의도적으로 유저 바로 뒤까지 다가가야 하므로, 평소 배회에서
            // 유저 몸에 안 걸어 들어가게 막는 반경 회피는 여기서만 끈다. 전체 배회
            // 제외 구역은 넘기지 않되 AreaK/AreaB만 유지한다 — 키오스크 주변 반경은
            // 줄서기와 충돌하지만 직원 전용 구역은 어떤 행동에서도 침범하면 안 된다.
            let outcome = move(toward: queueSlot, deltaTime: deltaTime,
                               movementContext: movementContext,
                               intent: .queueing,
                               arrivalDistance: NPCGuestTuning.queueArrivalDistance,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               neighborVelocities: neighboringVelocities,
                               separationScale: 0.35,
                               avoidPlayer: false)
            if outcome.arrived {
                // 대기줄에 서서 기다리는 동안은 살짝 짜증난 티를 낸다(Idle 대신 Angry 루프).
                playAnimation(.angry)
                if let facingTarget { face(point: facingTarget, deltaTime: deltaTime) }
                if !hasReportedQueueArrival {
                    hasReportedQueueArrival = true
                    pendingQueueArrival = true
                }
            } else {
                if outcome.blocked {
                    beginEscape()
                    playAnimation(.idle)
                } else {
                    playAnimation(outcome.moved ? .walk : .idle)
                }
            }
            return
        }
        hasReportedQueueArrival = false

        if pauseRemaining > 0 {
            pauseRemaining = max(0, pauseRemaining - deltaTime)
            playAnimation(.idle)
            return
        }
        if wanderTarget == nil {
            // 이미 걷고 있던 배회를 마저 이어가는 건 막지 않는다 — 여기서 막는 건
            // "새로 걷기 시작하는" 순간뿐이다. 그래야 동시 배회 인원을 최대 3명으로
            // 눌러도 이미 걷던 손님이 벽 앞에서 뚝 멈춰버리지 않는다.
            guard allowNewWander || requiresRecovery else {
                playAnimation(.idle)
                return
            }
            wanderTarget = randomWanderTarget(
                in: movementContext.floor,
                excluding: movementContext.exclusions(for: .roaming),
                awayFrom: currentPosition,
                avoiding: occupiedAnchors)
            activePath = requestPath(to: wanderTarget, grid: pathGrid)
        }
        guard wanderTarget != nil else {
            playAnimation(.idle)
            return
        }
        let outcome = moveAlongPath(deltaTime: deltaTime,
                                    movementContext: movementContext,
                                    intent: .roaming,
                                    arrivalDistance: NPCGuestTuning.arrivalDistance,
                                    playerPosition: playerPosition,
                                    neighboringPositions: neighboringPositions,
                                    neighborVelocities: neighboringVelocities,
                                    separationScale: 1)
        if outcome.blocked {
            beginEscape()
            playAnimation(.idle)
            return
        }
        if outcome.arrived {
            wanderTarget = nil
            activePath = []
            pauseRemaining = Float.random(in: movementProfile.pauseRange)
            playAnimation(.idle)
            // 좌석 부족으로 배회하는 seatedPool만 목적지 도착 시 재시도한다. cycler는
            // 이 경로에 들어오지 않고 항상 즉시 다음 좌석을 요청한다.
            if role == .seatedPool, Float.random(in: 0...1) < movementProfile.sitDesireChance {
                pendingSeatRequest = NPCGuestSeatRequest(excludedSeatIndices: [])
            }
        } else {
            // 실제로 위치가 움직인 프레임에만 Walk를 재생한다. 장애물에 막혀 제자리인
            // 프레임까지 Walk를 계속 재생하면 제자리걸음처럼 보인다.
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    // MARK: - Seating

    /// cycler 전용: 앉아있던 시간이 다 되면 기립 전환을 시작한다. 실제 좌석 반납과
    /// 다음 좌석 요청은 애니메이션이 끝난 프레임에 함께 처리한다.
    private func standUpAndResumeWandering() {
        let transitionDuration: Float
        if let animationDuration = playSitTransition(reversed: false) {
            transitionDuration = animationDuration
        } else {
            transitionDuration = NPCGuestTuning.seatingTransitionFallbackDuration
            playAnimation(.idle)
        }
        // claimedSeatIndex/claimedSeat는 여기서 비우지 않는다 — 기립 애니메이션이
        // 끝나 실제로 자리를 벗어날 때(.standingUp 완료 시점, update() 참고)까지는
        // 이 손님의 몸이 여전히 그 좌석 위치에 있다. 그 전에 코디네이터에 "비었다"고
        // 통지하면 다른 손님이 아직 사람이 서 있는 자리로 걸어오게 된다.
        seatState = .standingUp
        sittingRemaining = nil
        standingUpRemaining = transitionDuration
        standingUpDuration = transitionDuration
        seatTransitionStandingPosition = claimedSeat?.approachPosition
        wanderTarget = nil
        activePath = []
        pauseRemaining = 0
    }

    /// 기립 애니메이션이 끝난 위치를 가구 밖의 보행 가능 접근점으로 확정한 뒤에만
    /// 좌석을 반납한다. 이전처럼 SittingPoint에서 다음 경로의 첫 셀까지 충돌을 끄고
    /// 걸어 나가지 않으므로 가구 관통이 발생하지 않는다.
    private func completeStandingUp() {
        standingUpRemaining = nil
        standingUpDuration = nil
        if let seat = claimedSeat, let root = locomotionRoot {
            root.position = SIMD3(seat.approachPosition.x, 0, seat.approachPosition.y)
        } else {
            locomotionRoot?.position.y = 0
        }
        seatTransitionStandingPosition = nil
        seatState = .none
        let vacatedSeatIndex = vacateClaimedSeat()
        requestNextSeatIfCycler(excluding: vacatedSeatIndex)
    }

    /// 지금 붙잡고 있는 좌석(있다면)을 실제로 놓아준다 — pendingVacatedSeatIndex로
    /// 코디네이터에 통지해 seatOccupants를 비우게 한다. 반드시 이 손님의 몸이 그
    /// 좌석 위치를 실제로 벗어난(또는 애초에 도착한 적 없는) 시점에만 불러야 한다
    /// — 기립 애니메이션 도중처럼 아직 그 자리에 있는 동안 부르면 다른 손님이
    /// 사람이 서 있는 자리로 걸어오는 원인이 된다(standUpAndResumeWandering 주석
    /// 참고).
    @discardableResult
    private func vacateClaimedSeat() -> Int? {
        let vacatedSeatIndex = claimedSeatIndex
        pendingVacatedSeatIndex = claimedSeatIndex
        claimedSeatIndex = nil
        claimedSeat = nil
        return vacatedSeatIndex
    }

    /// cycler는 좌석을 비운 프레임에 즉시 다음 좌석을 요청한다. 직전 좌석 하나가
    /// 아니라 이번 순회에서 이미 배정받았던 좌석 전체를 보내 두 자리 왕복과
    /// 접근 실패 좌석의 즉시 재배정을 함께 막는다.
    private func requestNextSeatIfCycler(excluding seatIndex: Int?) {
        guard role == .cycler else { return }
        if let seatIndex { visitedSeatIndices.insert(seatIndex) }
        pendingSeatRequest = NPCGuestSeatRequest(excludedSeatIndices: visitedSeatIndices)
    }

    /// 좌석 자체(SittingPoint)는 가구 콜리전 내부일 수 있으므로 그 지점까지 걷지 않는다.
    /// Coordinator가 미리 계산한 좌석 뒤 보행 가능 접근점까지만 A*와 씬 충돌을 모두
    /// 유지한 채 걷고, 접근점↔좌석의 짧은 구간은 착석/기립 애니메이션 진행률에 맞춰
    /// 보간한다. 접근점이 없는 깊은 좌석은 애초에 배정 후보에서 제외된다.
    private func updateMovingToSeat(deltaTime: Float,
                                    movementContext: NPCGuestMovementContext,
                                    playerPosition: SIMD2<Float>,
                                    neighboringPositions: [SIMD2<Float>],
                                    neighboringVelocities: [SIMD2<Float>],
                                    pathGrid: NPCGuestPathfinder.WalkableGrid?) {
        guard let seat = claimedSeat else {
            let vacatedSeatIndex = vacateClaimedSeat()
            activePath = []
            seatState = .none
            requestNextSeatIfCycler(excluding: vacatedSeatIndex)
            return
        }
        if activePath.isEmpty {
            guard let path = requestCollisionSafeSeatPath(
                to: seat.approachPosition,
                grid: pathGrid)
            else {
                // A*가 "연결된 경로 없음"을 반환했는데 목적지 하나만 넣어 직선으로
                // 걸으면, 결국 중간의 테이블/카운터 경계까지 간 뒤 sceneGeometry로
                // 멈춘다. 좌석 이동은 그런 fallback을 절대 쓰지 않는다.
                vacateSeatDueToBlockage(reason: .pathUnavailable)
                return
            }
            activePath = path
        }
        let isFinalApproachWaypoint = activePath.count == 1
        let outcome = moveAlongPath(deltaTime: deltaTime,
                                    movementContext: movementContext,
                                    intent: .seating,
                                    arrivalDistance: NPCGuestTuning.queueArrivalDistance,
                                    playerPosition: playerPosition,
                                    neighboringPositions: neighboringPositions,
                                    neighborVelocities: neighboringVelocities,
                                    separationScale: 0.5,
                                    // 좌석으로 걸어가는 짧고 목적이 분명한 구간에서는
                                    // 예측 회피를 아예 끈다 — move()의 usePredictiveAvoidance
                                    // 주석 참고. crowdSteeredDirection(즉시 반발)과
                                    // NPCObstacleAvoidance(하드 세이프티 넷)는 그대로
                                    // 적용되므로 다른 손님/유저와 실제로 겹치지는 않는다.
                                    usePredictiveAvoidance: false)
        if outcome.blocked {
            let canBeginFromBlockedApproach =
                NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                    currentPosition: currentPosition,
                    seatPosition: seat.position,
                    approachPosition: seat.approachPosition,
                    seatFacing: seat.facing,
                    isFinalWaypoint: isFinalApproachWaypoint,
                    isSceneGeometryBlock: outcome.blockReason == .sceneGeometry)
            if canBeginFromBlockedApproach {
                Self.movementLogger.notice(
                    "\(self.name, privacy: .public) 좌석 \(self.claimedSeatIndex ?? -1, privacy: .public) 근접 착석 전환(sceneGeometry, approachDistance=\(simd_distance(self.currentPosition, seat.approachPosition), privacy: .public))")
                beginSittingDown(at: seat)
                return
            }
            if outcome.blockReason == .sceneGeometry,
               scheduleSeatGeometryRecovery(
                   toward: seat,
                   movementContext: movementContext,
                   playerPosition: playerPosition,
                   neighboringPositions: neighboringPositions,
                   pathGrid: pathGrid) {
                playAnimation(.idle)
                return
            }
            vacateSeatDueToBlockage(reason: outcome.blockReason)
            return
        }
        if outcome.arrived {
            beginSittingDown(at: seat)
        } else {
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    /// 정상 도착과 sceneGeometry 근접 도착이 반드시 같은 상태 전이를 타도록 착석 시작을
    /// 한곳에 모은다. 호출 시점의 실제 위치를 서 있는 쪽 끝점으로 보존하므로 애니메이션
    /// 동안 그 위치에서 SittingPoint까지 자연스럽게 보간된다.
    private func beginSittingDown(at seat: GuestSeat) {
        seatState = .sittingDown
        seatGeometryRecoveryAttempts = 0
        face(direction: seat.facing, deltaTime: 999)
        seatTransitionStandingPosition = currentPosition
        activePath = []
        stallCheckTarget = nil
        stallCheckTimer = 0
        stallCheckStartPosition = nil
        if let transitionDuration = playSitTransition(reversed: true) {
            sittingDownRemaining = transitionDuration
            sittingDownDuration = transitionDuration
        } else {
            // 리소스 누락 시 상태 머신이 sittingDown에 영구 정지하지 않도록 즉시
            // Sitting 루프로 폴백한다.
            finishSittingDown()
        }
    }

    /// 정적 가구에 한 번 닿았다고 좌석을 포기하지 않는다. 방금 막힌 방향과 60도 이상
    /// 다른 열린 방향으로 먼저 빠진 다음, 그 지점에서 같은 좌석 접근점까지 A*를 다시
    /// 연결한다. detourTarget을 경로의 첫 웨이포인트로 명시해 현재 가구 경계에서 실제로
    /// 떨어져 나온 뒤에만 재탐색 경로로 합류한다.
    private func scheduleSeatGeometryRecovery(
        toward seat: GuestSeat,
        movementContext: NPCGuestMovementContext,
        playerPosition: SIMD2<Float>,
        neighboringPositions: [SIMD2<Float>],
        pathGrid: NPCGuestPathfinder.WalkableGrid?
    ) -> Bool {
        guard seatGeometryRecoveryAttempts < NPCGuestTuning.maximumSeatGeometryRecoveryAttempts,
              let pathGrid,
              let detourTarget = nearbyEscapeTarget(
                  from: currentPosition,
                  in: movementContext.floor,
                  excluding: movementContext.exclusions(for: .seating),
                  playerPosition: playerPosition,
                  neighboringPositions: neighboringPositions,
                  avoidingDirection: lastBlockedDirection),
              let returnPath = NPCGuestPathfinder.findPath(
                  from: detourTarget,
                  to: seat.approachPosition,
                  in: pathGrid)
        else { return false }

        var recoveryPath = [detourTarget]
        for waypoint in returnPath {
            guard let last = recoveryPath.last,
                  simd_distance(last, waypoint) > NPCGuestTuning.arrivalDistance else { continue }
            recoveryPath.append(waypoint)
        }
        guard let finalWaypoint = recoveryPath.last,
              simd_distance(finalWaypoint, seat.approachPosition) <= 0.001 else { return false }

        seatGeometryRecoveryAttempts += 1
        activePath = recoveryPath
        stallCheckTarget = nil
        stallCheckTimer = 0
        stallCheckStartPosition = nil
        Self.movementLogger.notice(
            "\(self.name, privacy: .public) 좌석 \(self.claimedSeatIndex ?? -1, privacy: .public) 접근 국소 우회 \(self.seatGeometryRecoveryAttempts, privacy: .public)/\(NPCGuestTuning.maximumSeatGeometryRecoveryAttempts, privacy: .public), 우회점=(\(detourTarget.x, privacy: .public), \(detourTarget.y, privacy: .public))")
        return true
    }

    /// 좌석까지 걸어가는 걸 완전히 포기하고 자리를 반납한다. 시간을 두고 재시도하지
    /// 않고(코디네이터가 seatOccupants를 즉시 비워 다른 손님에게 다시 배정할 수 있게
    /// 한다), 배회 상태로 되돌린다.
    private func vacateSeatDueToBlockage(reason: MovementBlockReason?) {
        // 아직 좌석에 도착하지 못한 채(걸어가는 도중) 포기하는 경우라 이 손님의
        // 몸은 좌석 위치에 없다 — standUpAndResumeWandering과 달리 즉시 비워도
        // 안전하다.
        let approachDistance = claimedSeat.map {
            simd_distance(currentPosition, $0.approachPosition)
        } ?? -1
        let seatDistance = claimedSeat.map {
            simd_distance(currentPosition, $0.position)
        } ?? -1
        let remainingWaypointCount = activePath.count
        let recoveryAttempts = seatGeometryRecoveryAttempts
        let vacatedSeatIndex = vacateClaimedSeat()
        Self.movementLogger.notice(
            "\(self.name, privacy: .public) 좌석 접근 포기: seat=\(vacatedSeatIndex ?? -1, privacy: .public) reason=\((reason ?? .unknown).rawValue, privacy: .public) approachDistance=\(approachDistance, privacy: .public) seatDistance=\(seatDistance, privacy: .public) remainingWaypoints=\(remainingWaypointCount, privacy: .public) recoveryAttempts=\(recoveryAttempts, privacy: .public)")
        seatState = .none
        activePath = []
        seatTransitionStandingPosition = nil
        sittingDownRemaining = nil
        sittingDownDuration = nil
        pauseRemaining = 0
        if role == .cycler, let vacatedSeatIndex {
            visitedSeatIndices.insert(vacatedSeatIndex)
        }
        beginEscape()
        playAnimation(.idle)
    }

    /// Sit_to_Stand 역재생이 끝난 뒤에만 실제 착석 완료로 처리한다. 디저트 생성 신호와
    /// cycler의 15~20초 체류 타이머도 이 시점부터 시작해 전환 시간을 착석 시간에
    /// 섞지 않는다.
    private func finishSittingDown() {
        guard case .sittingDown = seatState else { return }
        guard claimedSeatIndex != nil, claimedSeat != nil else {
            let vacatedSeatIndex = vacateClaimedSeat()
            sittingDownRemaining = nil
            sittingDownDuration = nil
            seatState = .none
            requestNextSeatIfCycler(excluding: vacatedSeatIndex)
            playAnimation(.idle)
            return
        }
        sittingDownRemaining = nil
        sittingDownDuration = nil
        if let seat = claimedSeat, let root = locomotionRoot {
            root.position = SIMD3(
                seat.position.x,
                seat.sittingHeightOffset,
                seat.position.y)
        }
        seatTransitionStandingPosition = nil
        seatState = .sitting
        playAnimation(.sitting)
        pendingSeatedArrivalIndex = claimedSeatIndex
        sittingRemaining = role == .cycler
            ? Float.random(in: NPCGuestTuning.sittingDurationRange)
            : nil
    }

    /// Sit_to_Stand 클립의 진행률과 로코모션 루트 높이를 함께 보간한다. 스켈레톤
    /// 애니메이션만 역재생하고 루트 Y를 한 번에 스냅하면 착석/기립 시작점에서 몸 전체가
    /// 위아래로 튀므로, 앉을 때는 0→좌석 높이, 일어날 때는 좌석 높이→0으로 맞춘다.
    private func updateSeatTransitionPose(
        remaining: Float,
        duration: Float?,
        isSittingDown: Bool
    ) {
        guard let duration, duration > 0,
              let seat = claimedSeat,
              let root = locomotionRoot else { return }
        let remainingFraction = min(1, max(0, remaining / duration))
        let seatedFraction = isSittingDown ? 1 - remainingFraction : remainingFraction
        let standingPosition = seatTransitionStandingPosition ?? seat.approachPosition
        root.position.x = standingPosition.x + (seat.position.x - standingPosition.x) * seatedFraction
        root.position.y = seat.sittingHeightOffset * seatedFraction
        root.position.z = standingPosition.y + (seat.position.y - standingPosition.y) * seatedFraction
    }

    // MARK: - Movement

    /// arrived: 목적지에 도착(또는 이미 도착해 있었음). moved: 이번 프레임에 실제로
    /// 위치가 바뀌었는지. blocked: 장애물에 사실상 막혀 더 못 감(= 원하는 이동
    /// 폭의 일정 비율도 못 갔음, stalled도 포함) — 호출부는 이걸 보고 Walk/Idle
    /// 애니메이션을 정한다.
    ///
    /// stalled: stallCheckInterval(1.2초) 동안 순 이동이 stallMinimumDistance보다
    /// 작았는지. 한 프레임의 스텝은 충분해 보여도 제자리에서 흔들리는 경우를 잡아,
    /// blocked와 동일하게 즉시 명시적 escape 단계로 전환한다.
    private enum MovementBlockReason: String {
        case sceneGeometry
        case player
        case neighboringNPC
        case restrictedArea
        case stalled
        case pathUnavailable
        case unknown
    }

    private struct MoveOutcome {
        let arrived: Bool
        let moved: Bool
        let blocked: Bool
        let stalled: Bool
        let blockReason: MovementBlockReason?
    }

    /// 현재 행동을 버리고 주변의 실제 뚫린 방향으로 빠져나가는 단계를 예약한다.
    /// 좌석 요청도 지워 Coordinator가 escape 도중 새 좌석을 배정하지 못하게 한다.
    private func beginEscape() {
        escapeRequested = true
        escapeTarget = nil
        pendingSeatRequest = nil
        wanderTarget = nil
        activePath = []
        pauseRemaining = 0
        stallCheckTarget = nil
        stallCheckTimer = 0
        stallCheckStartPosition = nil
    }

    /// 역할과 좌석 배정 여부에 관계없이 막힘 다음 프레임부터 가장 넓게 열린 방향으로
    /// 직접 빠져나간다. 이 경로에서는 씬/유저/NPC 충돌을 모두 유지한다. escape가 끝난
    /// 뒤에만 cycler의 다음 좌석 요청을 복구한다.
    private func updateEscaping(
        deltaTime: Float,
        movementContext: NPCGuestMovementContext,
        playerPosition: SIMD2<Float>,
        neighboringPositions: [SIMD2<Float>],
        neighboringVelocities: [SIMD2<Float>]
    ) {
        if escapeTarget == nil {
            guard let target = nearbyEscapeTarget(
                from: currentPosition,
                in: movementContext.floor,
                excluding: movementContext.exclusions(for: .roaming),
                playerPosition: playerPosition,
                neighboringPositions: neighboringPositions,
                avoidingDirection: lastBlockedDirection)
            else {
                playAnimation(.idle)
                return
            }
            escapeTarget = target
            activePath = [target]
            face(point: target, deltaTime: 999)
        }

        let outcome = moveAlongPath(
            deltaTime: deltaTime,
            movementContext: movementContext,
            intent: .roaming,
            arrivalDistance: NPCGuestTuning.arrivalDistance,
            playerPosition: playerPosition,
            neighboringPositions: neighboringPositions,
            neighborVelocities: neighboringVelocities,
            separationScale: 1,
            usePredictiveAvoidance: false)
        if outcome.blocked {
            // 동적 장애물이 방향을 다시 막았으면 다음 프레임에 360도 후보를 새로 잰다.
            escapeTarget = nil
            activePath = []
            stallCheckTarget = nil
            playAnimation(.idle)
            return
        }
        if outcome.arrived {
            escapeRequested = false
            escapeTarget = nil
            activePath = []
            stallCheckTarget = nil
            lastBlockedDirection = nil
            if role == .cycler {
                requestNextSeatIfCycler(excluding: nil)
            }
            playAnimation(.idle)
            return
        }
        playAnimation(outcome.moved ? .walk : .idle)
    }

    /// grid가 있으면 NPCGuestPathfinder로 destination까지의 웨이포인트 경로를 찾는다.
    /// grid가 없거나(전달 안 됨) 경로를 못 찾으면(고립된 영역 등) 예전처럼 목적지
    /// 하나만 담은 경로로 대체한다 — move()가 직선으로 곧장 겨냥하던 것과 동일하게
    /// 동작해, 격자가 아직 없는 상황에서도 완전히 멈추지는 않는다.
    private func requestPath(to destination: SIMD2<Float>?,
                             grid: NPCGuestPathfinder.WalkableGrid?) -> [SIMD2<Float>] {
        guard let destination else { return [] }
        guard let grid,
              let path = NPCGuestPathfinder.findPath(from: currentPosition, to: destination, in: grid)
        else { return [destination] }
        return path
    }

    /// 좌석 접근에는 "경로가 없으면 목적지로 직진"하는 일반 배회 fallback을 허용하지
    /// 않는다. grid가 준비되지 않았거나 A*로 연결된 경로가 없으면 nil을 반환해 호출부가
    /// 좌석을 반납하고 탈출하도록 한다.
    private func requestCollisionSafeSeatPath(
        to destination: SIMD2<Float>,
        grid: NPCGuestPathfinder.WalkableGrid?
    ) -> [SIMD2<Float>]? {
        guard let grid else { return nil }
        return NPCGuestPathfinder.findPath(from: currentPosition, to: destination, in: grid)
    }

    /// activePath의 웨이포인트를 순서대로 밟아 최종 목적지에 도달한다. 중간
    /// 웨이포인트 도착은 "아직 도착 안 함(moved: true)"으로만 보고하고, 마지막
    /// 웨이포인트(경로의 끝, 항상 최종 목적지와 같다)에 닿아야 진짜 arrived를
    /// 반환한다 — 호출부(update/updateMovingToSeat)는 이 시점에만 도착 후속
    /// 처리(착석 시작, 다음 배회 결정 등)를 해야 한다.
    private func moveAlongPath(deltaTime: Float,
                               movementContext: NPCGuestMovementContext,
                               intent: NPCGuestMovementIntent,
                               arrivalDistance: Float,
                               playerPosition: SIMD2<Float>,
                               neighboringPositions: [SIMD2<Float>],
                               neighborVelocities: [SIMD2<Float>] = [],
                               separationScale: Float,
                               avoidPlayer: Bool = true,
                               usePredictiveAvoidance: Bool = true) -> MoveOutcome {
        guard let waypoint = activePath.first else {
            return MoveOutcome(arrived: true, moved: false, blocked: false, stalled: false,
                               blockReason: nil)
        }
        let isFinalWaypoint = activePath.count == 1
        let outcome = move(toward: waypoint, deltaTime: deltaTime,
                           movementContext: movementContext,
                           intent: intent,
                           arrivalDistance: isFinalWaypoint ? arrivalDistance : NPCGuestTuning.arrivalDistance,
                           playerPosition: playerPosition,
                           neighboringPositions: neighboringPositions,
                           neighborVelocities: neighborVelocities,
                           separationScale: separationScale,
                           avoidPlayer: avoidPlayer,
                           usePredictiveAvoidance: usePredictiveAvoidance)
        guard outcome.arrived else { return outcome }
        activePath.removeFirst()
        return isFinalWaypoint
            ? outcome
            : MoveOutcome(arrived: false, moved: true, blocked: false, stalled: false,
                          blockReason: nil)
    }

    private func move(toward target: SIMD2<Float>, deltaTime: Float,
                      movementContext: NPCGuestMovementContext,
                      intent: NPCGuestMovementIntent,
                      arrivalDistance: Float, playerPosition: SIMD2<Float>,
                      neighboringPositions: [SIMD2<Float>],
                      neighborVelocities: [SIMD2<Float>] = [],
                      separationScale: Float,
                      avoidPlayer: Bool = true,
                      usePredictiveAvoidance: Bool = true) -> MoveOutcome {
        guard let root = locomotionRoot else {
            return MoveOutcome(arrived: false, moved: false, blocked: false, stalled: false,
                               blockReason: nil)
        }
        let exclusions = movementContext.exclusions(for: intent)
        let current = SIMD2<Float>(root.position.x, root.position.z)
        // 목적지가 바뀌었으면(새 배회 목적지, 좌석 이동 시작 등) 제자리걸음 감지 창을
        // 새로 시작한다 — 그대로 두면 방금 도착해 다음 다리를 반대 방향으로 걷기
        // 시작한 것까지 "순 이동이 없다"고 오탐할 수 있다. 대기줄처럼 목적지가 유저를
        // 따라 매 프레임 조금씩 바뀌는 이동은 이 리셋이 계속 일어나 창이 거의 안
        // 쌓이므로 자연스럽게 감지 대상에서 빠진다(의도한 동작).
        if stallCheckTarget == nil || simd_distance(stallCheckTarget!, target) > 0.01 {
            stallCheckTarget = target
            stallCheckTimer = 0
            stallCheckStartPosition = current
        }
        let delta = target - current
        let distance = simd_length(delta)
        guard distance > arrivalDistance else {
            return MoveOutcome(arrived: true, moved: false, blocked: false, stalled: false,
                               blockReason: nil)
        }

        let targetDirection = delta / distance
        // Predictive Dynamic Avoidance: 아직 떨어져 있어도 미래에 부딪힐 것으로
        // 예측되는 이웃이 있으면 targetDirection을 먼저 좌/우로 살짝 보정한다.
        // 그 다음에야 crowdSteeredDirection(즉시 반발, 이미 가까운 이웃 전용)을
        // 거친다 — Path Direction → Predictive Avoidance → Immediate Separation
        // → Final Steering 순서(NPCGuestLocalAvoidance 타입 주석 참고). 새 경로를
        // 계산하거나 activePath/wanderTarget을 건드리지 않는다 — A* 목적지는 그대로
        // 두고 그리로 가는 이번 스텝의 방향만 살짝 튼다.
        //
        // 이미 존재하는 separationScale을 avoidance 세기에도 그대로 재사용한다 —
        // 대기줄(0.35)·좌석 접근(0.5)·자유 배회(1.0)마다 반발을 다르게 눌러 둔 값이
        // 그대로 예측 회피에도 맞는 감쇠 지표라 컨텍스트별 새 파라미터가 필요 없다.
        // usePredictiveAvoidance가 false면(좌석 접근 전체 — updateMovingToSeat 호출부
        // 참고) 이 레이어를 통째로 끈다. 정지 이웃 제외/막힘 시 원래 방향 재시도 등
        // 거쳤는데도 "좌석 근처에서 계속 서 있다"는 재현이 실기에서 반복돼, 좌석으로
        // 걸어가는 짧고 목적이 분명한 구간에서는 예측(먼 거리에서 미리 피하기)
        // 대신 반응형(crowdSteeredDirection의 즉시 반발)과 하드 세이프티 넷
        // (NPCObstacleAvoidance)만으로 충분하다고 판단해 아예 끈다 — 목적지 도달을
        // 예측 회피보다 우선한다(원 작업 지시의 "자연스러움을 위해 목적지 도달을
        // 희생하지 않는다" 원칙).
        let preferredDirection: SIMD2<Float>
        if usePredictiveAvoidance, !neighborVelocities.isEmpty {
            let neighborKinematics = zip(neighboringPositions, neighborVelocities).map {
                NPCNeighborKinematics(position: $0, velocity: $1)
            }
            preferredDirection = NPCGuestLocalAvoidance.adjustedPreferredDirection(
                preferredDirection: targetDirection,
                myPosition: current,
                myVelocity: velocity,
                sidePreference: movementProfile.separationSide,
                neighbors: neighborKinematics,
                strengthScale: separationScale)
        } else {
            preferredDirection = targetDirection
        }
        var direction = crowdSteeredDirection(
            targetDirection: preferredDirection,
            from: current,
            neighbors: neighboringPositions,
            scale: separationScale)
        // 목적지 자체는 제외 구역을 피해 골랐어도 직선 경로가 AreaK/AreaB를 가로지를
        // 수 있다. 지금 그 구역 안에 있다면 중심에서 바깥으로 강하게 밀어내 서성이지
        // 않고 빠르게 빠져나가게 한다.
        if let intruded = exclusions.first(where: { $0.contains(current) }) {
            let away = current - intruded.center
            if simd_length(away) > 0.001 {
                direction = simd_normalize(direction + simd_normalize(away) * 1.5)
            }
        }
        let desiredStep = min(distance, movementProfile.moveSpeed * deltaTime)
        var step = desiredStep
        var obstacleBlocker: NPCObstacleAvoidance.Blocker?
        if let scene = root.scene {
            let stepResult = NPCObstacleAvoidance.allowedStepResult(
                scene: scene,
                from: SIMD3(current.x, 0, current.y),
                direction: SIMD3(direction.x, 0, direction.y),
                desiredStep: desiredStep,
                halfWidth: NPCGuestTuning.bodyHalfWidth,
                playerPosition: playerPosition,
                avoidPlayer: avoidPlayer,
                neighborPositions: neighboringPositions)
            step = stepResult.step
            obstacleBlocker = stepResult.blocker
            // 스티어링이 A* 방향을 옆으로 틀어 가구에 닿았으면 경로 원방향으로 한 번
            // 더 검사한다. 착석 이동은 predictive를 끈 상태라 예전 조건은 항상 false였고,
            // crowdSteeredDirection의 즉시 반발이 Cube 쪽으로 미는 경우 원방향 재시도가
            // 전혀 실행되지 않았다. 착석에서는 raw targetDirection을 쓰되, 같은
            // allowedStepResult가 유저/NPC 원형 충돌을 다시 검사하므로 사람을 통과하지는
            // 않는다. 다른 이동은 기존처럼 predictive 보정만 제거하고 즉시 반발은 유지한다.
            let isPredictiveAvoidanceEngaged = simd_length_squared(preferredDirection - targetDirection) > 0.0001
            let isFinalSteeringAdjusted = simd_length_squared(direction - targetDirection) > 0.0001
            let shouldRetryOriginalDirection: Bool
            let fallbackDirection: SIMD2<Float>
            switch intent {
            case .seating:
                shouldRetryOriginalDirection = isFinalSteeringAdjusted
                fallbackDirection = targetDirection
            case .roaming, .queueing:
                shouldRetryOriginalDirection = isPredictiveAvoidanceEngaged
                fallbackDirection = crowdSteeredDirection(
                    targetDirection: targetDirection,
                    from: current,
                    neighbors: neighboringPositions,
                    scale: separationScale)
            }
            if step < desiredStep * NPCGuestTuning.blockedStepFraction,
               shouldRetryOriginalDirection {
                let fallbackResult = NPCObstacleAvoidance.allowedStepResult(
                    scene: scene,
                    from: SIMD3(current.x, 0, current.y),
                    direction: SIMD3(fallbackDirection.x, 0, fallbackDirection.y),
                    desiredStep: desiredStep,
                    halfWidth: NPCGuestTuning.bodyHalfWidth,
                    playerPosition: playerPosition,
                    avoidPlayer: avoidPlayer,
                    neighborPositions: neighboringPositions)
                if fallbackResult.step > step {
                    direction = fallbackDirection
                    step = fallbackResult.step
                    obstacleBlocker = fallbackResult.blocker
                }
            }
        }
        let stepAfterObstacles = step
        // 레이캐스트는 메시 충돌만 알고 논리적인 바닥/금지 영역은 모른다. 군중 회피로
        // 직선 경로에서 밀려나거나 큰 deltaTime 한 프레임에 경계를 건너는 경우까지
        // 최종 이동 직전에 잘라, 정상 위치의 NPC가 금지 구역으로 진입하지 못하게 한다.
        let proposed = current + direction * step
        let areaFraction = NPCGuestNavigation.allowedFraction(
            from: current,
            to: proposed,
            inside: movementContext.floor,
            excluding: exclusions)
        step *= areaFraction
        root.position.x += direction.x * step
        root.position.z += direction.y * step
        // 장애물에 거의 다 막혀 한 프레임에 1mm 안팎만 겨우 밀리는 경우까지 "이동
        // 중"으로 치면, 실제로는 제자리에 멈춰 있는데도 Walk 애니메이션이 계속
        // 재생되는 것처럼 보인다. blockedStepFraction과 같은 기준으로 "사실상
        // 막혔다"를 판정해 그 경우엔 이동도 애니메이션도 멈춘 것으로 취급한다.
        let isBlocked = step < desiredStep * NPCGuestTuning.blockedStepFraction
        let moved = !isBlocked && step > 0.0005
        if moved {
            face(direction: direction, deltaTime: deltaTime)
        }
        // 장애물에 얕은 각도로 걸려 프레임마다 방향이 조금씩 상쇄되면(예: 밀렸다
        // 되밀렸다), 프레임별로는 매번 blockedStepFraction을 넘어 "막힘"으로 안
        // 잡히면서도 몇 초간 순 이동은 거의 없을 수 있다 — Walk 애니메이션은 계속
        // 재생되는데 실제로는 흔들리기만 하고 거의 안 나아가는 것처럼 보인다.
        // stallCheckInterval 동안의 "시작점 대비 순 이동 거리"를 따로 재서 이런
        // 경우까지 막힘으로 취급한다.
        stallCheckTimer += deltaTime
        var isStalled = false
        if stallCheckTimer >= NPCGuestTuning.stallCheckInterval {
            let newPosition = SIMD2<Float>(root.position.x, root.position.z)
            let netDisplacement = simd_distance(newPosition, stallCheckStartPosition ?? newPosition)
            isStalled = netDisplacement < NPCGuestTuning.stallMinimumDistance
            stallCheckTimer = 0
            stallCheckStartPosition = newPosition
        }
        if isBlocked || isStalled {
            lastBlockedDirection = direction
        }
        // wanderTarget/pauseRemaining 갱신은 호출부(update의 배회·좌석 이동 분기)가
        // blocked를 보고 즉시 처리한다 — 여기서 같이 건드리면 호출부가 막 고른 새
        // 목적지를 다시 지워버리거나, 다음 프레임에 남은 pauseRemaining 때문에
        // "즉시 방향 전환"이 지연될 수 있다.
        let blockReason: MovementBlockReason?
        if isStalled {
            blockReason = .stalled
        } else if stepAfterObstacles < desiredStep * NPCGuestTuning.blockedStepFraction {
            switch obstacleBlocker {
            case .sceneGeometry: blockReason = .sceneGeometry
            case .player: blockReason = .player
            case .neighboringNPC: blockReason = .neighboringNPC
            case nil: blockReason = .unknown
            }
        } else if isBlocked {
            blockReason = .restrictedArea
        } else {
            blockReason = nil
        }
        return MoveOutcome(arrived: step >= distance, moved: moved,
                           blocked: isBlocked || isStalled, stalled: isStalled,
                           blockReason: blockReason)
    }

    /// update() 호출 전후의 실제 위치 변화량을 deltaTime으로 나눠 velocity를 갱신한다.
    /// commanded 속도(movementProfile.moveSpeed)를 그대로 쓰지 않는 이유는 velocity
    /// 프로퍼티 주석 참고. 가벼운 지수 평활(NPCGuestLocalAvoidance.Tuning.
    /// velocitySmoothing)만 적용해 한 프레임짜리 순간 튐은 줄이되, 실제로 방향을 튼
    /// 반응까지 느려 보이게 하지는 않는다.
    private func updateVelocity(from previousPosition: SIMD2<Float>, deltaTime: Float) {
        guard deltaTime > 0.0001 else { return }
        let instantVelocity = (currentPosition - previousPosition) / deltaTime
        guard instantVelocity.x.isFinite, instantVelocity.y.isFinite else { return }
        let alpha = min(1, NPCGuestLocalAvoidance.Tuning.velocitySmoothing * deltaTime)
        velocity += (instantVelocity - velocity) * alpha
    }

    /// 목표 방향에 개인 공간 반발력을 섞는다. 완전 정면 충돌 시에는 손님별 좌/우
    /// 성향을 사용해 둘이 같은 자리에서 영원히 마주 보는 대칭 교착을 깬다.
    private func crowdSteeredDirection(targetDirection: SIMD2<Float>,
                                       from current: SIMD2<Float>,
                                       neighbors: [SIMD2<Float>],
                                       scale: Float) -> SIMD2<Float> {
        var steering = targetDirection
        for neighbor in neighbors {
            var away = current - neighbor
            var distance = simd_length(away)
            guard distance < movementProfile.personalSpace else { continue }
            if distance < 0.001 {
                away = SIMD2(movementProfile.separationSide, 0)
                distance = 0.001
            }
            let proximity = 1 - distance / movementProfile.personalSpace
            steering += (away / distance) * proximity
                * movementProfile.separationStrength * scale
        }

        // 반발력이 정확히 상쇄되거나 뒤로 향하면 선호 측면으로 살짝 비켜 교착을 푼다.
        if simd_length_squared(steering) < 0.01 || simd_dot(steering, targetDirection) < 0.05 {
            let side = SIMD2(targetDirection.y, -targetDirection.x)
                * movementProfile.separationSide
            steering = targetDirection * 0.35 + side * 0.65
        }
        let len = simd_length(steering)
        return len > 0.001 ? steering / len : targetDirection
    }

    private func face(point: SIMD2<Float>, deltaTime: Float) {
        let delta = point - currentPosition
        guard simd_length(delta) > 0.001, !delta.x.isNaN, !delta.y.isNaN else { return }
        face(direction: simd_normalize(delta), deltaTime: deltaTime)
    }

    private func face(direction: SIMD2<Float>, deltaTime: Float) {
        guard let root = locomotionRoot,
              !direction.x.isNaN, !direction.y.isNaN,
              simd_length(direction) > 0.001 else { return }
        let yaw = atan2(-direction.x, -direction.y) + NPCGuestTuning.forwardYawOffset
        guard !yaw.isNaN else { return }
        let target = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let amount = min(1, max(0, NPCGuestTuning.turnResponse * deltaTime))
        let currentOri = root.orientation
        if simd_length(currentOri.vector) > 0.001 && !currentOri.vector.x.isNaN {
            let nextOri = simd_slerp(simd_normalize(currentOri), target, amount)
            if !nextOri.vector.x.isNaN {
                root.orientation = nextOri
            }
        } else {
            root.orientation = target
        }
    }

    private func randomWanderTarget(in area: NPCGuestArea,
                                    excluding exclusions: [NPCGuestArea],
                                    awayFrom current: SIMD2<Float>,
                                    avoiding occupiedAnchors: [SIMD2<Float>]) -> SIMD2<Float>? {
        // 후보는 바닥 안·제외 구역 밖이라는 논리적 조건만 보고 고른다. 실제 이동은
        // NPCGuestPathfinder가 찾은 웨이포인트 경로를 따라가므로(activePath), 여기서
        // current→candidate 직선이 뚫려 있는지 미리 걸러낼 필요가 없다 — 직선이
        // 막혀 있어도 경로가 돌아갈 수 있다. 예전에는 직선 여부로 미리 걸렀는데,
        // 그러면 우회해서 갈 수 있는 목적지까지 부당하게 배제됐다. current 자신이
        // 이미 어떤 제외 구역 안에 있어도(예: 방금 일어난 좌석) 문제없다 — 경로
        // 탐색이 가장 가까운 유효 칸에서부터 다시 잡아 준다.
        var fallback: SIMD2<Float>?
        var bestSeparation: Float = -1
        for _ in 0..<40 {
            let candidate = area.point(u: Float.random(in: -1...1), v: Float.random(in: -1...1))
            if exclusions.contains(where: { $0.contains(candidate) }) { continue }
            guard simd_distance(candidate, current) >= NPCGuestTuning.minimumRoamDistance else { continue }
            let separation = occupiedAnchors
                .map { simd_distance(candidate, $0) }
                .min() ?? .greatestFiniteMagnitude
            if separation > bestSeparation {
                bestSeparation = separation
                fallback = candidate
            }
            if separation >= NPCGuestTuning.preferredTargetSeparation {
                return candidate
            }
        }
        return fallback
    }

    /// 막힘 직후 부르는 탈출 방향 탐색. 먼 무작위 목적지 대신 지금 위치 주변을
    /// 원형으로 훑어 논리적으로 유효하고 가구·유저·NPC에도 실제로 열린 방향을 찾는다.
    private func nearbyEscapeTarget(from current: SIMD2<Float>,
                                    in area: NPCGuestArea,
                                    excluding exclusions: [NPCGuestArea],
                                    playerPosition: SIMD2<Float>,
                                    neighboringPositions: [SIMD2<Float>],
                                    avoidingDirection: SIMD2<Float>?) -> SIMD2<Float>? {
        let scene = locomotionRoot?.scene
        let sampleCount = 16
        let probeDistance = NPCGuestTuning.escapeProbeDistance
        var best: SIMD2<Float>?
        var bestTravel: Float = 0
        for index in 0..<sampleCount {
            let angle = Float(index) / Float(sampleCount) * 2 * Float.pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            guard NPCGuestNavigation.isDifferentEscapeDirection(
                direction,
                from: avoidingDirection)
            else { continue }
            let clearance: Float
            if let scene {
                clearance = NPCObstacleAvoidance.allowedStep(
                    scene: scene, from: SIMD3(current.x, 0, current.y),
                    direction: SIMD3(direction.x, 0, direction.y),
                    desiredStep: probeDistance, halfWidth: NPCGuestTuning.bodyHalfWidth,
                    playerPosition: playerPosition,
                    neighborPositions: neighboringPositions)
            } else {
                clearance = probeDistance
            }
            let travel = min(probeDistance, clearance * 0.9)
            guard travel >= NPCGuestTuning.escapeMinimumDistance,
                  travel > bestTravel else { continue }
            let candidate = current + direction * travel
            // 정상 위치에서는 금지 구역에 새로 진입하지 않고, 이미 위반 상태라면
            // 위반 깊이가 얕아지는 방향만 허용한다.
            guard NPCGuestNavigation.isAllowedStep(
                from: current,
                to: candidate,
                inside: area,
                excluding: exclusions)
            else { continue }
            bestTravel = travel
            best = candidate
        }
        return best
    }

    // MARK: - Animation

    /// 같은 Sit_to_Stand 리소스를 정방향(기립) 또는 역방향(착석)으로 재생한다.
    /// 역재생은 paused 상태로 컨트롤러를 만든 뒤 클립 끝으로 이동하고 음수 speed를
    /// 적용한 다음 resume해, 렌더 프레임 사이에 원래 시작 자세가 노출되지 않게 한다.
    /// 반환값은 상태 전이 타이머에 사용할 실제 클립 길이다.
    private func playSitTransition(reversed: Bool) -> Float? {
        guard let model = modelEntity,
              let match = findAnimation(named: NPCGuestAnimationCue.sitToStand.rawValue, in: model)
        else { return nil }

        animationPlayback?.stop(blendOutDuration: 0.15)
        let playback = match.entity.playAnimation(
            match.resource,
            transitionDuration: 0.2,
            startsPaused: reversed)
        let duration = playback.duration
        guard duration.isFinite, duration > 0 else {
            playback.stop()
            animationPlayback = nil
            currentCue = nil
            return nil
        }
        if reversed {
            playback.speed = -1
            playback.time = duration
            playback.resume()
        }
        animationPlayback = playback
        currentCue = .sitToStand
        return Float(duration)
    }

    private func playAnimation(_ cue: NPCGuestAnimationCue) {
        guard currentCue != cue, let model = modelEntity else { return }

        let match = cue == .idle
            ? findDefaultSubtreeAnimation(in: model)
            : findAnimation(named: cue.rawValue, in: model)
        guard let match else { return }

        animationPlayback?.stop(blendOutDuration: 0.15)
        let resource = cue.repeats ? match.resource.repeat() : match.resource
        animationPlayback = match.entity.playAnimation(resource, transitionDuration: 0.2)
        if cue.repeats {
            // 여러 손님이 같은 클립을 동시에 재생하면 완전히 같은 위상으로 움직여
            // 기계적으로 보인다. 반복 재생 cue는 시작 지점을 무작위로 어긋나게 한다
            // (원샷인 sitToStand는 처음부터 재생돼야 하므로 건드리지 않는다).
            animationPlayback?.time = TimeInterval.random(in: 0..<4)
        }
        currentCue = cue
    }

    private func findAnimation(named animationName: String,
                               in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        if let library = entity.components[AnimationLibraryComponent.self],
           let resource = library.animations[animationName] {
            return (entity, resource)
        }
        for child in entity.children {
            if let match = findAnimation(named: animationName, in: child) { return match }
        }
        return nil
    }

    /// Indoor.usda의 Guest AnimationLibrary에 이름으로 등록된 클립. 이 이름과 겹치지
    /// 않는 첫 애니메이션이 *Idle.usdz 임포트 시 RealityKit이 모델 자체의 스켈레톤
    /// 액션으로부터 자동 생성하는 "default subtree animation"(idle 루프)이다.
    /// Sitting/Sit_to_Stand/Angry도 라이브러리에 등록돼 있어 "Walk"만 제외하면
    /// idle 판정이 그중 하나로 잘못 걸릴 수 있다(NPCClerkController의 동일 패턴 참고).
    private static let libraryAnimationNames: Set<String> = ["Walk", "Sitting", "Sit_to_Stand", "Angry"]

    /// availableAnimations는 이미 서브트리 전체를 포함하므로, 라이브러리에 등록된
    /// 이름과 겹치지 않는 첫 항목을 idle 애니메이션으로 사용한다.
    private func findDefaultSubtreeAnimation(in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        guard let resource = entity.availableAnimations.first(where: { animation in
            guard let name = animation.name else { return true }
            return !Self.libraryAnimationNames.contains(name)
        }) else { return nil }
        return (entity, resource)
    }
}
