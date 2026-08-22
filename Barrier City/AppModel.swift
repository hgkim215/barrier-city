import SwiftUI
import RealityKit

/// 앱 전역 상태.
///
/// 입력은 '충격량(impulse)'으로 모인다. 한 번 미는 동작이 누적 충격량을 만들고,
/// `WheelchairMovementSystem`이 매 프레임 이를 소비(consume)해 바퀴 속도에 더한다.
///   - 실기(Vision Pro): 손으로 바퀴를 잡고 앞으로 민 거리 → 충격량
///   - 시뮬레이터: "밀기" 버튼(누를 때마다 한 번의 stroke)
@Observable
@MainActor
final class AppModel {

    /// System 등 비-SwiftUI 코드에서 입력을 읽기 위한 전역 참조.
    /// 실제 화면(environment)에 쓰이는 인스턴스를 ImmersiveView에서 직접 등록한다.
    /// (약한 참조로 두면 버려진 인스턴스/해제로 nil이 될 수 있어 strong으로 보관)
    static var current: AppModel?

    // MARK: - 엔티티 참조(System이 직접 제어). 관찰 대상 아님.
    /// 캐릭터 캡슐(CharacterControllerComponent). 시뮬 공간에서 실제로 움직이며 충돌.
    @ObservationIgnored var characterBody: Entity?
    /// 보이는 카페 루트. 캡슐 위치의 역(inverse)으로 매 프레임 배치(world-inverse 시야).
    @ObservationIgnored var worldRoot: Entity?

    /// 실내 주문·서빙·대화 상태는 앱 수명 동안 하나의 의존성 그래프를 공유한다.
    let cafeOrderSession: CafeOrderSession
    let rainbowSmoothiePresenter: RainbowSmoothiePresenter
    let rainbowSmoothieServing: RainbowSmoothieServingController
    let npcDialogue: NPCDialogueController
    let npcClerk: NPCClerkController
    /// 배경으로 돌아다니는 손님 NPC들. 대화가 없는 순수 동선 담당이라 npcClerk와 분리했다.
    let npcGuests = NPCGuestCoordinator()
    /// 주행 물리 상태는 입력·앱 수명 상태와 분리해 MovementSystem의 변경 범위를 제한한다.
    let motion = WheelchairMotionState()
    /// 캐릭터 캡슐 전체 높이(m). 바닥 접지 = 중심.y - charHeight/2.
    static let charHeight: Float = 1.0
    static let charRadius: Float = 0.34

    /// 바닥/벽 콜리전 전용 충돌 그룹. 기울기용 광선이 '이 그룹만' 때려서
    /// 캐릭터 캡슐(다른 그룹)을 바닥으로 오인하지 않게 한다.
    static let groundGroup = CollisionGroup(rawValue: 1 << 5)

    /// 손님 NPC/Barista 몸통 콜리전 그룹(Entity.applyNPCBodyCollision에서 코드로 직접
    /// 부여). Indoor.usda에 RealityKit.Collider로 authoring된 값은 SceneEntityPreparation
    /// 의 removePhysics()가 씬 로드 시 재귀적으로 걷어내 런타임에 전혀 반영되지 않는다.
    /// 접지 판정(groundY/groundHit)에는 절대 섞지 않는다 — 섞으면 NPC 몸통을 바닥으로
    /// 오인해 높이가 튈 수 있다. 벽 감지(wallDistance)에만 groundGroup과 함께 마스크로 써서
    /// NPC도 막히게 한다.
    static let npcGroup = CollisionGroup(rawValue: 1)

    /// 시점(눈) 높이 보정. 바닥+휠체어를 이만큼 위로 올려 체감 눈높이를 낮춘다.
    /// 0 = 바닥을 실제 바닥에 맞춤(앉아서 테스트 시 자연스러움).
    /// 서서 테스트해서 시야가 너무 높으면 0.3~0.5 정도로.
    static let viewHeightOffset: Float = 0.0

    init() {
        let orderSession = CafeOrderSession()
        let presenter = RainbowSmoothiePresenter()
        let dialogue = NPCDialogueController(orderSession: orderSession)
        let serving = RainbowSmoothieServingController(
            session: orderSession,
            presenter: presenter,
            onReady: { [weak dialogue] in
                dialogue?.requestOrderReadyAnnouncement()
                GuideFlowModel.shared.handleQuestEvent(.drinkReady)
            })

        cafeOrderSession = orderSession
        rainbowSmoothiePresenter = presenter
        rainbowSmoothieServing = serving
        npcDialogue = dialogue
        npcClerk = NPCClerkController(
            dialogue: dialogue,
            smoothieServing: serving)

        // System/Component는 씬이 만들어지기 전, 앱 시작 시점에 등록해야 안전하다.
        // AppModel은 @State로 앱 시작 시 생성되므로 여기서 등록하면 타이밍이 이르다.
        WheelchairComponent.registerComponent()
        WheelchairMovementSystem.registerSystem()
    }

    /// 몰입 공간 열기/닫기와 뷰 생명주기가 공유하는 단일 상태.
    private(set) var immersiveSessionState = ImmersiveSessionState()
    @ObservationIgnored private var npcDialogueResetGate = ImmersiveGenerationResetGate()

    /// 기존 손 추적·진단 코드가 읽는 호환 속성.
    var isImmersive: Bool { immersiveSessionState.isImmersive }

    func beginImmersiveOpen() -> Int? {
        immersiveSessionState.beginOpen()
    }

    @discardableResult
    func completeImmersiveOpen(generation: Int, succeeded: Bool) -> Bool {
        immersiveSessionState.completeOpen(generation: generation, succeeded: succeeded)
    }

    func beginImmersiveClose() -> Int? {
        immersiveSessionState.beginClose()
    }

    @discardableResult
    func completeImmersiveClose(generation: Int) -> Bool {
        immersiveSessionState.completeClose(generation: generation)
    }

    func immersiveSessionAppeared() -> Int? {
        guard let generation = immersiveSessionState.appeared() else { return nil }
        resetNPCDialogueProgressIfNeeded(for: generation)
        return generation
    }

    /// 전체 NPC 대화 진행 초기화의 유일한 호출 지점이다.
    /// RealityView 재구성이나 indoor 전환이 아니라 새 immersive generation에만 반응한다.
    private func resetNPCDialogueProgressIfNeeded(for generation: Int) {
        guard npcDialogueResetGate.shouldReset(for: generation) else { return }
        npcDialogue.resetImmersiveProgress()
    }

    func immersiveSessionDisappeared(generation: Int) -> Bool {
        let didDisappear = immersiveSessionState.disappeared(generation: generation)
        if didDisappear {
            npcDialogue.endImmersiveSession()
        }
        return didDisappear
    }

    /// 손 추적을 쓸지(실기), 버튼 입력을 쓸지(시뮬레이터).
    var useHandTracking = false

    // MARK: - 테스트용 주먹 드론 조작
    /// true면 바퀴 근처에서 양손을 잡는 대신, 주먹 하나를 가상 스틱처럼 사용한다.
    /// 손 추적 자체(`useHandTracking`)와 분리해 기존 바퀴 밀기 조작을 그대로 보존한다.
    var testFistDriveEnabled = false
    /// 테스트 모드가 손 추적을 자동으로 켰다면 OFF 때 원래 설정으로 복원한다.
    @ObservationIgnored private var handTrackingBeforeFistDrive = false
    /// 현재 어느 한 손이 주먹을 쥐고 테스트 조작권을 가진 상태.
    var fistDriveActive = false
    /// 창에 표시할 정규화 입력값. 전진은 0...1, 회전은 -1...1(음수=왼쪽).
    var fistDriveForwardAxis: Float = 0
    var fistDriveTurnAxis: Float = 0
    /// 차동 구동 System이 추종할 좌/우 바퀴 목표 속도(m/s).
    var fistDriveTargetLeft: Float = 0
    var fistDriveTargetRight: Float = 0
    /// 마지막으로 유효한 조작 손 샘플을 받은 시각. 추적 유실 안전 정지에 사용한다.
    var fistDriveLastUpdate: TimeInterval = 0
    /// UI에 표시할 현재 조작 손 이름.
    var fistDriveHand = ""
    /// 토글·재시작·추적 유실 때 HandTrackingManager에 재보정을 요청하는 세대 값.
    var fistDriveResetID = 0
    /// 다음 물리 프레임에서 관성까지 제거하는 테스트 조작 전용 하드 스톱.
    private var fistDriveHardStopRequested = false
    /// 권한/연결/보정 상태를 테스트 창에서 바로 확인하기 위한 문구.
    var handTrackingStatus = "꺼짐"
    var worldTrackingStatus = "대기"
    var worldTrackingFallbacks = 0

    // MARK: - 누적 충격량(매 프레임 System이 소비 후 0으로 리셋)
    var pendingImpulseLeft: Float = 0
    var pendingImpulseRight: Float = 0

    /// 브레이크 요청(다음 프레임에 속도를 강하게 감쇠).
    var brakeRequested = false

    // MARK: - 잡힘 상태(시각 피드백)
    var leftGrabbed = false
    var rightGrabbed = false

    // MARK: - 잡은 손의 현재 전진 속도(m/s). 잡고 있는 동안 바퀴 속도를 이 값으로 고정.
    var handSpeedLeft: Float = 0
    var handSpeedRight: Float = 0

    // MARK: - 바퀴 배치(잡기 거리 판정 + 엔티티 배치 공용 기준)
    // 앉아서도 잡기 쉽도록 바퀴를 키움. 중심 y=반경이면 바닥에 닿고 위쪽은 엉덩이~손 높이.
    static let wheelRadius: Float = 0.34
    /// 잡기 인식 기준 높이(바퀴 중심이 아니라 윗부분을 잡고 굴리도록 위로 올림).
    static let grabHeight: Float = 0.55
    static let leftWheelPos = SIMD3<Float>(-0.36, grabHeight, -0.12)
    static let rightWheelPos = SIMD3<Float>(0.36, grabHeight, -0.12)
    /// 손목이 바퀴 기준점에서 이 거리 안에 있어야 '바퀴를 잡는' 것으로 인정(잡기 시작).
    static let grabRadius: Float = 0.34

    /// 진단: 각 손과 해당 바퀴 사이 거리(m).
    var leftWheelDist: Float = 0
    var rightWheelDist: Float = 0

    // MARK: - 디버그 표시
    /// 밀기 버튼이 눌린 횟수(UI 측).
    var pushCount: Int = 0
    /// System이 0이 아닌 충격량을 실제로 받은 횟수(엔진 측).
    var impulseApplied: Int = 0
    // MARK: - 손 추적 진단
    /// 손 앵커 업데이트를 받은 총 횟수(0에서 안 변하면 데이터가 안 들어옴).
    var handUpdates: Int = 0
    /// 그중 실제로 '추적됨(isTracked)' 상태였던 횟수.
    var handTracked: Int = 0
    /// 그중 손 골격(handSkeleton)이 있었던 횟수.
    var handSkeletonOK: Int = 0
    /// 마지막으로 측정한 좌/우 손의 쥠 세기(0=편 손, 1=주먹).
    var leftGrabStrength: Float = 0
    var rightGrabStrength: Float = 0
    /// 보정용 원시값: 손가락끝-손목 평균거리 / 손크기 (펴면 큼, 주먹이면 작음).
    var leftRawD: Float = 0
    var rightRawD: Float = 0

    // MARK: - 입력 API

    /// 한 번의 밀기 세기(m/s 상당). 버튼 한 번에 더해지는 충격량.
    nonisolated static let strokeAmount: Float = 0.5

    func pushLeft(_ amount: Float = AppModel.strokeAmount)  { pendingImpulseLeft += amount; pushCount += 1 }
    func pushRight(_ amount: Float = AppModel.strokeAmount) { pendingImpulseRight += amount; pushCount += 1 }
    func pushBoth(_ amount: Float = AppModel.strokeAmount)  { pushLeft(amount); pushRight(amount) }
    func brake() { brakeRequested = true }

    /// 창의 일반 손 추적 토글. 끌 때 테스트 조작도 함께 안전하게 해제한다.
    func setHandTrackingEnabled(_ enabled: Bool) {
        useHandTracking = enabled
        if enabled {
            handTrackingStatus = isImmersive ? "손 추적 연결 중…" : "체험을 시작하면 손 추적을 연결합니다"
        } else {
            testFistDriveEnabled = false
            handTrackingBeforeFistDrive = false
            releaseWheelHandInput()
            stopFistDrive(requestRecenter: true)
            handTrackingStatus = "꺼짐"
        }
    }

    /// 테스트용 가상 스틱 모드 토글. ON이면 손 추적도 자동으로 켠다.
    func setTestFistDriveEnabled(_ enabled: Bool) {
        guard testFistDriveEnabled != enabled else { return }
        if enabled {
            handTrackingBeforeFistDrive = useHandTracking
        }

        testFistDriveEnabled = enabled
        releaseWheelHandInput()
        stopFistDrive(requestRecenter: true)

        if enabled {
            useHandTracking = true
            handTrackingStatus = isImmersive
                ? "손 추적 연결 중…"
                : "체험을 시작한 뒤 주먹을 쥐세요"
        } else {
            useHandTracking = handTrackingBeforeFistDrive
            handTrackingBeforeFistDrive = false
            handTrackingStatus = useHandTracking
                ? "기존 바퀴 손 추적 모드"
                : "꺼짐"
        }
    }

    /// HandTrackingManager가 계산한 정규화 축을 테스트 전용 차동 구동 명령으로 바꾼다.
    func updateFistDrive(forwardAxis: Float,
                         turnAxis: Float,
                         hand: String,
                         timestamp: TimeInterval) {
        guard testFistDriveEnabled else { return }

        let forwardAxis = max(0, min(1, forwardAxis))
        let turnAxis = max(-1, min(1, turnAxis))
        let forward = forwardAxis * 1.0
        // 중앙에서 미세 조향이 쉽도록 부호를 유지한 제곱 커브를 사용한다.
        let turn = turnAxis * abs(turnAxis) * 0.35

        fistDriveActive = true
        fistDriveForwardAxis = forwardAxis
        fistDriveTurnAxis = turnAxis
        fistDriveTargetLeft = forward + turn
        fistDriveTargetRight = forward - turn
        fistDriveLastUpdate = timestamp
        fistDriveHand = hand
        handTrackingStatus = "\(hand)으로 조작 중"
    }

    /// 테스트 조작 명령을 해제한다. 실제 속도 제거는 System이 다음 프레임에 처리한다.
    func stopFistDrive(requestRecenter: Bool,
                       status: String? = nil) {
        fistDriveActive = false
        fistDriveForwardAxis = 0
        fistDriveTurnAxis = 0
        fistDriveTargetLeft = 0
        fistDriveTargetRight = 0
        fistDriveLastUpdate = 0
        fistDriveHand = ""
        fistDriveHardStopRequested = true
        if requestRecenter { fistDriveResetID &+= 1 }
        if let status { handTrackingStatus = status }
    }

    /// 테스트 입력이 사라졌는데 관성으로 계속 달리는 일을 막는 one-shot 신호.
    func consumeFistDriveHardStop() -> Bool {
        defer { fistDriveHardStopRequested = false }
        return fistDriveHardStopRequested
    }

    /// 일반 바퀴 잡기 경로의 잔여 입력을 지운다(두 손 입력 모드 충돌 방지).
    func releaseWheelHandInput() {
        leftGrabbed = false
        rightGrabbed = false
        handSpeedLeft = 0
        handSpeedRight = 0
    }

    func prepareForGuidePhaseChange(isLocked: Bool) {
        motion.leftVelocity = 0
        motion.rightVelocity = 0
        pendingImpulseLeft = 0
        pendingImpulseRight = 0
        brakeRequested = false
        releaseWheelHandInput()
        stopFistDrive(
            requestRecenter: true,
            status: isLocked && testFistDriveEnabled ? "가이드 확인 중" : nil)
    }

    func discardGuideLockedInput() {
        motion.leftVelocity = 0
        motion.rightVelocity = 0
        pendingImpulseLeft = 0
        pendingImpulseRight = 0
        brakeRequested = false
        releaseWheelHandInput()
        fistDriveActive = false
        fistDriveForwardAxis = 0
        fistDriveTurnAxis = 0
        fistDriveTargetLeft = 0
        fistDriveTargetRight = 0
        fistDriveLastUpdate = 0
        fistDriveHand = ""
    }

    /// System이 호출: 누적 충격량을 가져오고 리셋.
    func consumeImpulses() -> (left: Float, right: Float) {
        defer { pendingImpulseLeft = 0; pendingImpulseRight = 0 }
        return (pendingImpulseLeft, pendingImpulseRight)
    }

    /// 다시 시작: 시작 위치/자세로 모든 상태 초기화.
    func restart() {
        motion.reset()
        releaseWheelHandInput()
        stopFistDrive(requestRecenter: true,
                      status: testFistDriveEnabled ? "다시 주먹을 쥐어 중립점을 잡으세요" : nil)
        pendingImpulseLeft = 0; pendingImpulseRight = 0
    }
}
