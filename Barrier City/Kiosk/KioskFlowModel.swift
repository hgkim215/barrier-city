//
//  KioskFlowModel.swift
//  Barrier City
//
//  키오스크 체험 상태 단일 진실원(InteractionModel 패턴).
//  전이 규칙은 KioskFlowLogic(순수 함수)에 위임하고, 여기서는 타이머 진행과
//  장바구니·카운터 등 상태 보관만 한다. tick은 InteractionSetup 구독이 dt를 주입한다.
//

import Observation

/// 키오스크 메뉴 항목. 순수 값 타입.
struct KioskMenuItem: Identifiable, Equatable {
    let id: String
    let name: String
    let price: Int
}

@Observable
@MainActor
final class KioskFlowModel {

    static let shared = KioskFlowModel()

    // MARK: 화면 상태
    private(set) var phase: KioskPhase = .browsing
    private(set) var cart: [KioskMenuItem] = []
    private(set) var categoryIndex = 0
    private(set) var idleRemaining: Float = KioskTuning.idleLimit
    private(set) var resetCount = 0
    private(set) var upperNearMissCount = 0
    private(set) var paymentAttempts = 0
    /// 근접 실패 순간마다 증가 — 뷰가 변화 자체를 하이라이트 펄스 트리거로 쓴다.
    private(set) var nearMissPulse = 0

    // MARK: 외부(틱·가드)가 설정하는 입력
    /// 이번 프레임 기준, 실기 손이 상단 존에 닿는가. 시뮬레이터는 항상 false.
    var reachableUpper = false
    /// 일어서기 오버레이 표시 중(StandUpGuard가 설정). 타이머 일시정지 조건.
    var standUpShown = false
    /// 키오스크 트리거 안(패널 표시 중)인가. InteractionSetup.tick이 매 프레임 갱신.
    var isActive = false

    private var resetHoldRemaining: Float = 0

    var cartTotal: Int { cart.reduce(0) { $0 + $1.price } }
    /// "손이 닿지 않습니다" 안내를 보여줄 만큼 근접 실패가 쌓였는가.
    var showsReachHint: Bool { upperNearMissCount >= KioskTuning.nearMissHintCount }

    // MARK: 진행

    /// 매 프레임. 유휴 타이머·리셋 연출만 진행한다.
    /// 정지 조건: 트리거 밖·일어서기 오버레이·씬 전환 중.
    func tick(dt: Float, transitioning: Bool) {
        guard isActive, !standUpShown, !transitioning else { return }
        switch phase {
        case .browsing, .payment:
            idleRemaining -= dt
            if idleRemaining <= 0 {
                phase = KioskFlowLogic.afterIdleTimeout(phase)
                resetCount += 1
                cart.removeAll()
                categoryIndex = 0
                resetHoldRemaining = KioskTuning.resetHoldSeconds
                if resetCount == 1 { PressureAudio.shared.onFirstReset() }
            }
        case .resetting:
            resetHoldRemaining -= dt
            if resetHoldRemaining <= 0 {
                phase = KioskFlowLogic.afterResetHold(phase)
                idleRemaining = KioskTuning.idleLimit
            }
        case .failed:
            break
        }
        PressureAudio.shared.tick(dt: dt)
    }

    // MARK: 입력(전부 유휴 타이머를 리셋한다)

    private func touch() { idleRemaining = KioskTuning.idleLimit }

    func addToCart(_ item: KioskMenuItem) {
        guard phase == .browsing else { return }
        touch()
        cart.append(item)
    }

    /// 상단 카테고리 탭. 실기에서 정말 닿았으면 전환(정직 판정), 아니면 근접 실패.
    func categoryTapped(_ index: Int) {
        guard phase == .browsing else { return }
        touch()
        if reachableUpper {
            categoryIndex = index
        } else {
            registerNearMiss()
        }
    }

    /// 하단 "주문하기" → 결제 화면(장바구니가 있어야).
    func proceedToPayment() {
        guard phase == .browsing, !cart.isEmpty else { return }
        touch()
        phase = .payment
    }

    /// 결제 확인(상단 존). 도달 여부와 무관하게 실패가 누적된다 —
    /// 버튼에 닿아도 카드 삽입구(최상단)까지는 조작할 수 없다는 설정(스펙 장벽 ③).
    func paymentConfirmTapped() {
        guard phase == .payment else { return }
        touch()
        registerNearMiss()
        let r = KioskFlowLogic.afterPaymentAttempt(phase: phase,
                                                   attempts: paymentAttempts,
                                                   maxAttempts: KioskTuning.paymentMaxAttempts)
        paymentAttempts = r.attempts
        if paymentAttempts == 1 { PressureAudio.shared.onPaymentStruggle() }
        phase = r.phase
        if phase == .failed {
            QuestModel.shared.advance(on: .kioskFailed)
        }
    }

    private func registerNearMiss() {
        nearMissPulse += 1
        upperNearMissCount += 1
    }

    /// 트리거 재진입 시 호출(InteractionSetup): 유휴 타이머만 리셋하고
    /// 진행 상태(장바구니·리셋 횟수·phase)는 유지한다 — 리셋 연출은 시간 초과로만.
    func resumeAtTrigger() {
        idleRemaining = KioskTuning.idleLimit
    }

    /// 몰입 공간 재진입 시 초기화(InteractionSetup.install 0단계에서 호출).
    func reset() {
        phase = .browsing
        cart.removeAll()
        categoryIndex = 0
        idleRemaining = KioskTuning.idleLimit
        resetCount = 0
        upperNearMissCount = 0
        paymentAttempts = 0
        nearMissPulse = 0
        resetHoldRemaining = 0
        reachableUpper = false
        standUpShown = false
        isActive = false
        PressureAudio.shared.reset()
    }
}
