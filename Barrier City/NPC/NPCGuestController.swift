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
    /// 배회↔착석을 실제로 반복한다: 좌석을 찾아 앉고, 10~15초(NPCGuestTuning.
    /// sittingDurationRange) 뒤 자동으로 일어나 다시 배회하다 새 좌석에 앉는다.
    /// 배회 중일 때만 대기줄 후보(착석 중이거나 좌석으로 이동 중일 때는 제외).
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
        /// 막혀서 새 목적지를 고른 뒤에도 곧장 다시 움직이면(특히 새 목적지도 같은
        /// 장애물 방향이면) 같은 프레임에 다시 막혀 Idle↔Walk가 매 프레임 번갈아
        /// 재생되며 결과적으로 Walk가 끊기지 않는 것처럼 보인다. 잠깐 멈춰 있다가
        /// 다시 시도하게 해 이 진동을 막는다.
        static let blockedPauseRange: ClosedRange<Float> = 0.2...0.5
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
        /// 이 횟수만큼 연속으로 막히면(consecutiveBlockedCount) 먼 무작위 목적지
        /// 대신 지금 위치 주변을 원형으로 훑어 실제로 뚫린 방향을 찾는
        /// nearbyEscapeTarget으로 전환한다 — 막다른 구석에 몰려 무작위 후보가
        /// 계속 같은 방향으로만 뽑히는 경우까지 확실히 벗어나게 하는 마지막 안전망.
        static let stuckEscapeThreshold = 3
        /// 좌석 도착 판정 거리. 8cm처럼 너무 좁으면 다른 손님이나 좌석 주변
        /// 콜리전에 조금만 걸려도 이 문턱 안으로 못 들어와 계속 재시도만 하다
        /// vacate/stall 경로를 타게 된다 — 여유를 넉넉히 둬 "거의 다 왔으면
        /// 앉는다"로 완화한다. seatCollisionBypassDistance(0.6m)보다는 항상
        /// 작아야 한다(그래야 도착 판정 전에 레이캐스트 회피가 이미 꺼진 구간에
        /// 들어와 있다).
        static let seatArrivalDistance: Float = 0.3
        /// 좌석 콜리전 프록시를 넘는 마지막 구간에서만 장애물 레이를 끈다. 좌석까지
        /// 먼 구간은 계속 벽/가구 충돌을 검사해 방을 가로질러 관통하지 못하게 한다.
        static let seatCollisionBypassDistance: Float = 0.6
        /// 좌석으로 걸어가는 경로(activePath)의 한 웨이포인트가 막힌 걸 이 횟수만큼
        /// 연속으로 확인하기 전까지는 자리를 포기하지 않고 그 자리에서 재시도한다.
        /// 경로 자체는 NPCGuestPathfinder가 정적 장애물을 피해 미리 찾아 두므로,
        /// 여기서 막히는 건 대개 다른 손님·유저가 일시적으로 그 자리에 서 있는
        /// 경우다 — 잠깐 기다리면 대개 풀린다. 예전(경로 탐색 도입 전)에는 막힌
        /// 첫 프레임에 곧장 자리를 반납해 cycler가 좌석 근처까지 가보지도 못하고
        /// 영원히 배회만 반복했다.
        static let seatApproachEscapeThreshold = 3
        /// cycler가 한 좌석에 계속 앉아있는 시간(초). 이 시간이 지나면 자동으로
        /// 일어나 다시 배회하다 새 좌석을 찾는다 — 카페가 계속 사람이 들고 나는
        /// 느낌을 주기 위함이다. cycler는 3명뿐이라 이 순환에 참여하는 인원이
        /// 동시에 3명을 넘는 일은 구조적으로 없다.
        static let sittingDurationRange: ClosedRange<Float> = 10...15
        /// Sit_to_Stand 애니메이션이 다 재생될 시간(초). 이 시간 동안은 새 배회
        /// 목적지를 고르지 않는다 — 그렇지 않으면 일어나자마자 Walk가 요청돼
        /// 기립 애니메이션이 한 프레임만 보이고 바로 끊긴다.
        static let standUpAnimationDuration: Float = 1.0
    }

    private enum SeatState {
        case none
        case movingToSeat
        case sitting
        /// Sit_to_Stand 애니메이션이 재생되는 짧은 구간(standUpAnimationDuration).
        /// 이 동안은 배회 목적지를 고르지 않아 애니메이션이 끊기지 않는다.
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
        /// 배회 목적지에 도착할 때마다 착석을 시도할 확률(cycler 개인차). 전원이 같은
        /// 확률로 앉으면 기계적으로 보여, 손님마다 성향을 다르게 둔다. 입장 후 너무
        /// 오래 아무도 안 앉는 것처럼 보이지 않도록 평균적으로 배회 1~2번 만에는
        /// 앉기 시작하게 높게 잡았다.
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
    private var pauseRemaining: Float = 0
    /// "제자리걸음" 감지용(NPCGuestTuning.stallCheckInterval 참고). move()의 목적지가
    /// 바뀌면(새 배회 목적지, 좌석 이동 시작 등) 그 즉시 리셋해, 정상적으로 도착한 뒤
    /// 다음 다리를 걷기 시작하는 것까지 오탐하지 않게 한다.
    private var stallCheckTarget: SIMD2<Float>?
    private var stallCheckTimer: Float = 0
    private var stallCheckStartPosition: SIMD2<Float>?
    /// 배회 중 연속으로 막힌 횟수(NPCGuestTuning.stuckEscapeThreshold 참고). 막히지
    /// 않고 이동/도착하면 즉시 0으로 리셋된다.
    private var consecutiveBlockedCount = 0
    private let movementProfile: MovementProfile

    private var seatState: SeatState = .none
    private var claimedSeatIndex: Int?
    private var claimedSeat: GuestSeat?
    /// cycler가 착석한 뒤 자동으로 일어날 때까지 남은 시간(초). role == .cycler로
    /// 착석했을 때만 값이 채워진다 — seatedPool은 영구 착석이라 항상 nil이다.
    private var sittingRemaining: Float?
    /// seatState == .standingUp 동안 Sit_to_Stand 애니메이션이 끊기지 않도록 두는
    /// 남은 시간(초).
    private var standingUpRemaining: Float?
    /// 코디네이터가 다음 프레임에 한 번만 소비하는 원샷 신호. 착석을 원한다는 요청과,
    /// 방금 자리를 비웠다는 통지에 쓴다(takeSeatRequest/takeVacatedSeatIndex 참고).
    private var pendingSeatRequest = false
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
    /// 배회를 한 바퀴 마친 뒤 곧장 향할 좌석(코디네이터가 reserveSeat로 예약).
    /// grantSeat와 달리 즉시 이동을 시작하지 않고, 다음 배회 목적지에 도착하는
    /// 시점에 자동으로 커밋한다 — 입장하자마자 전원이 일제히 좌석으로 직행하면
    /// 부자연스러워, 일부는 방을 한 바퀴 둘러보다 앉는 것처럼 보이게 한다.
    private var reservedSeat: (index: Int, seat: GuestSeat)?
    /// 좌석으로 이동 중 연속으로 막힌 횟수(seatApproachEscapeThreshold 참고). 정적
    /// 장애물은 activePath(경로 탐색)가 이미 피해 가므로, 여기서 막히는 건 대개
    /// 다른 손님이나 유저가 일시적으로 그 자리에 서 있는 경우다 — 몇 번은 그대로
    /// 재시도하고, 계속 막히면 그제서야 자리를 반납한다.
    private var seatApproachBlockedCount = 0
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

    /// 대기줄 후보 자격: 착석 지향(seatedPool) 역할이 아니고, 지금 좌석으로
    /// 이동/착석 중이거나 좌석을 예약해 둔 상태가 아닐 때만(= 순수 배회 중일 때만)
    /// 후보가 된다.
    var isQueueEligible: Bool {
        role != .seatedPool && seatState == .none && reservedSeat == nil
    }

    /// 코디네이터가 이번 프레임에 착석을 원하는지 확인할 때 한 번만 읽고 소비한다.
    func takeSeatRequest() -> Bool {
        defer { pendingSeatRequest = false }
        return pendingSeatRequest
    }

    /// 코디네이터가 빈 좌석을 찾아 배정할 때 호출한다.
    func grantSeat(index: Int, seat: GuestSeat) {
        claimedSeatIndex = index
        claimedSeat = seat
        seatState = .movingToSeat
        wanderTarget = nil
        activePath = []
        pauseRemaining = 0
        seatApproachBlockedCount = 0
    }

    /// grantSeat와 달리 즉시 걸어가지 않는다 — 다음 배회 목적지에 도착하는
    /// 시점(update의 .none 분기)에 자동으로 이 좌석으로 향하게 예약만 해 둔다.
    /// 자리는 코디네이터가 이미 seatOccupants에 표시해 다른 손님이 못 가져간다.
    func reserveSeat(index: Int, seat: GuestSeat) {
        reservedSeat = (index, seat)
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
        seatState = .none
        claimedSeatIndex = nil
        claimedSeat = nil
        sittingRemaining = nil
        standingUpRemaining = nil
        pendingSeatRequest = false
        pendingVacatedSeatIndex = nil
        pendingSeatedArrivalIndex = nil
        pendingQueueArrival = false
        hasReportedQueueArrival = false
        reservedSeat = nil
        consecutiveBlockedCount = 0
        seatApproachBlockedCount = 0
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

    /// queueSlot이 있으면 그 지점으로 이동해 대기하고, 없으면 wanderArea 안에서
    /// exclusions(직원 구역 + 키오스크 반경 + 테이블별 좌석 클러스터)를 피해 자유롭게
    /// 걸어 다닌다.
    ///
    /// exclusions와 staffExclusions를 분리해서 받는 이유: 좌석으로 걸어가는 중(예:
    /// updateMovingToSeat)에는 목적지인 좌석 자체가 "그 테이블의 좌석 클러스터
    /// 제외 구역" 안에 있다(제외 구역이 그 테이블 좌석들을 감싸도록 만들어지므로).
    /// 그런데 exclusions 전체를 그대로 넘기면 move()의 "제외 구역 안에 있으면
    /// 바깥으로 밀어낸다" 로직이 매 프레임 목적지 반대 방향으로 계속 밀어내, 좌석에
    /// 영원히 도착하지 못한 채 Walk만 반복 재생하는 문제가 있었다(seatedPool처럼
    /// 입장 시 바로 착석 배치되는 손님은 이 이동 자체를 안 거쳐서 증상이 안 보였고,
    /// cycler처럼 배회하다 실제로 좌석까지 걸어가야 하는 손님만 걸렸다). 그래서
    /// 좌석으로 걸어갈 때는 직원 구역(AreaK/AreaB)만 담은 staffExclusions만 넘겨,
    /// 그쪽으로는 안 걸어 들어가되 목적지인 좌석 자체와는 싸우지 않게 한다.
    func update(deltaTime: Float,
               wanderArea: NPCGuestArea,
               exclusions: [NPCGuestArea],
               staffExclusions: [NPCGuestArea],
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
                               movementArea: wanderArea,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               neighboringVelocities: neighboringVelocities,
                               exclusions: staffExclusions,
                               pathGrid: pathGrid)
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
                seatState = .none
                vacateClaimedSeat()
                return
            }
            remaining -= deltaTime
            if remaining > 0 {
                standingUpRemaining = remaining
                return
            }
            standingUpRemaining = nil
            seatState = .none
            // 좌석을 실제로 "비웠다"고 코디네이터에 통지하는 시점은 여기(기립
            // 애니메이션이 끝나 실제로 그 자리를 벗어난 순간)여야 한다.
            // standUpAndResumeWandering()에서 곧장 통지하면, 코디네이터가 그
            // 프레임에 바로 좌석을 "빈 자리"로 표시해 다른 손님에게 재배정할 수
            // 있는데, 정작 이 손님의 몸은 standingUpAnimationDuration(1초) 동안
            // 그 좌석 위치에 그대로 서 있다(기립 중에는 이동하지 않는다). 그
            // 사이 새로 배정된 손님이 걸어오면 NPCObstacleAvoidance의 이웃
            // 하드블록이 아직 그 자리에 서 있는 이 손님의 몸에 막혀, 막힘
            // 판정이 아슬아슬하게 오락가락하며(3연속 실패 임계값에는 못
            // 미치면서 순 이동도 없는) 좌석 근처에서 영원히 서성이기만 하고
            // 앉지 못하는 교착에 빠졌다 — 실기에서 "의자에 앉지 않고 서 있는
            // NPC"로 관찰된 원인.
            vacateClaimedSeat()
            return
        case .none:
            break
        }

        // 외부 transform 변경이나 이전 프레임의 예외 상황으로 이미 경계를 위반했다면
        // 정지 타이머/보행 예산보다 복구를 우선한다. move()는 위반 깊이가 줄어드는
        // 이동만 허용하므로 안전 영역을 향해 빠져나가는 동안 더 깊이 들어갈 수 없다.
        let requiresRecovery = !NPCGuestNavigation.isValid(
            currentPosition, inside: wanderArea, excluding: exclusions)
        if requiresRecovery {
            pauseRemaining = 0
            wanderTarget = randomWanderTarget(
                in: wanderArea,
                excluding: exclusions,
                awayFrom: currentPosition,
                avoiding: occupiedAnchors)
            activePath = requestPath(to: wanderTarget, grid: pathGrid)
        }

        if let queueSlot {
            // 대기줄은 의도적으로 유저 바로 뒤까지 다가가야 하므로, 평소 배회에서
            // 유저 몸에 안 걸어 들어가게 막는 반경 회피는 여기서만 끈다. 전체 배회
            // 제외 구역은 넘기지 않되 AreaK/AreaB만 유지한다 — 키오스크 주변 반경은
            // 줄서기와 충돌하지만 직원 전용 구역은 어떤 행동에서도 침범하면 안 된다.
            let outcome = move(toward: queueSlot, deltaTime: deltaTime,
                               movementArea: wanderArea,
                               arrivalDistance: NPCGuestTuning.queueArrivalDistance,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               neighborVelocities: neighboringVelocities,
                               separationScale: 0.35,
                               exclusions: staffExclusions,
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
                playAnimation(outcome.moved ? .walk : .idle)
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
                in: wanderArea,
                excluding: exclusions,
                awayFrom: currentPosition,
                avoiding: occupiedAnchors)
            activePath = requestPath(to: wanderTarget, grid: pathGrid)
        }
        guard wanderTarget != nil else {
            playAnimation(.idle)
            return
        }
        let outcome = moveAlongPath(deltaTime: deltaTime,
                                    movementArea: wanderArea,
                                    arrivalDistance: NPCGuestTuning.arrivalDistance,
                                    playerPosition: playerPosition,
                                    neighboringPositions: neighboringPositions,
                                    neighborVelocities: neighboringVelocities,
                                    separationScale: 1,
                                    exclusions: exclusions)
        if outcome.blocked {
            // 막힌 걸 확인한 그 프레임에 바로 다른 목적지를 찾아 방향을 틀되, 짧게
            // 멈췄다 가게 해 새 목적지도 같은 장애물에 곧장 다시 막히며 Idle↔Walk가
            // 매 프레임 번갈아 재생되는(결과적으로 Walk가 안 끊기는 것처럼 보이는)
            // 진동을 막는다.
            consecutiveBlockedCount += 1
            // randomWanderTarget은 논리적 유효성(바닥 안·제외 구역 밖)만 보고 후보를
            // 고르는데, 지금 위치가 이미 막다른 구석이면 그렇게 고른 새 목적지도
            // 같은 장애물 너머라 다시 막히길 반복할 수 있다. 연속으로
            // stuckEscapeThreshold번 이상 막히면, 먼 무작위 후보 대신 지금 위치
            // 주변에서 실제로(레이캐스트로 확인된) 뚫린 방향을 찾는 nearbyEscapeTarget로
            // 전환해 확실히 벗어나게 한다.
            // outcome.stalled(1.2초간 순 이동 거의 없음)는 연속 횟수와 무관하게 그
            // 자체로 즉시 escape 전환 사유다 — 프레임 단위 blocked만 세면, 여러
            // NPC가 몰려 미묘하게 밀고 밀리는 상황에서 어느 한 프레임이
            // blockedStepFraction을 살짝 넘겨 카운터가 0으로 리셋되는 게 반복되며
            // 실제로는 오래 정체돼 있는데도 "3연속"에 영원히 못 미칠 수 있다
            // (MoveOutcome.stalled 주석 참고).
            let newTarget: SIMD2<Float>?
            if outcome.stalled || consecutiveBlockedCount >= NPCGuestTuning.stuckEscapeThreshold {
                newTarget = nearbyEscapeTarget(from: currentPosition, in: wanderArea, excluding: exclusions)
                    ?? randomWanderTarget(in: wanderArea, excluding: exclusions,
                                          awayFrom: currentPosition, avoiding: occupiedAnchors)
            } else {
                newTarget = randomWanderTarget(in: wanderArea, excluding: exclusions,
                                               awayFrom: currentPosition, avoiding: occupiedAnchors)
            }
            wanderTarget = newTarget
            activePath = requestPath(to: newTarget, grid: pathGrid)
            // move()는 실제로 이동한(moved) 프레임에만 face()를 호출한다. 막힌 프레임은
            // moved가 false라 이 회전이 없으면 벽/가구를 향한 채로 그대로 멈춰 서서,
            // Idle로 바뀌어도 여전히 "막혀서 못 가고 있다"는 느낌을 준다. 새 목적지를
            // 정한 그 즉시 그쪽을 보게 돌려 다른 방향을 시도한다는 게 눈에 보이게 한다.
            if let newTarget {
                face(point: newTarget, deltaTime: 999)
            }
            pauseRemaining = Float.random(in: NPCGuestTuning.blockedPauseRange)
            playAnimation(.idle)
            return
        }
        consecutiveBlockedCount = 0
        if outcome.arrived {
            wanderTarget = nil
            activePath = []
            // 예약된 좌석이 있으면(reserveSeat) 이 배회 목적지 도착을 신호로 곧장 그
            // 좌석으로 향한다 — 확률을 굴리지 않고 항상 커밋해, "한 바퀴 둘러보고 나서
            // 앉는다"는 정해진 그림이 실제로 이어지게 한다.
            if let reserved = reservedSeat {
                reservedSeat = nil
                claimedSeatIndex = reserved.index
                claimedSeat = reserved.seat
                seatState = .movingToSeat
                pauseRemaining = 0
                seatApproachBlockedCount = 0
                playAnimation(.idle)
                return
            }
            pauseRemaining = Float.random(in: movementProfile.pauseRange)
            playAnimation(.idle)
            // 목적지 도착이라는 자연스러운 결정 지점에서만 착석 여부를 굴린다.
            // alwaysWandering 역할은 절대 앉지 않는다. 확률은 손님마다 달라(개인차) 전원이
            // 기계적으로 같은 타이밍에 앉지 않게 한다.
            if role != .alwaysWandering, Float.random(in: 0...1) < movementProfile.sitDesireChance {
                pendingSeatRequest = true
            }
        } else {
            // 실제로 위치가 움직인 프레임에만 Walk를 재생한다. 장애물에 막혀 제자리인
            // 프레임까지 Walk를 계속 재생하면 제자리걸음처럼 보인다.
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    // MARK: - Seating

    /// cycler 전용: 앉아있던 시간(sittingDurationRange)이 다 되면 자동으로 일어나
    /// 다시 배회 상태로 돌아간다. 방금 앉아있던 좌석은 pendingVacatedSeatIndex로
    /// 코디네이터에 알려 비워지고(그 테이블에 다른 손님이 안 남아있으면 코디네이터가
    /// 디저트도 함께 치운다), 이후 정상적인 배회→확률적 착석 요청 경로가 새 좌석을
    /// 찾아준다 — 배회 손님이 카페에 계속 들고 나는 느낌을 준다.
    private func standUpAndResumeWandering() {
        playAnimation(.sitToStand)
        locomotionRoot?.position.y = 0
        // claimedSeatIndex/claimedSeat는 여기서 비우지 않는다 — 기립 애니메이션이
        // 끝나 실제로 자리를 벗어날 때(.standingUp 완료 시점, update() 참고)까지는
        // 이 손님의 몸이 여전히 그 좌석 위치에 있다. 그 전에 코디네이터에 "비었다"고
        // 통지하면 다른 손님이 아직 사람이 서 있는 자리로 걸어오게 된다.
        seatState = .standingUp
        sittingRemaining = nil
        standingUpRemaining = NPCGuestTuning.standUpAnimationDuration
        wanderTarget = nil
        pauseRemaining = 0
    }

    /// 지금 붙잡고 있는 좌석(있다면)을 실제로 놓아준다 — pendingVacatedSeatIndex로
    /// 코디네이터에 통지해 seatOccupants를 비우게 한다. 반드시 이 손님의 몸이 그
    /// 좌석 위치를 실제로 벗어난(또는 애초에 도착한 적 없는) 시점에만 불러야 한다
    /// — 기립 애니메이션 도중처럼 아직 그 자리에 있는 동안 부르면 다른 손님이
    /// 사람이 서 있는 자리로 걸어오는 원인이 된다(standUpAndResumeWandering 주석
    /// 참고).
    private func vacateClaimedSeat() {
        pendingVacatedSeatIndex = claimedSeatIndex
        claimedSeatIndex = nil
        claimedSeat = nil
    }

    /// exclusions는 호출부(update)가 staffExclusions(직원 구역만)를 넘긴다 — 테이블
    /// 좌석 클러스터 제외 구역까지 넘기면 목적지인 좌석 자체와 충돌한다(update의
    /// 문서 주석 참고).
    ///
    /// 좌석까지의 경로는 NPCGuestPathfinder로 미리 찾아 activePath에 웨이포인트로
    /// 담아 두고 그 순서대로 걷는다(moveAlongPath) — 직선으로 곧장 겨냥하면
    /// 테이블처럼 큰 장애물을 사이에 두고 매 프레임 다시 막히며 제자리에서
    /// 왔다갔다만 반복했다.
    ///
    /// 좌석 바로 앞 마지막 seatCollisionBypassDistance 구간에서만 레이캐스트 장애물
    /// 회피를 끈다 — Indoor.usda의 좌석은 사실상 전부(39/39 실측) 휠체어가 테이블을
    /// 가로지르지 못하게 둘러싼 collision Cube 프록시 안쪽에 있다. NPC 이동도 같은
    /// 콜리전 그룹(groundGroup)을 검사하므로, 이 회피를 켜 둔 채로는 좌석 코앞까지
    /// 걸어와도 그 박스 경계에 막혀 마지막 한 걸음을 절대 못 넘고("착석 동작 없이
    /// 서 있음") seatArrivalDistance 안으로 못 들어왔다. 그 전 이동은 충돌 검사를
    /// 유지해 먼 거리에서 벽이나 가구를 관통하는 우회는 허용하지 않는다.
    private func updateMovingToSeat(deltaTime: Float,
                                    movementArea: NPCGuestArea,
                                    playerPosition: SIMD2<Float>,
                                    neighboringPositions: [SIMD2<Float>],
                                    neighboringVelocities: [SIMD2<Float>],
                                    exclusions: [NPCGuestArea],
                                    pathGrid: NPCGuestPathfinder.WalkableGrid?) {
        guard let seat = claimedSeat else { seatState = .none; return }
        if activePath.isEmpty {
            activePath = requestPath(to: seat.position, grid: pathGrid)
        }

        let bypassSeatCollision = simd_distance(currentPosition, seat.position)
            <= NPCGuestTuning.seatCollisionBypassDistance
        let outcome = moveAlongPath(deltaTime: deltaTime,
                                    movementArea: movementArea,
                                    arrivalDistance: NPCGuestTuning.seatArrivalDistance,
                                    playerPosition: playerPosition,
                                    neighboringPositions: neighboringPositions,
                                    neighborVelocities: neighboringVelocities,
                                    separationScale: 0.5,
                                    exclusions: exclusions,
                                    avoidObstacles: !bypassSeatCollision,
                                    // 좌석으로 걸어가는 짧고 목적이 분명한 구간에서는
                                    // 예측 회피를 아예 끈다 — move()의 usePredictiveAvoidance
                                    // 주석 참고. crowdSteeredDirection(즉시 반발)과
                                    // NPCObstacleAvoidance(하드 세이프티 넷)는 그대로
                                    // 적용되므로 다른 손님/유저와 실제로 겹치지는 않는다.
                                    usePredictiveAvoidance: false)
        if outcome.blocked {
            // 정적 장애물(테이블 등)은 activePath가 이미 피해서 잡은 경로라 여기서는
            // 잘 안 걸린다 — 막히는 건 대개 다른 손님이나 유저가 일시적으로 그
            // 웨이포인트를 막고 서 있는 경우다. 몇 번은 그대로 재시도하고, 계속
            // 막히면 그제서야 포기한다(코디네이터가 seatOccupants를 비워 다른
            // 손님에게 다시 배정할 수 있게 한다).
            //
            // outcome.stalled는 프레임 단위 연속 횟수와 무관하게 그 자체로 즉시
            // 포기 사유다 — 여러 손님이 좁은 공간(테이블·카운터 주변)에 몰려
            // 미묘하게 밀고 밀리면, 어느 한 프레임이 blockedStepFraction을 살짝
            // 넘겨 seatApproachBlockedCount가 0으로 리셋되는 게 반복될 수 있다.
            // 그러면 실제로는 1.2초 넘게 좌석 근처에서 정체돼 있는데도(=실기에서
            // "충돌 판정만 나며 계속 서 있는" 증상) "3연속 막힘"에 영원히 못
            // 미쳐 포기 로직이 발동하지 않는다(MoveOutcome.stalled 주석 참고).
            seatApproachBlockedCount += 1
            if !outcome.stalled, seatApproachBlockedCount < NPCGuestTuning.seatApproachEscapeThreshold {
                playAnimation(.idle)
                return
            }
            vacateSeatDueToBlockage()
            return
        }
        seatApproachBlockedCount = 0
        if outcome.arrived {
            seatState = .sitting
            face(direction: seat.facing, deltaTime: 999)
            playAnimation(.sitting)
            // seatArrivalDistance(0.3m)가 넉넉해진 만큼, 도착 판정 시점의 실제 위치는
            // 좌석 중심에서 최대 그 거리만큼 떨어져 있을 수 있다. 그 위치 그대로
            // 앉으면 의자 옆 허공에 앉은 것처럼 보이므로, 착석 순간 좌석 위치로
            // 스냅한다(placeSeated가 입장 시 이미 하는 것과 동일).
            locomotionRoot?.position = SIMD3(seat.position.x, seat.sittingHeightOffset, seat.position.y)
            pendingSeatedArrivalIndex = claimedSeatIndex
            // cycler만 자동으로 다시 일어난다 — seatedPool은 영구 착석이라 타이머를
            // 두지 않는다(sittingRemaining이 nil로 남아 update()의 .sitting 분기가
            // 아무것도 하지 않는다).
            if role == .cycler {
                sittingRemaining = Float.random(in: NPCGuestTuning.sittingDurationRange)
            }
        } else {
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    /// 좌석까지 걸어가는 걸 완전히 포기하고 자리를 반납한다. 시간을 두고 재시도하지
    /// 않고(코디네이터가 seatOccupants를 즉시 비워 다른 손님에게 다시 배정할 수 있게
    /// 한다), 배회 상태로 되돌린다.
    private func vacateSeatDueToBlockage() {
        // 아직 좌석에 도착하지 못한 채(걸어가는 도중) 포기하는 경우라 이 손님의
        // 몸은 좌석 위치에 없다 — standUpAndResumeWandering과 달리 즉시 비워도
        // 안전하다.
        vacateClaimedSeat()
        seatState = .none
        activePath = []
        seatApproachBlockedCount = 0
        pauseRemaining = Float.random(in: 0.3...1.0)
        playAnimation(.idle)
    }

    // MARK: - Movement

    /// arrived: 목적지에 도착(또는 이미 도착해 있었음). moved: 이번 프레임에 실제로
    /// 위치가 바뀌었는지. blocked: 장애물에 사실상 막혀 더 못 감(= 원하는 이동
    /// 폭의 일정 비율도 못 갔음, stalled도 포함) — 호출부는 이걸 보고 Walk/Idle
    /// 애니메이션을 정한다.
    ///
    /// stalled: stallCheckInterval(1.2초) 동안 순 이동이 stallMinimumDistance보다
    /// 작았는지 — blocked와 별개 필드로 둔 이유는 호출부(update/updateMovingToSeat)의
    /// "연속 N회 막히면 포기" 카운터(consecutiveBlockedCount/seatApproachBlockedCount)가
    /// 프레임 단위 blocked만 보면 취약하기 때문이다. 여러 NPC가 좁은 공간에 몰려
    /// 서로 미묘하게 밀고 밀리면, 어느 한 프레임은 blockedStepFraction을 살짝 넘겨
    /// "막힘 아님"으로 판정되고 카운터가 0으로 리셋되는 일이 반복될 수 있다 —
    /// 그러면 실제로는 1.2초 넘게 제자리인데도 "3연속 막힘"에는 영원히 도달하지
    /// 못해 포기/탈출 로직이 아예 발동하지 않는다(실기에서 관찰된 "충돌 판정만
    /// 나며 계속 서 있는" 현상의 근본 원인). stalled는 프레임 단위 흔들림과 무관하게
    /// "1.2초간 순 이동이 거의 없었다"는 사실 자체를 보므로, 호출부는 이 신호
    /// 하나만으로도(연속 횟수를 더 쌓지 않고) 즉시 탈출/포기로 넘어간다.
    private struct MoveOutcome {
        let arrived: Bool
        let moved: Bool
        let blocked: Bool
        let stalled: Bool
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

    /// activePath의 웨이포인트를 순서대로 밟아 최종 목적지에 도달한다. 중간
    /// 웨이포인트 도착은 "아직 도착 안 함(moved: true)"으로만 보고하고, 마지막
    /// 웨이포인트(경로의 끝, 항상 최종 목적지와 같다)에 닿아야 진짜 arrived를
    /// 반환한다 — 호출부(update/updateMovingToSeat)는 이 시점에만 도착 후속
    /// 처리(착석 시작, 다음 배회 결정 등)를 해야 한다.
    private func moveAlongPath(deltaTime: Float,
                               movementArea: NPCGuestArea,
                               arrivalDistance: Float,
                               playerPosition: SIMD2<Float>,
                               neighboringPositions: [SIMD2<Float>],
                               neighborVelocities: [SIMD2<Float>] = [],
                               separationScale: Float,
                               exclusions: [NPCGuestArea] = [],
                               avoidPlayer: Bool = true,
                               avoidObstacles: Bool = true,
                               usePredictiveAvoidance: Bool = true) -> MoveOutcome {
        guard let waypoint = activePath.first else {
            return MoveOutcome(arrived: true, moved: false, blocked: false, stalled: false)
        }
        let isFinalWaypoint = activePath.count == 1
        let outcome = move(toward: waypoint, deltaTime: deltaTime,
                           movementArea: movementArea,
                           arrivalDistance: isFinalWaypoint ? arrivalDistance : NPCGuestTuning.arrivalDistance,
                           playerPosition: playerPosition,
                           neighboringPositions: neighboringPositions,
                           neighborVelocities: neighborVelocities,
                           separationScale: separationScale,
                           exclusions: exclusions,
                           avoidPlayer: avoidPlayer,
                           avoidObstacles: avoidObstacles,
                           usePredictiveAvoidance: usePredictiveAvoidance)
        guard outcome.arrived else { return outcome }
        activePath.removeFirst()
        return isFinalWaypoint
            ? outcome
            : MoveOutcome(arrived: false, moved: true, blocked: false, stalled: false)
    }

    private func move(toward target: SIMD2<Float>, deltaTime: Float,
                      movementArea: NPCGuestArea,
                      arrivalDistance: Float, playerPosition: SIMD2<Float>,
                      neighboringPositions: [SIMD2<Float>],
                      neighborVelocities: [SIMD2<Float>] = [],
                      separationScale: Float,
                      exclusions: [NPCGuestArea] = [],
                      avoidPlayer: Bool = true,
                      avoidObstacles: Bool = true,
                      usePredictiveAvoidance: Bool = true) -> MoveOutcome {
        guard let root = locomotionRoot else {
            return MoveOutcome(arrived: false, moved: false, blocked: false, stalled: false)
        }
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
            return MoveOutcome(arrived: true, moved: false, blocked: false, stalled: false)
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
        // avoidObstacles가 꺼진 좌석 바로 앞 구간(seatCollisionBypassDistance)에서는
        // NPCObstacleAvoidance의 이웃 하드 블록도 같이 꺼지므로, 이 레이어도 같은
        // 구간에서는 끈다 — "좌석 콜리전 프록시를 관통해 마지막 한 걸음을 확실히
        // 딛는다"는 그 구간의 의도를 옆으로 미는 보정이 방해하지 않게 한다.
        //
        // usePredictiveAvoidance가 false면(좌석 접근 전체 — updateMovingToSeat 호출부
        // 참고) avoidObstacles 상태와 무관하게 이 레이어를 통째로 끈다. 정지 이웃
        // 제외/막힘 시 원래 방향 재시도/stall 즉시 탈출 등 여러 차례 개별 완화를
        // 거쳤는데도 "좌석 근처에서 계속 서 있다"는 재현이 실기에서 반복돼, 좌석으로
        // 걸어가는 짧고 목적이 분명한 구간에서는 예측(먼 거리에서 미리 피하기)
        // 대신 반응형(crowdSteeredDirection의 즉시 반발)과 하드 세이프티 넷
        // (NPCObstacleAvoidance)만으로 충분하다고 판단해 아예 끈다 — 목적지 도달을
        // 예측 회피보다 우선한다(원 작업 지시의 "자연스러움을 위해 목적지 도달을
        // 희생하지 않는다" 원칙).
        let preferredDirection: SIMD2<Float>
        if avoidObstacles, usePredictiveAvoidance, !neighborVelocities.isEmpty {
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
        if avoidObstacles, let scene = root.scene {
            step = NPCObstacleAvoidance.allowedStep(
                scene: scene,
                from: SIMD3(current.x, 0, current.y),
                direction: SIMD3(direction.x, 0, direction.y),
                desiredStep: desiredStep,
                halfWidth: NPCGuestTuning.bodyHalfWidth,
                playerPosition: playerPosition,
                avoidPlayer: avoidPlayer,
                neighborPositions: neighboringPositions)
            // 예측 회피(NPCGuestLocalAvoidance)가 targetDirection을 실제로 옆으로
            // 틀었는데 그 방향이 하필 정적 장애물(테이블·카운터 등)로 막혀 있으면,
            // A*가 원래 뚫려 있다고 골라준 targetDirection 자체는 멀쩡한데도 좌/우
            // 보정 때문에 가만히 못 나아가는 경우가 있었다(좁은 통로에서 다른 NPC와
            // 마주쳤을 때 특히 그랬다 — 옆으로 피할 공간 자체가 없는데 계속 옆으로
            // 틀려고 하니 매 프레임 다시 막힘). 그 방향이 원래 방향과 실제로
            // 달랐고 사실상 막혔다면, 예측 회피 보정만 뺀 방향(즉시 반발은 유지)으로
            // 한 번 더 재시도해 실제로 더 나아갈 수 있으면 그쪽을 쓴다. A* 경로/
            // 웨이포인트는 전혀 건드리지 않는다 — 이번 한 스텝의 방향만 되돌린다.
            let isPredictiveAvoidanceEngaged = simd_length_squared(preferredDirection - targetDirection) > 0.0001
            if step < desiredStep * NPCGuestTuning.blockedStepFraction, isPredictiveAvoidanceEngaged {
                let fallbackDirection = crowdSteeredDirection(
                    targetDirection: targetDirection,
                    from: current,
                    neighbors: neighboringPositions,
                    scale: separationScale)
                let fallbackStep = NPCObstacleAvoidance.allowedStep(
                    scene: scene,
                    from: SIMD3(current.x, 0, current.y),
                    direction: SIMD3(fallbackDirection.x, 0, fallbackDirection.y),
                    desiredStep: desiredStep,
                    halfWidth: NPCGuestTuning.bodyHalfWidth,
                    playerPosition: playerPosition,
                    avoidPlayer: avoidPlayer,
                    neighborPositions: neighboringPositions)
                if fallbackStep > step {
                    direction = fallbackDirection
                    step = fallbackStep
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
            inside: movementArea,
            excluding: exclusions)
        step *= areaFraction
        // 진단용: "지지거림"(걷다 멈췄다 반복) 원인이 실제 장애물(레이캐스트)인지
        // 논리적 경계 클램프(allowedFraction)인지 분리해서 남긴다 — 둘 다 같은
        // step에 누적되므로 이 로그 없이는 blocked 판정만 보고는 구분이 안 된다.
        if step < desiredStep * NPCGuestTuning.blockedStepFraction {
            Self.movementLogger.notice(
                "\(self.name, privacy: .public) 막힘 진단: desired=\(desiredStep, privacy: .public) rayAfter=\(stepAfterObstacles, privacy: .public) areaFraction=\(areaFraction, privacy: .public) final=\(step, privacy: .public)")
        }
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
        // wanderTarget/pauseRemaining 갱신은 호출부(update의 배회·좌석 이동 분기)가
        // blocked를 보고 즉시 처리한다 — 여기서 같이 건드리면 호출부가 막 고른 새
        // 목적지를 다시 지워버리거나, 다음 프레임에 남은 pauseRemaining 때문에
        // "즉시 방향 전환"이 지연될 수 있다.
        return MoveOutcome(arrived: step >= distance, moved: moved,
                          blocked: isBlocked || isStalled, stalled: isStalled)
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

    /// 연속으로 막힌 끝에 부르는 최후 탈출: 먼 무작위 목적지 대신, 지금 위치
    /// 주변을 원형으로 훑어 논리적으로 유효하고 실제로도(레이캐스트) 가장 많이
    /// 뚫린 방향을 찾는다. randomWanderTarget이 매번 같은 막다른 방향의 후보만
    /// 뽑는 막다른 구석에서도 확실히 벗어나게 하는 안전망이다.
    private func nearbyEscapeTarget(from current: SIMD2<Float>,
                                    in area: NPCGuestArea,
                                    excluding exclusions: [NPCGuestArea]) -> SIMD2<Float>? {
        let scene = locomotionRoot?.scene
        let activeExclusions = exclusions.filter { !$0.contains(current) }
        let sampleCount = 16
        let probeDistance: Float = 1.0
        var best: SIMD2<Float>?
        var bestClearance: Float = 0
        for index in 0..<sampleCount {
            let angle = Float(index) / Float(sampleCount) * 2 * Float.pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let probe = current + direction * probeDistance
            // randomWanderTarget과 동일하게, 지금 이미 들어가 있는 구역은 "빠져나갈
            // 곳"이지 "들어가면 안 되는 곳"이 아니라 이번 탐색에서는 뺀다.
            guard NPCGuestNavigation.isValid(probe, inside: area, excluding: activeExclusions) else { continue }
            let clearance: Float
            if let scene {
                clearance = NPCObstacleAvoidance.allowedStep(
                    scene: scene, from: SIMD3(current.x, 0, current.y),
                    direction: SIMD3(direction.x, 0, direction.y),
                    desiredStep: probeDistance, halfWidth: NPCGuestTuning.bodyHalfWidth,
                    playerPosition: .zero, avoidPlayer: false)
            } else {
                clearance = probeDistance
            }
            guard clearance > bestClearance else { continue }
            bestClearance = clearance
            best = current + direction * clearance * 0.9
        }
        return best
    }

    // MARK: - Animation

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
