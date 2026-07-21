# 키오스크 체험 구체화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 휠체어 사용자가 키오스크 주문을 직접 시도하다 누적 장벽(리치 실패·시간 초과·결제 불가)에 좌절하고 NPC 직원에게 음성으로 주문하는 흐름을 구현한다.

**Architecture:** 기존 패턴 준수 — `@Observable @MainActor` 싱글턴(상태) + nonisolated 순수 함수(판정, 테스트 대상) + Tuning enum(상수) + `InteractionSetup`의 SceneEvents.Update 틱(매 프레임 배선). 키오스크 UI는 빌보드가 아니라 Kiosk 프림 표면에 월드 고정된 실물 크기 attachment.

**Tech Stack:** visionOS SwiftUI + RealityKit, ARKit(HandTracking·WorldTracking), XCTest, DialogueKit(기존 패키지, 무수정), AVAudioEngine(합성음), 프록시 TTS(VoiceOutput).

**Spec:** `docs/superpowers/specs/2026-07-21-kiosk-experience-design.md`

## Global Constraints

- 언어: 코드 주석·UI 문구는 한국어(기존 파일 관례). 식별자는 영어.
- 테스트 프레임워크: **XCTest** (DialogueKit 관례. Swift Testing 사용 금지 — 스펙의 "Swift Testing" 언급은 관례 확인 후 XCTest로 확정됨).
- 에러 처리: 전부 fail-open — 에셋/추적/네트워크가 없어도 체험이 막히지 않아야 한다.
- 시뮬레이터 우선: 모든 기능이 시뮬레이터에서 완주 가능해야 한다. 실기 전용 상수는 `KioskTuning`에 모으고 주석에 "실측 조정" 표기.
- 기존 파일 최소 수정: `AppModel`(+2 프로퍼티), `HandTrackingManager`(+좌표 기록), `ImmersiveView`(attachment 블록만), `QuestModel` 무수정.
- 테스트 실행 커맨드(전 태스크 공통):
  `xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20`
  빌드만 확인할 때:
  `xcodebuild build -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -5`
- 작업 디렉토리(모든 명령의 cwd): `/Users/mac/Library/Mobile Documents/com~apple~CloudDocs/Engineering/XR/Barrier City`
- 커밋 컨벤션: `feat(kiosk): …` / `feat(npc): …` / `test: …` / `chore: …` (기존 로그 참고).

---

### Task 1: 유닛 테스트 타깃 신설

**Files:**
- Create: `scripts/add_test_target.rb` (일회성 도구)
- Create: `Barrier CityTests/SmokeTests.swift`
- Modify: `Barrier City.xcodeproj` (스크립트가 수정)

**Interfaces:**
- Produces: `Barrier CityTests` 유닛 테스트 타깃(호스트 앱 `Barrier City`), 공유 스킴 `Barrier City`에 Test 액션 연결. 이후 모든 태스크가 `@testable import Barrier_City`로 앱 코드를 테스트한다.

- [ ] **Step 1: xcodeproj gem 설치**

Run: `gem install --user-install xcodeproj 2>&1 | tail -2`
Expected: `1 gem installed` (이미 있으면 그대로 성공).
실패 시(네트워크 등): 이 태스크를 중단하고 사용자에게 Xcode GUI 대체 경로를 요청한다 — Xcode에서 File > New > Target… > visionOS > Unit Testing Bundle, 이름 `Barrier CityTests`, Host Application `Barrier City` 선택 후 Step 4로 건너뜀.

- [ ] **Step 2: 스모크 테스트 파일 작성**

`Barrier CityTests/SmokeTests.swift`:
```swift
//
//  SmokeTests.swift
//  Barrier CityTests
//
//  테스트 타깃 동작 확인용 스모크 테스트.
//

import XCTest
@testable import Barrier_City

final class SmokeTests: XCTestCase {
    func testTargetRuns() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: 타깃 생성 스크립트 작성·실행**

`scripts/add_test_target.rb`:
```ruby
# 일회성: Barrier CityTests 유닛 테스트 타깃을 만들고 공유 스킴에 연결한다.
require 'xcodeproj'

proj = Xcodeproj::Project.open('Barrier City.xcodeproj')
abort '이미 존재' if proj.targets.any? { |t| t.name == 'Barrier CityTests' }
app = proj.targets.find { |t| t.name == 'Barrier City' } or abort '앱 타깃 없음'

test = proj.new_target(:unit_test_bundle, 'Barrier CityTests', :visionos,
                       app.deployment_target)
test.build_configurations.each do |c|
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  c.build_settings['TEST_HOST'] =
    '$(BUILT_PRODUCTS_DIR)/Barrier City.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Barrier City'
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.barriercity.BarrierCityTests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['SWIFT_VERSION'] =
    app.build_configurations.first.build_settings['SWIFT_VERSION'] || '5.0'
end
test.add_dependency(app)

group = proj.main_group.find_subpath('Barrier CityTests', true)
group.set_source_tree('<group>')
group.set_path('Barrier CityTests')
file = group.new_file('SmokeTests.swift')
test.add_file_references([file])
proj.save

# 공유 스킴: 앱 빌드 + 테스트 타깃을 Test 액션에 연결.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test)
scheme.set_launch_target(app)
scheme.save_as('Barrier City.xcodeproj', 'Barrier City')
puts 'OK'
```

Run: `ruby scripts/add_test_target.rb` (gem 경로 문제 시 `ruby -rrubygems scripts/add_test_target.rb` 또는 `GEM_HOME=~/.gem ruby ...`)
Expected: `OK`

- [ ] **Step 4: 테스트 실행으로 검증**

Run: `xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20`
Expected: `Test Suite 'SmokeTests' passed` 및 `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add "Barrier City.xcodeproj" "Barrier CityTests" scripts
git commit -m "test: Barrier CityTests 유닛 테스트 타깃 신설"
```

---

### Task 2: KioskTuning + KioskPhase + KioskFlowLogic (순수 판정, TDD)

**Files:**
- Create: `Barrier City/Kiosk/KioskTuning.swift`
- Create: `Barrier City/Kiosk/KioskFlowLogic.swift`
- Test: `Barrier CityTests/KioskFlowLogicTests.swift`

새 파일을 앱 타깃에 추가하는 법: Xcode가 폴더 동기화(fileSystemSynchronizedGroups)를 쓰지 않는 프로젝트이므로, 파일 생성 후 `ruby scripts/add_files.rb` 헬퍼로 추가한다(Step 1에서 작성). 이후 태스크도 동일 헬퍼를 쓴다.

**Interfaces:**
- Produces:
  - `enum KioskPhase: Equatable { case browsing, resetting, payment, failed }`
  - `KioskFlowLogic.afterIdleTimeout(_ phase: KioskPhase) -> KioskPhase`
  - `KioskFlowLogic.afterResetHold(_ phase: KioskPhase) -> KioskPhase`
  - `KioskFlowLogic.afterPaymentAttempt(phase: KioskPhase, attempts: Int, maxAttempts: Int) -> (phase: KioskPhase, attempts: Int)`
  - `KioskFlowLogic.canReach(hand: SIMD3<Float>?, kioskXZ: SIMD2<Float>, zoneMinY: Float, margin: Float, maxXZ: Float) -> Bool`
  - `KioskFlowLogic.standUpShown(currentlyShown: Bool, headY: Float, baselineY: Float, enter: Float, exit: Float) -> Bool`
  - `KioskTuning` 상수 전부 (아래 코드 참조)

- [ ] **Step 1: 파일 추가 헬퍼 스크립트 작성**

`scripts/add_files.rb`:
```ruby
# 사용: ruby scripts/add_files.rb <target명> <파일경로>...
# 파일을 그룹 트리에 만들고 지정 타깃의 컴파일 소스에 추가한다(이미 있으면 건너뜀).
require 'xcodeproj'

target_name = ARGV.shift or abort '타깃명 필요'
proj = Xcodeproj::Project.open('Barrier City.xcodeproj')
target = proj.targets.find { |t| t.name == target_name } or abort "타깃 없음: #{target_name}"

ARGV.each do |path|
  next if proj.files.any? { |f| f.real_path.to_s.end_with?(path) }
  parts = path.split('/')
  fname = parts.pop
  group = proj.main_group
  parts.each { |p| group = group.find_subpath(p, true); group.set_source_tree('<group>'); group.set_path(p) if group.path.nil? }
  ref = group.new_file(fname)
  target.add_file_references([ref])
  puts "추가: #{path} -> #{target_name}"
end
proj.save
```

- [ ] **Step 2: 실패하는 테스트 작성**

`Barrier CityTests/KioskFlowLogicTests.swift`:
```swift
//
//  KioskFlowLogicTests.swift
//  Barrier CityTests
//
//  키오스크 상태 전이·리치·일어서기 판정(순수 함수) 단위 테스트.
//

import XCTest
import simd
@testable import Barrier_City

final class KioskFlowLogicTests: XCTestCase {

    // MARK: 유휴 시간 초과

    func testIdleTimeout_browsingGoesToResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.browsing), .resetting)
    }
    func testIdleTimeout_paymentGoesToResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.payment), .resetting)
    }
    func testIdleTimeout_failedStaysFailed() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.failed), .failed)
    }
    func testIdleTimeout_resettingStaysResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.resetting), .resetting)
    }

    // MARK: 리셋 연출 종료

    func testResetHold_resettingGoesToBrowsing() {
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.resetting), .browsing)
    }
    func testResetHold_otherPhasesUnchanged() {
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.payment), .payment)
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.failed), .failed)
    }

    // MARK: 결제 시도

    func testPaymentAttempt_incrementsBelowThreshold() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .payment, attempts: 0, maxAttempts: 3)
        XCTAssertEqual(r.phase, .payment)
        XCTAssertEqual(r.attempts, 1)
    }
    func testPaymentAttempt_failsAtThreshold() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .payment, attempts: 2, maxAttempts: 3)
        XCTAssertEqual(r.phase, .failed)
        XCTAssertEqual(r.attempts, 3)
    }
    func testPaymentAttempt_ignoredOutsidePayment() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .browsing, attempts: 0, maxAttempts: 3)
        XCTAssertEqual(r.phase, .browsing)
        XCTAssertEqual(r.attempts, 0)
    }

    // MARK: 리치 판정

    func testCanReach_nilHandNeverReaches() {
        XCTAssertFalse(KioskFlowLogic.canReach(hand: nil, kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_highHandNearKioskReaches() {
        // 키오스크 바로 앞에서 손을 1.5m까지 올림 → 닿음
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(0, 1.5, -0.8), kioskXZ: SIMD2(0, -1),
                                              zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_lowHandDoesNotReach() {
        // 앉은 손 높이(1.1m) → 안 닿음
        XCTAssertFalse(KioskFlowLogic.canReach(hand: SIMD3(0, 1.1, -0.8), kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_farHandDoesNotReach() {
        // 높이는 충분해도 키오스크에서 3m 떨어짐 → 안 닿음
        XCTAssertFalse(KioskFlowLogic.canReach(hand: SIMD3(3, 1.6, -1), kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_marginAllowsSlightlyBelowZone() {
        // 존 최소 높이보다 여유(margin)만큼 아래까지는 닿음 처리
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(0, 1.36, -0.8), kioskXZ: SIMD2(0, -1),
                                              zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }

    // MARK: 일어서기 판정(히스테리시스)

    func testStandUp_entersAboveEnterThreshold() {
        XCTAssertTrue(KioskFlowLogic.standUpShown(currentlyShown: false, headY: 1.30,
                                                  baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
    func testStandUp_staysHiddenBelowEnterThreshold() {
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: false, headY: 1.20,
                                                   baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
    func testStandUp_staysShownUntilExitThreshold() {
        // 표시 중에는 exit 아래로 내려와야 해제(깜빡임 방지)
        XCTAssertTrue(KioskFlowLogic.standUpShown(currentlyShown: true, headY: 1.20,
                                                  baselineY: 1.0, enter: 0.25, exit: 0.15))
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: true, headY: 1.10,
                                                   baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
}
```

- [ ] **Step 3: 테스트 파일을 테스트 타깃에 추가하고 실패 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier CityTests" "Barrier CityTests/KioskFlowLogicTests.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: 컴파일 실패 — `cannot find 'KioskFlowLogic' in scope`

- [ ] **Step 4: 구현 작성**

`Barrier City/Kiosk/KioskTuning.swift`:
```swift
//
//  KioskTuning.swift
//  Barrier City
//
//  키오스크 체험 튜닝 상수 단일 진실원(InteractionTuning 패턴).
//  [실측 조정] 표기 상수는 실기 테스트에서 값을 확정한다.
//

import simd

enum KioskTuning {
    // MARK: 화면 존 경계(월드 y, m) — 서 있는 성인 기준 키오스크
    /// 키오스크 화면 패널 중심 높이. [실측 조정]
    static let screenCenterY: Float = 1.25
    /// 이 높이 위는 '상단 존'(카테고리 탭·결제 버튼). 앉은 손은 못 닿는다. [실측 조정]
    static let upperZoneMinY: Float = 1.4
    /// 리치 판정 여유(m). 존 경계보다 이만큼 아래까지는 닿은 것으로 인정.
    static let reachMargin: Float = 0.05
    /// 리치 판정 대상이 되는 손-키오스크 수평 최대 거리(m).
    static let reachMaxXZ: Float = 1.2

    // MARK: 유휴 타이머
    /// 입력이 없을 때 처음 화면으로 리셋되기까지의 시간(초). 짧아야 장벽 ②가 잘 발동한다.
    static let idleLimit: Float = 20
    /// "처음 화면으로 돌아갑니다" 리셋 연출 유지 시간(초).
    static let resetHoldSeconds: Float = 3

    // MARK: 실패 임계
    /// 상단 존 근접 실패(near-miss)가 이 횟수 이상이면 "손이 닿지 않습니다" 안내 표시.
    static let nearMissHintCount = 3
    /// 결제 시도 실패가 이 횟수에 도달하면 최종 실패(장벽 ③).
    static let paymentMaxAttempts = 3

    // MARK: 일어서기 가드
    /// 기준 대비 머리가 이만큼 오르면 오버레이 표시(m).
    static let standUpEnter: Float = 0.25
    /// 표시 중 이 값 아래로 내려와야 해제(히스테리시스, m).
    static let standUpExit: Float = 0.15

    // MARK: NPC
    /// NPC 대화 트리거 진입 반경(m).
    static let npcTriggerRadius: Float = 2.5
    /// 카운터(Bar) 프림을 못 찾을 때 NPC 폴백 좌표(맵 좌표 x, z). [실측 조정]
    static let npcFallbackCenter = SIMD2<Float>(4, -4)
    /// NPC 모델 스케일·yaw. Skull.usdz 실물 확인 후 조정. [실측 조정]
    static let npcScale: Float = 1.0
    static let npcYaw: Float = .pi
}
```

`Barrier City/Kiosk/KioskFlowLogic.swift`:
```swift
//
//  KioskFlowLogic.swift
//  Barrier City
//
//  키오스크 상태 전이·리치·일어서기 판정(순수 함수).
//  QuestProgression 패턴 — KioskFlowModel이 호출하고 단위 테스트가 직접 검증한다.
//

import simd

/// 키오스크 화면 단계.
enum KioskPhase: Equatable {
    case browsing    // 메뉴 탐색·장바구니
    case resetting   // 시간 초과 리셋 연출 중
    case payment     // 결제 화면
    case failed      // 최종 실패(직원 안내)
}

enum KioskFlowLogic {

    /// 유휴 시간 초과: 조작 중(browsing·payment)에만 리셋 연출로 전이.
    static func afterIdleTimeout(_ phase: KioskPhase) -> KioskPhase {
        switch phase {
        case .browsing, .payment: return .resetting
        case .resetting, .failed: return phase
        }
    }

    /// 리셋 연출 종료 → 처음 화면.
    static func afterResetHold(_ phase: KioskPhase) -> KioskPhase {
        phase == .resetting ? .browsing : phase
    }

    /// 결제 시도 실패 누적. 임계 도달 시 최종 실패.
    static func afterPaymentAttempt(phase: KioskPhase, attempts: Int,
                                    maxAttempts: Int) -> (phase: KioskPhase, attempts: Int) {
        guard phase == .payment else { return (phase, attempts) }
        let n = attempts + 1
        return (n >= maxAttempts ? .failed : .payment, n)
    }

    /// 리치 판정: 손이 키오스크 수평 근방(maxXZ)에 있고 손 높이가
    /// 존 최소 높이 − 여유 이상이면 닿음. hand가 nil(시뮬레이터·추적 불가)이면 항상 실패.
    static func canReach(hand: SIMD3<Float>?, kioskXZ: SIMD2<Float>,
                         zoneMinY: Float, margin: Float, maxXZ: Float) -> Bool {
        guard let hand else { return false }
        let horiz = simd_distance(SIMD2(hand.x, hand.z), kioskXZ)
        return horiz <= maxXZ && hand.y >= zoneMinY - margin
    }

    /// 일어서기 오버레이 표시 여부(히스테리시스).
    /// 미표시 → 기준+enter 초과 시 표시. 표시 중 → 기준+exit 아래로 내려와야 해제.
    static func standUpShown(currentlyShown: Bool, headY: Float, baselineY: Float,
                             enter: Float, exit: Float) -> Bool {
        let rise = headY - baselineY
        return currentlyShown ? rise > exit : rise > enter
    }
}
```

- [ ] **Step 5: 소스를 앱 타깃에 추가하고 테스트 통과 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Kiosk/KioskTuning.swift" "Barrier City/Kiosk/KioskFlowLogic.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, KioskFlowLogicTests 17개 전부 PASS

- [ ] **Step 6: Commit**

```bash
git add "Barrier City/Kiosk" "Barrier CityTests/KioskFlowLogicTests.swift" scripts/add_files.rb "Barrier City.xcodeproj"
git commit -m "feat(kiosk): 상태 전이·리치·일어서기 판정 순수 함수 + 튜닝 상수 (TDD)"
```

---

### Task 3: KioskFlowModel 상태 머신 (TDD)

**Files:**
- Create: `Barrier City/Kiosk/KioskFlowModel.swift`
- Test: `Barrier CityTests/KioskFlowModelTests.swift`

**Interfaces:**
- Consumes: `KioskPhase`, `KioskFlowLogic`, `KioskTuning` (Task 2), `QuestModel.shared.advance(on:)`, `KioskMenuItem` (Task 4에서 정의되지만 이 태스크에서 함께 선언 — 아래 참조)
- Produces (이후 태스크가 의존하는 API):
  - `KioskFlowModel.shared` (`@Observable @MainActor` 싱글턴)
  - `var phase: KioskPhase`, `var cart: [KioskMenuItem]`, `var cartTotal: Int`
  - `var idleRemaining: Float`, `var resetCount: Int`, `var paymentAttempts: Int`
  - `var upperNearMissCount: Int`, `var nearMissPulse: Int`, `var showsReachHint: Bool`
  - `var categoryIndex: Int`
  - `var reachableUpper: Bool`, `var standUpShown: Bool`, `var isActive: Bool` (외부에서 설정)
  - `func tick(dt: Float, transitioning: Bool)`
  - `func addToCart(_:)`, `func categoryTapped(_ index: Int)`, `func proceedToPayment()`, `func paymentConfirmTapped()`, `func resumeAtTrigger()`, `func reset()`
- `KioskMenuItem`은 이 태스크에서 만든다(모델이 의존하므로):
  `struct KioskMenuItem: Identifiable, Equatable { let id: String; let name: String; let price: Int }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Barrier CityTests/KioskFlowModelTests.swift`:
```swift
//
//  KioskFlowModelTests.swift
//  Barrier CityTests
//
//  KioskFlowModel 통합 동작(타이머·전이·근접 실패) 테스트.
//  싱글턴이지만 reset()으로 매 테스트 초기화한다. tick은 dt 주입식이라 결정적.
//

import XCTest
@testable import Barrier_City

@MainActor
final class KioskFlowModelTests: XCTestCase {

    let item = KioskMenuItem(id: "americano", name: "아메리카노", price: 4000)

    override func setUp() async throws {
        KioskFlowModel.shared.reset()
        KioskFlowModel.shared.isActive = true
    }

    func testIdleTimeout_resetsCartAndCountsReset() {
        let m = KioskFlowModel.shared
        m.addToCart(item)
        // 유휴 한계 + 1초 경과
        m.tick(dt: KioskTuning.idleLimit + 1, transitioning: false)
        XCTAssertEqual(m.phase, .resetting)
        XCTAssertEqual(m.resetCount, 1)
        XCTAssertTrue(m.cart.isEmpty)
        // 리셋 연출 종료 → 처음 화면 + 타이머 복구
        m.tick(dt: KioskTuning.resetHoldSeconds + 0.1, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)
        XCTAssertEqual(m.idleRemaining, KioskTuning.idleLimit, accuracy: 0.01)
    }

    func testTickPaused_whenInactiveOrStandUpOrTransitioning() {
        let m = KioskFlowModel.shared
        m.isActive = false
        m.tick(dt: 999, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)

        m.isActive = true
        m.standUpShown = true
        m.tick(dt: 999, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)

        m.standUpShown = false
        m.tick(dt: 999, transitioning: true)
        XCTAssertEqual(m.phase, .browsing)
    }

    func testInputResetsIdleTimer() {
        let m = KioskFlowModel.shared
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        m.addToCart(item)   // 입력 → 타이머 리셋
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)   // 아직 리셋 안 됨
    }

    func testCategoryTapped_unreachableCountsNearMiss() {
        let m = KioskFlowModel.shared
        m.reachableUpper = false
        for _ in 0..<KioskTuning.nearMissHintCount { m.categoryTapped(1) }
        XCTAssertEqual(m.categoryIndex, 0)                 // 카테고리 안 바뀜
        XCTAssertEqual(m.upperNearMissCount, KioskTuning.nearMissHintCount)
        XCTAssertTrue(m.showsReachHint)
    }

    func testCategoryTapped_reachableSwitchesCategory() {
        let m = KioskFlowModel.shared
        m.reachableUpper = true   // 실기에서 정말 손이 닿은 경우(정직 판정)
        m.categoryTapped(2)
        XCTAssertEqual(m.categoryIndex, 2)
        XCTAssertEqual(m.upperNearMissCount, 0)
    }

    func testPaymentFlow_failsAtThresholdAndStaysFailed() {
        let m = KioskFlowModel.shared
        m.addToCart(item)
        m.proceedToPayment()
        XCTAssertEqual(m.phase, .payment)
        for _ in 0..<KioskTuning.paymentMaxAttempts { m.paymentConfirmTapped() }
        XCTAssertEqual(m.phase, .failed)
        // failed 이후는 타이머·입력에 반응하지 않는다(재접근 시 직원 안내 고정)
        m.tick(dt: 999, transitioning: false)
        m.paymentConfirmTapped()
        XCTAssertEqual(m.phase, .failed)
    }

    func testProceedToPayment_requiresCart() {
        let m = KioskFlowModel.shared
        m.proceedToPayment()
        XCTAssertEqual(m.phase, .browsing)   // 빈 장바구니로는 결제 화면 진입 불가
    }

    func testResumeAtTrigger_resetsOnlyIdleTimer() {
        // 트리거 이탈 후 재진입: 유휴 타이머만 리셋, 진행 상태(장바구니 등)는 유지(스펙 5장)
        let m = KioskFlowModel.shared
        m.addToCart(item)
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        m.resumeAtTrigger()
        XCTAssertEqual(m.idleRemaining, KioskTuning.idleLimit, accuracy: 0.01)
        XCTAssertEqual(m.cart.count, 1)
        XCTAssertEqual(m.phase, .browsing)
    }
}
```

- [ ] **Step 2: 테스트 추가·실패 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier CityTests" "Barrier CityTests/KioskFlowModelTests.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: 컴파일 실패 — `cannot find 'KioskFlowModel' in scope`

- [ ] **Step 3: 구현 작성**

`Barrier City/Kiosk/KioskFlowModel.swift`:
```swift
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
    }
}
```

- [ ] **Step 4: 소스 추가·테스트 통과 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Kiosk/KioskFlowModel.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (주의: `testPaymentFlow…`가 `QuestModel.shared.advance`를 호출하지만 퀘스트 1·2단계가 아닌 상태라 무시됨 — QuestModel의 불일치 무시 동작 덕에 테스트 격리가 유지된다)

- [ ] **Step 5: Commit**

```bash
git add "Barrier City/Kiosk/KioskFlowModel.swift" "Barrier CityTests/KioskFlowModelTests.swift" "Barrier City.xcodeproj"
git commit -m "feat(kiosk): KioskFlowModel 상태 머신 — 유휴 타이머·근접 실패·결제 실패 누적 (TDD)"
```

---

### Task 4: 메뉴 데이터 + KioskScreenView (실물 키오스크 UI)

**Files:**
- Create: `Barrier City/Kiosk/KioskMenu.swift`
- Create: `Barrier City/Kiosk/KioskScreenView.swift`
- Modify: `Barrier City/ImmersiveView.swift` (attachment 교체: `KioskOrderView()` → `KioskScreenView()`)
- Modify: `Barrier City/Interaction/InteractionModel.swift` (`kioskTooHighShown` 제거)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (`kioskTooHighShown` 참조 2곳 제거)
- Modify: `Barrier City/Interaction/SceneSwitcher.swift` (`kioskTooHighShown` 참조 제거)
- Delete: `Barrier City/Interaction/KioskOrderView.swift`

**Interfaces:**
- Consumes: `KioskFlowModel.shared` 전체 API(Task 3), `KioskMenuItem`
- Produces: `KioskMenu.categories: [String]`, `KioskMenu.items(for categoryIndex: Int) -> [KioskMenuItem]`, `struct KioskScreenView: View`
- 시각 규칙: attachment는 1m ≈ 1360pt. 패널 `frame(width: 680, height: 1090)` ≈ 실물 0.5m × 0.8m. 패널 중심을 `KioskTuning.screenCenterY`(1.25m)에 두면 상단 영역이 물리적으로 1.4m+ 높이에 온다(Task 5에서 배치).

- [ ] **Step 1: 메뉴 데이터 작성**

`Barrier City/Kiosk/KioskMenu.swift`:
```swift
//
//  KioskMenu.swift
//  Barrier City
//
//  키오스크 메뉴 정적 데이터. index 0(커피)만 기본 선택 —
//  나머지 카테고리는 상단 탭이라 앉은 사용자는 전환할 수 없다(장벽 ①).
//

enum KioskMenu {
    static let categories = ["커피", "디저트", "시즌 한정", "티·에이드"]

    static let coffee: [KioskMenuItem] = [
        KioskMenuItem(id: "americano",  name: "아메리카노",   price: 4000),
        KioskMenuItem(id: "latte",      name: "카페라떼",     price: 4500),
        KioskMenuItem(id: "vanilla",    name: "바닐라라떼",   price: 5000),
        KioskMenuItem(id: "espresso",   name: "에스프레소",   price: 3500),
        KioskMenuItem(id: "coldbrew",   name: "콜드브루",     price: 4800),
        KioskMenuItem(id: "cappuccino", name: "카푸치노",     price: 4500),
    ]

    /// 현재는 커피만 실제 데이터. 다른 카테고리는 전환 자체가 장벽이라 도달 불가지만,
    /// 실기에서 정말 닿아 전환한 경우를 위해 빈 배열 대신 안내용 최소 데이터를 둔다.
    static func items(for categoryIndex: Int) -> [KioskMenuItem] {
        categoryIndex == 0 ? coffee : [
            KioskMenuItem(id: "soldout", name: "품절", price: 0),
        ]
    }
}
```

- [ ] **Step 2: KioskScreenView 작성**

`Barrier City/Kiosk/KioskScreenView.swift`:
```swift
//
//  KioskScreenView.swift
//  Barrier City
//
//  실물 크기 키오스크 화면(월드 고정 attachment — 배치는 InteractionSetup).
//  세로 1090pt ≈ 0.8m. 상단 영역(카테고리·결제 확인)은 공간상 1.4m+ 높이에 놓여
//  앉은 사용자의 손이 닿지 않는다. 상단 버튼 탭은 KioskFlowModel이
//  리치 판정에 따라 근접 실패로 라우팅한다.
//

import SwiftUI

struct KioskScreenView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 프로퍼티가 관찰 의존성이 된다.
        let m = KioskFlowModel.shared

        VStack(spacing: 0) {
            switch m.phase {
            case .browsing:  browsing(m)
            case .resetting: resetting(m)
            case .payment:   payment(m)
            case .failed:    failed
            }
        }
        .frame(width: 680, height: 1090)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
        .animation(.default, value: m.phase)
    }

    // MARK: 메뉴 탐색(장벽 ①·②)

    @ViewBuilder
    private func browsing(_ m: KioskFlowModel) -> some View {
        // 상단 존: 카테고리 탭(물리적으로 높아 손이 안 닿는다)
        upperZone {
            HStack(spacing: 10) {
                ForEach(Array(KioskMenu.categories.enumerated()), id: \.offset) { i, name in
                    Button { m.categoryTapped(i) } label: {
                        Text(name)
                            .font(.title3).bold()
                            .padding(.vertical, 12).padding(.horizontal, 18)
                            .background(i == m.categoryIndex ? Color.orange : Color.white.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .nearMissFlash(pulse: m.nearMissPulse)
        }

        // 중단: 메뉴 그리드
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(KioskMenu.items(for: m.categoryIndex)) { item in
                Button { m.addToCart(item) } label: {
                    VStack(spacing: 6) {
                        Text(item.name).font(.title3).bold()
                        Text("\(item.price)원").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(item.price == 0)
            }
        }
        .padding(20)

        Spacer(minLength: 0)

        // 하단: 안내 + 장바구니 + 주문하기(하단이라 닿는다)
        VStack(spacing: 10) {
            if m.showsReachHint {
                Label("손이 닿지 않습니다", systemImage: "hand.raised.slash")
                    .font(.callout).foregroundStyle(.orange)
            }
            idleBar(m)
            HStack {
                Text("장바구니 \(m.cart.count)개 · \(m.cartTotal)원")
                    .font(.title3)
                Spacer()
                Button { m.proceedToPayment() } label: {
                    Text("주문하기").font(.title2).bold()
                        .padding(.vertical, 12).padding(.horizontal, 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.cart.isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: 시간 초과 리셋(장벽 ②)

    @ViewBuilder
    private func resetting(_ m: KioskFlowModel) -> some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56)).foregroundStyle(.orange)
            Text("이용자가 없어\n처음 화면으로 돌아갑니다")
                .font(.largeTitle).bold().multilineTextAlignment(.center)
            Text("담아둔 메뉴가 사라졌습니다")
                .font(.title3).foregroundStyle(.secondary)
        }
        Spacer()
    }

    // MARK: 결제(장벽 ③)

    @ViewBuilder
    private func payment(_ m: KioskFlowModel) -> some View {
        // 상단 존: 카드 투입구 + 결제 확인(최상단 — 도달해도 카드 삽입 불가 설정)
        upperZone {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.3))
                    .frame(width: 220, height: 14)
                    .overlay(Text("CARD").font(.caption2).foregroundStyle(.black.opacity(0.6)))
                Button { m.paymentConfirmTapped() } label: {
                    Text("결제 확인").font(.title2).bold()
                        .padding(.vertical, 14).padding(.horizontal, 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .nearMissFlash(pulse: m.nearMissPulse)
        }

        Spacer()
        VStack(spacing: 14) {
            Text("결제 금액").font(.title3).foregroundStyle(.secondary)
            Text("\(m.cartTotal)원").font(.system(size: 54, weight: .bold))
            if m.paymentAttempts > 0 {
                Text("결제가 진행되지 않았습니다 (\(m.paymentAttempts)/\(KioskTuning.paymentMaxAttempts))")
                    .font(.callout).foregroundStyle(.orange)
            }
            if m.showsReachHint {
                Label("손이 닿지 않습니다", systemImage: "hand.raised.slash")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        Spacer()
        idleBar(m).padding(20)
    }

    // MARK: 최종 실패

    @ViewBuilder
    private var failed: some View {
        Spacer()
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.red)
            Text("결제가 완료되지 않았습니다")
                .font(.largeTitle).bold().multilineTextAlignment(.center)
            Text("직원에게 문의해 주세요")
                .font(.title2).foregroundStyle(.secondary)
        }
        Spacer()
    }

    // MARK: 공통 조각

    /// 상단 존 컨테이너: 높이를 고정해 화면 위쪽(공간상 1.4m+)에 온다.
    @ViewBuilder
    private func upperZone<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(.white.opacity(0.06))
    }

    /// 유휴 타이머 바: 남은 시간을 시각화(줄어드는 압박).
    @ViewBuilder
    private func idleBar(_ m: KioskFlowModel) -> some View {
        GeometryReader { geo in
            let ratio = max(0, min(1, m.idleRemaining / KioskTuning.idleLimit))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(ratio < 0.3 ? Color.red : Color.white.opacity(0.4))
                    .frame(width: geo.size.width * CGFloat(ratio))
            }
        }
        .frame(height: 6)
    }
}

/// 근접 실패 펄스: nearMissPulse가 증가할 때마다 잠깐 주황 테두리를 깜빡인다
/// ("닿을 듯 말 듯" 피드백).
private struct NearMissFlash: ViewModifier {
    let pulse: Int
    @State private var flashing = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.orange, lineWidth: flashing ? 4 : 0))
            .onChange(of: pulse) {
                flashing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    flashing = false
                }
            }
            .animation(.easeOut(duration: 0.3), value: flashing)
    }
}

private extension View {
    func nearMissFlash(pulse: Int) -> some View { modifier(NearMissFlash(pulse: pulse)) }
}

#Preview(windowStyle: .automatic) {
    KioskScreenView()
}
```

- [ ] **Step 3: ImmersiveView attachment 교체 + 구 파일 삭제**

`Barrier City/ImmersiveView.swift`의 attachment 블록에서:
```swift
            // [김현기] 키오스크 주문 화면(고정 높이 장벽은 InteractionSetup이 처리)
            Attachment(id: "kioskScreen") {
                KioskOrderView()
            }
```
를 다음으로 교체:
```swift
            // [김현기] 키오스크 화면(실물 크기·월드 고정 — 배치는 InteractionSetup)
            Attachment(id: "kioskScreen") {
                KioskScreenView()
            }
```

구 파일 삭제(참조 정리 포함):
```bash
git rm "Barrier City/Interaction/KioskOrderView.swift"
ruby - <<'RB'
require 'xcodeproj'
proj = Xcodeproj::Project.open('Barrier City.xcodeproj')
proj.files.select { |f| f.path.to_s.include?('KioskOrderView') }.each(&:remove_from_project)
proj.save
RB
```

- [ ] **Step 4: kioskTooHighShown 제거(유일한 소비자였던 KioskOrderView와 함께)**

`KioskOrderView`가 유일하게 읽던 프로퍼티이므로 같은 커밋에서 정리한다(쓰기만 하고 아무도 읽지 않는 상태를 남기지 않는다).

`Barrier City/Interaction/InteractionModel.swift`에서 다음 프로퍼티를 삭제:
```swift
    /// 키오스크 "사용하기"를 눌러 '너무 높아 사용 불가' 안내가 뜬 상태.
    /// 트리거 이탈/재진입 시 리셋.
    var kioskTooHighShown = false
```

`Barrier City/Interaction/SceneSwitcher.swift`에서 `im.kioskTooHighShown = false` 줄 삭제.

`Barrier City/Interaction/InteractionSetup.swift`에서 `im.kioskTooHighShown = false` 두 곳 삭제:
- `install`의 0단계 리셋 목록에 있는 줄
- `tick`의 트리거 변경 처리 블록 안에 있는 줄(주석 `// 트리거가 바뀌면(이탈 포함) 키오스크 안내 리셋` 포함)

- [ ] **Step 5: 소스 추가·전체 빌드/테스트 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Kiosk/KioskMenu.swift" "Barrier City/Kiosk/KioskScreenView.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add -A "Barrier City" "Barrier City.xcodeproj"
git commit -m "feat(kiosk): 실물 키오스크 화면 — 4단계 UI(탐색·리셋·결제·실패) + KioskOrderView 대체"
```

---

### Task 5: 배선 — 손 월드 좌표 + 리치 틱 + 패널 월드 고정

**Files:**
- Modify: `Barrier City/AppModel.swift` (프로퍼티 2개 추가)
- Modify: `Barrier City/HandTrackingManager.swift` (좌표 기록)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (틱 확장·월드 고정 배치·리셋 목록)

**Interfaces:**
- Consumes: `KioskFlowModel.shared`, `KioskFlowLogic.canReach`, `KioskTuning`
- Produces: `AppModel.handWorldLeft/handWorldRight: SIMD3<Float>?` (nil = 추적 없음·시뮬레이터). InteractionSetup 틱이 매 프레임 `KioskFlowModel`의 `isActive`·`reachableUpper`를 갱신하고 `tick(dt:transitioning:)`을 호출한다.

- [ ] **Step 1: AppModel에 손 월드 좌표 추가**

`Barrier City/AppModel.swift`의 `// MARK: - 손 추적 진단` 섹션 바로 위에 추가:
```swift
    // MARK: - 손 월드 좌표(키오스크 리치 판정용)
    /// 마지막으로 추적된 손(손바닥 기준점)의 월드 좌표. 추적 안 되면 nil(시뮬레이터 포함).
    var handWorldLeft: SIMD3<Float>?
    var handWorldRight: SIMD3<Float>?
```

- [ ] **Step 2: HandTrackingManager가 좌표를 기록하게**

`Barrier City/HandTrackingManager.swift`의 `process(_:model:)` 안, `let gripPos = gripWorldPosition(anchor)` 바로 아래에 추가:
```swift
        // 리치 판정용 월드 좌표 기록(추적이 끊기면 nil로 지워 오판 방지).
        switch chirality {
        case .left:  model.handWorldLeft  = anchor.isTracked ? gripPos : nil
        case .right: model.handWorldRight = anchor.isTracked ? gripPos : nil
        }
```

- [ ] **Step 3: InteractionSetup 재작성(설치 리셋·dt 전달·리치 틱·월드 고정 배치)**

전제: Task 4에서 `kioskTooHighShown`이 이미 제거되어 있다.

`Barrier City/Interaction/InteractionSetup.swift`에 다음 변경을 적용:

(a) `install`의 0단계 리셋 목록(`im.transitionError = nil` 다음)에 추가:
```swift
        KioskFlowModel.shared.reset()
        kioskPlacedForTriggerID = nil
```

(b) `install`의 구독 등록을 dt 전달형으로 교체:
```swift
        im.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            tick(dt: Float(event.deltaTime))
        }
```

(c) `tick`을 다음으로 교체(근접 판정은 기존 그대로, 키오스크 갱신 추가):
```swift
    /// 매 프레임: 판정 → activeTrigger 갱신 → 패널 표시·배치 → 키오스크 리치·타이머.
    private static func tick(dt: Float) {
        guard let app = AppModel.current else { return }
        let im = InteractionModel.shared
        guard !im.isTransitioning else { return }

        let verdict = InteractionModel.evaluate(
            playerX: app.posX, playerZ: app.posZ,
            triggers: im.triggers,
            activeID: im.activeTrigger?.id,
            dismissedID: im.dismissedTriggerID)

        if verdict.clearDismissed { im.dismissedTriggerID = nil }
        if im.activeTrigger?.id != verdict.showID {
            im.activeTrigger = verdict.showID.flatMap { id in im.triggers.first { $0.id == id } }
            if im.activeTrigger == nil { im.transitionError = nil }   // 닫힐 때 안내 문구도 정리
        }
        updatePanel(im)

        // [키오스크] 활성 여부·리치 판정 갱신 후 상태 머신 진행.
        let kfm = KioskFlowModel.shared
        let kioskNowActive = (im.activeTrigger?.kind == .kioskScreen)
        if kioskNowActive && !kfm.isActive { kfm.resumeAtTrigger() }   // 재진입: 유휴 타이머만 리셋
        kfm.isActive = kioskNowActive
        if kfm.isActive, let panel = im.kioskPanelEntity {
            let world = panel.position(relativeTo: nil)
            let kioskXZ = SIMD2(world.x, world.z)
            func reaches(_ hand: SIMD3<Float>?) -> Bool {
                KioskFlowLogic.canReach(hand: hand, kioskXZ: kioskXZ,
                                        zoneMinY: KioskTuning.upperZoneMinY,
                                        margin: KioskTuning.reachMargin,
                                        maxXZ: KioskTuning.reachMaxXZ)
            }
            kfm.reachableUpper = reaches(app.handWorldLeft) || reaches(app.handWorldRight)
        } else {
            kfm.reachableUpper = false
        }
        kfm.tick(dt: dt, transitioning: im.isTransitioning)
    }
```

(d) `updatePanel`을 다음으로 교체(문은 빌보드 유지, 키오스크는 활성화 시 1회 월드 고정):
```swift
    /// 키오스크 화면을 월드에 고정한 트리거 id(활성화 시 1회 배치용).
    private static var kioskPlacedForTriggerID: String?

    /// 활성 트리거의 kind에 맞는 패널만 표시.
    /// 문 패널: 기존 눈높이 빌보드. 키오스크: 활성화 순간 1회 월드 고정(실물 화면처럼
    /// 접근 각도와 무관하게 공간에 붙박이 — 이후 프레임에는 위치를 건드리지 않는다).
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger
        showBillboard(im.panelEntity, active: trigger?.kind == .yesNoPrompt,
                      trigger: trigger, forwardOffset: 0)

        let kioskActive = trigger?.kind == .kioskScreen
        if let kiosk = im.kioskPanelEntity {
            kiosk.isEnabled = kioskActive
            if kioskActive, let t = trigger, kioskPlacedForTriggerID != t.id {
                placeKioskFixed(kiosk, trigger: t)
                kioskPlacedForTriggerID = t.id
            }
            if !kioskActive { kioskPlacedForTriggerID = nil }
        }
    }

    /// 키오스크 화면을 트리거 중심 위 화면 높이에 놓고, 사용자(세계 원점) 쪽으로
    /// forwardOffset만큼 당긴 뒤 사용자를 향해 1회 회전(이후 고정).
    private static func placeKioskFixed(_ panel: Entity, trigger t: ProximityTrigger) {
        panel.setPosition([t.center.x, KioskTuning.screenCenterY, t.center.y],
                          relativeTo: panel.parent)
        var worldPos = panel.position(relativeTo: nil)
        let horiz = SIMD2(worldPos.x, worldPos.z)
        let dist = simd_length(horiz)
        if dist > 0.001 {
            let pulled = horiz - (horiz / dist) * InteractionTuning.kioskPanelForwardOffset
            worldPos.x = pulled.x
            worldPos.z = pulled.y
            panel.setPosition(worldPos, relativeTo: nil)
        }
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
    }
```

- [ ] **Step 4: 빌드·전체 테스트 확인**

Run: `xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: 시뮬레이터 수동 확인(핵심 흐름)**

시뮬레이터에서 앱 실행 → 몰입 진입 → 문으로 이동해 "예" → 실내에서 키오스크 접근:
- 키오스크 화면이 공간에 고정되어 뜨는가(빌보드처럼 돌지 않는가)
- 상단 카테고리 탭 → 주황 테두리 깜빡(근접 실패) + 3회 후 "손이 닿지 않습니다"
- 방치 → 타이머 바 감소 → "처음 화면으로 돌아갑니다" → 복귀
- 메뉴 담기 → "주문하기" → 결제 화면 → "결제 확인" 3회 → 최종 실패 + 퀘스트 3단계 전환
확인 후 이상 있으면 수정하고 다시 확인.

- [ ] **Step 6: Commit**

```bash
git add "Barrier City"
git commit -m "feat(kiosk): 리치 판정 틱·화면 월드 고정 배선"
```

---

### Task 6: StandUpGuard(일어서기 가드) + 오버레이

**Files:**
- Create: `Barrier City/Kiosk/StandUpGuard.swift`
- Create: `Barrier City/Kiosk/StandUpOverlayView.swift`
- Modify: `Barrier City/ImmersiveView.swift` (attachment 추가)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (설치·틱 연결)

**Interfaces:**
- Consumes: `KioskFlowLogic.standUpShown`, `KioskTuning.standUpEnter/standUpExit`, `KioskFlowModel.shared.standUpShown`
- Produces: `final class StandUpGuard` — `func start() async`, `func tick()`, `func stop()`. attachment id `"standUpOverlay"`.

- [ ] **Step 1: StandUpGuard 작성**

`Barrier City/Kiosk/StandUpGuard.swift`:
```swift
//
//  StandUpGuard.swift
//  Barrier City
//
//  체험 중 사용자가 일어서면 "휠체어 사용자는 일어설 수 없습니다" 오버레이를 띄운다.
//  QuestHUDFollower처럼 자체 ARKitSession + WorldTrackingProvider로 head 높이를 조회
//  (한 앱에 세션 여러 개 허용). head 포즈를 못 얻으면 가드 비활성(fail-open).
//

import ARKit
import RealityKit
import QuartzCore
import simd

@MainActor
final class StandUpGuard {
    private let session = ARKitSession()
    private let provider = WorldTrackingProvider()
    private var running = false
    private var baselineY: Float?
    /// 오버레이 attachment 엔티티(씬 루트 자식). tick이 head 앞에 배치한다.
    var overlayEntity: Entity?

    func start() async {
        guard WorldTrackingProvider.isSupported else {
            print("WorldTracking 미지원 — 일어서기 가드 비활성")
            return
        }
        do {
            try await session.run([provider])
            running = true
        } catch {
            print("WorldTracking 시작 실패: \(error) — 일어서기 가드 비활성")
        }
    }

    /// 매 프레임(InteractionSetup.tick에서 호출). 기준 높이 캡처 → 판정 → 오버레이 배치.
    func tick() {
        guard running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return }
        let m = anchor.originFromAnchorTransform
        let headY = m.columns.3.y
        if baselineY == nil { baselineY = headY }
        guard let base = baselineY else { return }

        let kfm = KioskFlowModel.shared
        kfm.standUpShown = KioskFlowLogic.standUpShown(
            currentlyShown: kfm.standUpShown, headY: headY, baselineY: base,
            enter: KioskTuning.standUpEnter, exit: KioskTuning.standUpExit)

        guard let overlay = overlayEntity else { return }
        overlay.isEnabled = kfm.standUpShown
        if kfm.standUpShown {
            // head 정면 1m, 눈높이에 배치 + head를 향해 yaw 빌보드.
            let head = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let forward = -SIMD3(m.columns.2.x, 0, m.columns.2.z)
            let f = simd_length(forward) > 1e-5 ? simd_normalize(forward) : SIMD3(0, 0, -1)
            let pos = head + f * 1.0
            overlay.setPosition(pos, relativeTo: nil)
            let dir = head - pos
            overlay.setOrientation(simd_quatf(angle: atan2(dir.x, dir.z), axis: [0, 1, 0]),
                                   relativeTo: nil)
        }
    }

    func stop() {
        running = false
        baselineY = nil
        session.stop()
    }
}
```

- [ ] **Step 2: 오버레이 뷰 작성**

`Barrier City/Kiosk/StandUpOverlayView.swift`:
```swift
//
//  StandUpOverlayView.swift
//  Barrier City
//
//  일어서기 감지 시 시야 정면에 뜨는 안내 패널.
//  "그냥 일어서면 되잖아"라는 탈출구를 차단하는 제약 전달 장치.
//

import SwiftUI

struct StandUpOverlayView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.roll")
                .font(.system(size: 52))
            Text("휠체어 사용자는\n일어설 수 없습니다")
                .font(.largeTitle).bold()
                .multilineTextAlignment(.center)
            Text("앉은 채로 체험해 주세요")
                .font(.title3).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 620)
        .glassBackgroundEffect()
    }
}

#Preview(windowStyle: .automatic) {
    StandUpOverlayView()
}
```

- [ ] **Step 3: ImmersiveView attachment 추가 + InteractionSetup 연결**

`Barrier City/ImmersiveView.swift` attachments 블록 끝(questHUD 아래)에 추가:
```swift
            // [김현기] 일어서기 가드 오버레이(배치는 StandUpGuard가 처리)
            Attachment(id: "standUpOverlay") {
                StandUpOverlayView()
            }
```

`Barrier City/Interaction/InteractionSetup.swift`:

(a) enum 상단에 보관 프로퍼티 추가:
```swift
    /// 일어서기 가드(설치 시 시작, 씬 루트의 오버레이를 관리).
    private static var standUpGuard: StandUpGuard?
```

(b) `install` 1단계(attachment 배치) 뒤에 추가 — 오버레이는 맵과 분리(씬 루트):
```swift
        // 1.5) 일어서기 가드: 오버레이는 씬 루트에(맵과 함께 움직이면 안 된다).
        let guardInstance = StandUpGuard()
        if let overlay = attachments.entity(for: "standUpOverlay") {
            overlay.isEnabled = false
            content.add(overlay)
            guardInstance.overlayEntity = overlay
        } else {
            print("⚠️ standUpOverlay attachment 없음 — 일어서기 안내 비활성")
        }
        standUpGuard = guardInstance
        Task { await guardInstance.start() }
```

(c) `tick(dt:)` 끝(`kfm.tick(...)` 다음 줄)에 추가:
```swift
        standUpGuard?.tick()
```

- [ ] **Step 4: 빌드·테스트·시뮬레이터 확인**

Run: `xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

시뮬레이터 확인: 몰입 진입 후 카메라를 위로 이동(⌥+드래그로 시점 상승)했을 때 오버레이가 뜨고, 내리면 사라지는지. (시뮬레이터에서 head 높이 조작이 안 되면 실기 체크리스트 항목으로 남긴다 — fail-open이라 체험은 정상.)

- [ ] **Step 5: Commit**

```bash
git add "Barrier City" "Barrier City.xcodeproj"
git commit -m "feat(kiosk): 일어서기 가드 — head 높이 감지 + 안내 오버레이 (fail-open)"
```

(파일 추가 잊지 말 것: `ruby scripts/add_files.rb "Barrier City" "Barrier City/Kiosk/StandUpGuard.swift" "Barrier City/Kiosk/StandUpOverlayView.swift"` 를 Step 4 전에 실행.)

---

### Task 7: PressureAudio(사회적 압박 오디오)

**Files:**
- Create: `Barrier City/Kiosk/PressureAudio.swift`
- Modify: `Barrier City/Kiosk/KioskFlowModel.swift` (오디오 훅 4곳)
- Modify: `Barrier CityTests/KioskFlowModelTests.swift` (setUp에서 오디오 비활성화)

**Interfaces:**
- Consumes: `VoiceOutput(config: AppConfig.proxy)` — `await voice.speak(sentences: [String]) { line in }` (DialogueKitOpenAI, NPCDialogueController와 동일 사용법), `ImpactAudio`의 합성 패턴
- Produces: `PressureAudio.shared` — `func onFirstReset()`, `func onPaymentStruggle()`, `func tick(dt: Float)`, `func reset()`; `static var isEnabled` (테스트에서 false로 꺼서 오디오·네트워크 부수 효과 차단)
- 사운드 구성(스펙 대비): 발소리=코드 합성(에셋 불필요), 한숨·대사=프록시 TTS(네트워크 실패 시 조용히 생략 — fail-open). 헛기침은 생략(선택 확장).

- [ ] **Step 1: PressureAudio 작성**

`Barrier City/Kiosk/PressureAudio.swift`:
```swift
//
//  PressureAudio.swift
//  Barrier City
//
//  키오스크 뒤 대기줄의 사회적 압박 사운드.
//  - 발소리: ImpactAudio 패턴의 합성음(에셋 불필요, 오프라인 동작)
//  - 한숨·재촉 대사: 프록시 TTS(VoiceOutput). 실패하면 조용히 생략(fail-open).
//  강도 단계: 0=무음 → 1(첫 리셋: 발소리+한숨) → 2(결제 실패: 재촉 대사).
//

import AVFoundation
import DialogueKitOpenAI

@MainActor
final class PressureAudio {

    static let shared = PressureAudio()

    /// false면 모든 재생 요청을 무시한다. 단위 테스트가 오디오 엔진·TTS 네트워크
    /// 호출을 일으키지 않도록 끄는 용도(KioskFlowModelTests.setUp).
    static var isEnabled = true

    private let engine = AVAudioEngine()
    private let stepPlayer = AVAudioPlayerNode()
    private var stepBuffer: AVAudioPCMBuffer?
    private var started = false
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private let voice = VoiceOutput(config: AppConfig.proxy)

    private(set) var level = 0
    private var sighSpoken = false
    private var lineSpoken = false
    private var stepCooldown: Float = 0

    private init() {}

    /// 첫 시간 초과 리셋: 압박 시작(발소리 + 한숨 1회).
    func onFirstReset() {
        guard Self.isEnabled, level < 1 else { return }
        level = 1
        prepare()
        if !sighSpoken {
            sighSpoken = true
            Task { await voice.speak(sentences: ["하아…"]) { _ in } }   // 실패 시 무음(fail-open)
        }
    }

    /// 결제 실패 시작: 재촉 대사 1회.
    func onPaymentStruggle() {
        guard Self.isEnabled else { return }
        level = max(level, 2)
        prepare()
        if !lineSpoken {
            lineSpoken = true
            Task { await voice.speak(sentences: ["저기… 얼마나 걸릴까요?"]) { _ in } }
        }
    }

    /// 매 프레임(KioskFlowModel.tick에서 호출). 발소리를 불규칙 간격으로 재생.
    func tick(dt: Float) {
        guard Self.isEnabled, level >= 1, started else { return }
        stepCooldown -= dt
        if stepCooldown <= 0 {
            stepCooldown = Float.random(in: 1.0...2.2) / Float(level)   // 단계↑ → 잦아짐
            playStep()
        }
    }

    func reset() {
        level = 0
        sighSpoken = false
        lineSpoken = false
        stepCooldown = 0
    }

    // MARK: - 내부(ImpactAudio 패턴)

    private func prepare() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        stepBuffer = makeStep()
        engine.attach(stepPlayer)
        engine.connect(stepPlayer, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            stepPlayer.play()
            started = true
        } catch {
            print("PressureAudio 시작 실패: \(error)")
        }
    }

    private func playStep() {
        guard let stepBuffer else { return }
        stepPlayer.volume = 0.35
        stepPlayer.scheduleBuffer(stepBuffer, at: nil, options: .interrupts, completionHandler: nil)
        if !stepPlayer.isPlaying { stepPlayer.play() }
    }

    /// 뒤에서 서성이는 발소리 한 발(낮은 톤 + 잡음, 빠른 감쇠).
    private func makeStep() -> AVAudioPCMBuffer {
        let sr = Float(sampleRate)
        let duration: Float = 0.12
        let count = AVAudioFrameCount(sr * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        var generator = SystemRandomNumberGenerator()
        for i in 0..<Int(count) {
            let t = Float(i) / sr
            let env = expf(-t * 45)
            let attack = min(1, t / 0.003)
            let tone = sinf(2 * .pi * 55 * t)
            let noise = Float.random(in: -1...1, using: &generator)
            samples[i] = (0.6 * tone + 0.4 * noise) * env * attack * 0.8
        }
        return buffer
    }
}
```

- [ ] **Step 2: KioskFlowModel에 훅 연결**

`Barrier City/Kiosk/KioskFlowModel.swift` 수정 3곳:

(a) `tick`의 유휴 시간 초과 분기(`resetHoldRemaining = …` 다음 줄)에 추가:
```swift
                if resetCount == 1 { PressureAudio.shared.onFirstReset() }
```

(b) `tick` 함수 마지막(guard 통과한 본문 끝, switch 다음)에 추가:
```swift
        PressureAudio.shared.tick(dt: dt)
```

(c) `paymentConfirmTapped`의 `paymentAttempts = r.attempts` 다음 줄에 추가:
```swift
        if paymentAttempts == 1 { PressureAudio.shared.onPaymentStruggle() }
```

(d) `reset()` 마지막에 추가:
```swift
        PressureAudio.shared.reset()
```

- [ ] **Step 3: 테스트에서 오디오 비활성화**

KioskFlowModel의 타이머·결제 경로가 이제 PressureAudio를 호출하므로, 단위 테스트가
오디오 엔진을 켜고 TTS 네트워크 호출을 일으키지 않도록 끈다.

`Barrier CityTests/KioskFlowModelTests.swift`의 `setUp`에 한 줄 추가:
```swift
    override func setUp() async throws {
        PressureAudio.isEnabled = false   // 오디오·네트워크 부수 효과 차단
        KioskFlowModel.shared.reset()
        KioskFlowModel.shared.isActive = true
    }
```

- [ ] **Step 4: 소스 추가·테스트 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Kiosk/PressureAudio.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: 시뮬레이터 확인**

키오스크에서 방치 → 첫 리셋 후 발소리가 반복되는지, 결제 실패 후 대사가 나오는지(네트워크 연결 시). 소리 크기·간격이 거슬리면 `playStep`의 volume·`tick`의 간격 범위 조정.

- [ ] **Step 6: Commit**

```bash
git add "Barrier City" "Barrier City.xcodeproj"
git commit -m "feat(kiosk): 사회적 압박 오디오 — 합성 발소리 + TTS 한숨·재촉 대사 (fail-open)"
```

---

### Task 8: NPC 배치 + 대화 트리거

**Files:**
- Create: `Barrier City/Dialogue/NPCSetup.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift` (`TriggerKind.npcDialogue`, `npcPanelEntity` 추가)
- Modify: `Barrier City/Interaction/SceneSwitcher.swift` (NPC 배치·트리거 등록)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (npc 패널 attachment 등록·표시)
- Modify: `Barrier City/ImmersiveView.swift` (attachment 추가 — 뷰 본체는 Task 9, 여기서는 자리표시 텍스트)

**Interfaces:**
- Consumes: `KioskTuning.npcTriggerRadius/npcFallbackCenter/npcScale/npcYaw`, `realityKitContentBundle`의 `"Skull"` 엔티티
- Produces: `NPCSetup.placeStaff(in:worldRoot:) async -> SIMD2<Float>` (배치 후 맵 좌표 반환), `NPCSetup.playAnimation(named:)` (Greeting/Happy — 없으면 무시), `TriggerKind.npcDialogue`, `InteractionModel.npcPanelEntity`, attachment id `"npcOrder"`

- [ ] **Step 1: TriggerKind·패널 참조 추가**

`Barrier City/Interaction/InteractionModel.swift`의 `TriggerKind`에 케이스 추가:
```swift
    /// NPC 직원 대화 패널
    case npcDialogue
```
`kioskPanelEntity` 선언 아래에 추가:
```swift
    /// NPC 주문 대화 패널 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var npcPanelEntity: Entity?
```

- [ ] **Step 2: NPCSetup 작성**

`Barrier City/Dialogue/NPCSetup.swift`:
```swift
//
//  NPCSetup.swift
//  Barrier City
//
//  실내 카운터에 NPC 직원(Skull 모델)을 배치하고 애니메이션을 재생한다.
//  모델·프림·클립이 없어도 트리거와 대화는 동작한다(fail-open).
//

import RealityKit
import RealityKitContent
import simd

@MainActor
enum NPCSetup {

    private(set) static var staffEntity: Entity?

    /// Indoor 전환 시 호출. 카운터(Bar) 프림 위치(폴백: 상수)에 Skull을 놓고
    /// 배치한 맵 좌표(트리거 중심용)를 반환한다.
    static func placeStaff(in map: Entity, worldRoot: Entity) async -> SIMD2<Float> {
        var center = KioskTuning.npcFallbackCenter
        if let bar = map.findEntity(named: "Bar") {
            let b = bar.visualBounds(relativeTo: worldRoot)
            center = SIMD2(b.center.x, b.center.z)
            print("NPC 배치: Bar 프림 위치 사용 (\(b.center.x), \(b.center.z))")
        } else {
            print("⚠️ Bar 프림을 찾지 못해 NPC 폴백 좌표 사용: \(center)")
        }

        guard let staff = try? await Entity(named: "Skull", in: realityKitContentBundle) else {
            print("⚠️ Skull(NPC) 로드 실패 — 트리거만 등록")
            return center
        }
        staff.name = "npcStaff"
        staff.scale = SIMD3(repeating: KioskTuning.npcScale)
        staff.orientation = simd_quatf(angle: KioskTuning.npcYaw, axis: [0, 1, 0])
        staff.position = [center.x, 0, center.y]
        map.addChild(staff)   // 맵과 함께 움직인다(visibleMap은 worldRoot에 identity로 붙음)
        staffEntity = staff
        playAnimation(named: "Greeting")
        return center
    }

    /// 이름이 포함된 애니메이션 클립을 1회 재생. 없으면 첫 클립, 그것도 없으면 무시.
    static func playAnimation(named name: String) {
        guard let staff = staffEntity else { return }
        let anims = staff.availableAnimations
        let anim = anims.first { $0.name?.localizedCaseInsensitiveContains(name) == true }
            ?? anims.first
        guard let anim else { return }
        staff.playAnimation(anim, transitionDuration: 0.3)
    }

    /// 재진입 대비 정리(씬 전환·install 리셋에서 호출).
    static func reset() {
        staffEntity?.removeFromParent()
        staffEntity = nil
    }
}
```

- [ ] **Step 3: SceneSwitcher에 배치·트리거 등록**

`Barrier City/Interaction/SceneSwitcher.swift`의 `im.triggers = [ProximityTrigger(… id: "kiosk.order" …)]` 블록을 다음으로 교체:
```swift
        im.scene = .indoor
        var indoorTriggers = [ProximityTrigger(
            id: "kiosk.order",
            center: kioskCenter,
            radius: InteractionTuning.kioskTriggerRadius,
            kind: .kioskScreen,
            prompt: InteractionTuning.kioskTitle)]

        // [김현기] NPC 직원 배치 + 대화 트리거(항상 활성 — 퀘스트는 3단계에서만 반응).
        NPCSetup.reset()
        let npcCenter = await NPCSetup.placeStaff(in: indoorVisible, worldRoot: worldRoot)
        indoorTriggers.append(ProximityTrigger(
            id: "npc.staff",
            center: npcCenter,
            radius: KioskTuning.npcTriggerRadius,
            kind: .npcDialogue,
            prompt: "직원에게 주문하기"))
        im.triggers = indoorTriggers
```

- [ ] **Step 4: InteractionSetup에 npc 패널 연결**

`Barrier City/Interaction/InteractionSetup.swift`:

(a) `install` 1단계의 kiosk attachment 블록 아래에 추가:
```swift
            if let npc = attachments.entity(for: "npcOrder") {
                npc.isEnabled = false
                worldRoot.addChild(npc)
                im.npcPanelEntity = npc
            } else {
                print("⚠️ npcOrder attachment 없음 — NPC 대화 패널 비활성")
            }
```

(b) `install` 0단계 리셋 목록에 추가:
```swift
        NPCSetup.reset()
```

(c) `updatePanel`의 문 패널 처리 아래에 추가(NPC 패널은 문과 같은 빌보드 —
대화 UI는 항상 사용자를 향하는 게 자연스럽다):
```swift
        showBillboard(im.npcPanelEntity, active: trigger?.kind == .npcDialogue,
                      trigger: trigger, forwardOffset: 0.5)
```

- [ ] **Step 5: 자리표시 attachment 추가(뷰 본체는 Task 9)**

`Barrier City/ImmersiveView.swift` attachments 블록에 추가:
```swift
            // [김현기] NPC 주문 대화 패널(빌보드는 InteractionSetup이 처리)
            Attachment(id: "npcOrder") {
                Text("직원")   // Task 9에서 NPCOrderView로 교체
                    .padding(40)
                    .glassBackgroundEffect()
            }
```

- [ ] **Step 6: 소스 추가·테스트·시뮬레이터 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Dialogue/NPCSetup.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

시뮬레이터: 실내 전환 후 카운터 부근에 Skull 모델이 보이고(스케일·방향 이상하면 `KioskTuning.npcScale/npcYaw` 조정), 접근 시 자리표시 패널이 뜨는지. Skull이 비정상 위치면 콘솔의 "NPC 배치:" 좌표를 보고 `npcFallbackCenter` 조정.

- [ ] **Step 7: Commit**

```bash
git add "Barrier City" "Barrier City.xcodeproj"
git commit -m "feat(npc): 카운터 NPC 배치 + 대화 근접 트리거 (.npcDialogue)"
```

---

### Task 9: NPCOrderModel + NPCOrderView (음성 주문 + 폴백)

**Files:**
- Create: `Barrier City/Dialogue/NPCOrderModel.swift`
- Create: `Barrier City/Dialogue/NPCOrderView.swift`
- Modify: `Barrier City/ImmersiveView.swift` (자리표시 → `NPCOrderView()`)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (리셋 목록에 추가)
- Verify: `Barrier City/Info.plist` (마이크·음성인식 권한 키)

**Interfaces:**
- Consumes: `NPCDialogueController`(무수정 — `status/userText/npcSubtitle/lastEvent/liveText`, `beginListening()/endTurn()`), `VoiceOutput`, `QuestModel.shared.advance(on: .npcHelpDone)`, `NPCSetup.playAnimation(named:)`
- Produces: `NPCOrderModel.shared` — `var fallbackMode: Bool`, `var completed: Bool`, `let choices: [NPCOrderModel.Choice]`, `func beginListening() async`, `func endTurn() async`, `func selectFallback(_:)`, `func reset()`

- [ ] **Step 1: 권한 키 확인**

Run: `grep -E "Microphone|SpeechRecognition" "Barrier City/Info.plist" || echo "없음"`
`NSMicrophoneUsageDescription`·`NSSpeechRecognitionUsageDescription`이 없으면 `Barrier City/Info.plist`의 최상위 `<dict>`에 추가:
```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>직원에게 음성으로 주문하기 위해 마이크를 사용합니다.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>말한 내용을 주문으로 인식하기 위해 사용합니다.</string>
```
(이미 있으면 건너뜀 — DevHarness STT가 동작했다면 있을 가능성이 높다.)

- [ ] **Step 2: NPCOrderModel 작성**

`Barrier City/Dialogue/NPCOrderModel.swift`:
```swift
//
//  NPCOrderModel.swift
//  Barrier City
//
//  몰입 씬 NPC 주문의 상태 단일 진실원. NPCDialogueController(STT→AI→TTS)를 감싸고
//  ① orderPlaced/helpRequested 이벤트 → 퀘스트 3단계 완료
//  ② STT·네트워크 실패 → 선택지 폴백(오프라인에서도 완주 가능)
//  을 담당한다.
//

import Observation
import DialogueKitOpenAI

@Observable
@MainActor
final class NPCOrderModel {

    static let shared = NPCOrderModel()

    let controller = NPCDialogueController()
    private let voice = VoiceOutput(config: AppConfig.proxy)

    /// 음성 대신 선택지 버튼으로 진행 중인가(STT 실패 시 자동, 수동 전환도 가능).
    var fallbackMode = false
    /// 주문 완료(퀘스트 발행됨). 완료 후 패널은 안내만 표시.
    private(set) var completed = false

    struct Choice: Identifiable {
        var id: String { label }
        let label: String
        let reply: String
    }

    /// 폴백 선택지 — 고정 응답이 매핑되어 LLM 없이도 주문이 끝난다.
    let choices: [Choice] = [
        Choice(label: "아메리카노 한 잔 주세요",
               reply: "네, 아메리카노 한 잔 준비해드릴게요."),
        Choice(label: "키오스크가 너무 높아서요… 주문을 도와주시겠어요?",
               reply: "그럼요, 제가 도와드릴게요. 어떤 메뉴로 하시겠어요?"),
        Choice(label: "따뜻한 카페라떼 하나 부탁드려요",
               reply: "따뜻한 카페라떼 한 잔, 바로 준비해드릴게요."),
    ]

    /// push-to-talk 시작. STT 시작에 실패하면 폴백 모드로 전환.
    func beginListening() async {
        await controller.beginListening()
        if controller.status != .listening { fallbackMode = true }
    }

    /// push-to-talk 종료 → AI 응답 → 완료 이벤트 확인.
    func endTurn() async {
        await controller.endTurn()
        // orderPlaced(주문 확정)·helpRequested(도움 요청) 모두 3단계 완료로 인정.
        if controller.lastEvent.contains("orderPlaced")
            || controller.lastEvent.contains("helpRequested") {
            complete()
        }
    }

    /// 폴백 선택지 주문: 고정 응답을 자막+TTS로 내보내고 완료 처리.
    func selectFallback(_ choice: Choice) {
        guard !completed else { return }
        controller.userText = choice.label
        controller.npcSubtitle = choice.reply
        Task { await voice.speak(sentences: [choice.reply]) { _ in } }   // 실패 시 자막만
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        NPCSetup.playAnimation(named: "Happy")
        QuestModel.shared.advance(on: .npcHelpDone)
    }

    /// 몰입 공간 재진입 시 초기화.
    func reset() {
        fallbackMode = false
        completed = false
    }
}
```

- [ ] **Step 3: NPCOrderView 작성**

`Barrier City/Dialogue/NPCOrderView.swift`:
```swift
//
//  NPCOrderView.swift
//  Barrier City
//
//  NPC 직원 대화 패널(빌보드 attachment).
//  push-to-talk(누르는 동안 듣기)로 음성 주문 → NPC 음성+자막 응답.
//  STT 실패·오프라인이면 선택지 버튼 폴백으로 같은 흐름을 완주한다.
//

import SwiftUI

struct NPCOrderView: View {

    @State private var holding = false

    var body: some View {
        let m = NPCOrderModel.shared
        let c = m.controller

        VStack(spacing: 20) {
            if m.completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.green)
                Text("주문이 접수되었습니다")
                    .font(.largeTitle).bold()
                if !c.npcSubtitle.isEmpty {
                    Text("“\(c.npcSubtitle)”")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("직원에게 주문하기")
                    .font(.largeTitle).bold()
                Text(statusLine(c))
                    .font(.title3).foregroundStyle(.secondary)

                // 자막 영역: 내 발화(실시간/확정) + NPC 응답
                VStack(spacing: 8) {
                    if c.status == .listening {
                        Text(c.liveText.isEmpty ? "…" : c.liveText)
                            .font(.title3).foregroundStyle(.blue)
                    } else if !c.userText.isEmpty {
                        Text("나: \(c.userText)").font(.title3)
                    }
                    if !c.npcSubtitle.isEmpty {
                        Text("직원: \(c.npcSubtitle)")
                            .font(.title3).bold()
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(minHeight: 80)

                if m.fallbackMode {
                    // 폴백: 선택지 버튼(오프라인·STT 불가에서도 완주)
                    VStack(spacing: 12) {
                        ForEach(m.choices) { choice in
                            Button { m.selectFallback(choice) } label: {
                                Text(choice.label)
                                    .font(.title3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    // push-to-talk: 누르는 동안 듣고, 떼면 응답.
                    Label(holding ? "듣는 중… 떼면 전송" : "누른 채로 말하기",
                          systemImage: holding ? "waveform" : "mic.fill")
                        .font(.title2).bold()
                        .frame(minWidth: 300)
                        .padding(.vertical, 16)
                        .background(holding ? Color.blue : Color.blue.opacity(0.5),
                                    in: Capsule())
                        .onLongPressGesture(minimumDuration: .infinity) {
                        } onPressingChanged: { pressing in
                            holding = pressing
                            if pressing {
                                Task { await m.beginListening() }
                            } else {
                                Task { await m.endTurn() }
                            }
                        }
                        .disabled(c.status == .thinking || c.status == .speaking)

                    Button("말하기가 어려우면 선택지로 주문") {
                        m.fallbackMode = true
                    }
                    .font(.callout)
                }
            }
        }
        .padding(48)
        .frame(width: 720)
        .glassBackgroundEffect()
    }

    private func statusLine(_ c: NPCDialogueController) -> String {
        switch c.status {
        case .idle:      return "버튼을 누른 채로 주문을 말해 보세요"
        case .listening: return "듣고 있어요"
        case .thinking:  return "직원이 생각하고 있어요…"
        case .speaking:  return "직원이 말하는 중"
        }
    }
}

#Preview(windowStyle: .automatic) {
    NPCOrderView()
}
```

- [ ] **Step 4: attachment 교체 + 리셋 연결**

`Barrier City/ImmersiveView.swift`의 Task 8 자리표시를 교체:
```swift
            // [김현기] NPC 주문 대화 패널(빌보드는 InteractionSetup이 처리)
            Attachment(id: "npcOrder") {
                NPCOrderView()
            }
```

`Barrier City/Interaction/InteractionSetup.swift`의 `install` 0단계 리셋 목록에 추가:
```swift
        NPCOrderModel.shared.reset()
```

- [ ] **Step 5: 소스 추가·테스트 확인**

Run:
```bash
ruby scripts/add_files.rb "Barrier City" "Barrier City/Dialogue/NPCOrderModel.swift" "Barrier City/Dialogue/NPCOrderView.swift"
xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: 시뮬레이터 확인(폴백 경로 중심)**

- NPC 접근 → 패널 등장 → "말하기가 어려우면 선택지로 주문" → 선택지 탭 → 자막에 고정 응답 + (네트워크 시) TTS 재생 → "주문이 접수되었습니다" + 퀘스트 3단계 완료 확인
- 시뮬레이터에서 STT가 되면 push-to-talk도 확인(안 되면 실기 체크리스트로)

- [ ] **Step 7: Commit**

```bash
git add "Barrier City" "Barrier City.xcodeproj"
git commit -m "feat(npc): 음성 주문 패널 — push-to-talk + 선택지 폴백 + 퀘스트 3단계 완료"
```

---

### Task 10: 통합 검증 + 마무리

**Files:**
- Verify only (수정은 발견된 문제에 한정)

- [ ] **Step 1: 전체 테스트**

Run: `xcodebuild test -scheme "Barrier City" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` — SmokeTests(1) + KioskFlowLogicTests(17) + KioskFlowModelTests(8)

- [ ] **Step 2: 시뮬레이터 엔드투엔드 체크리스트(스펙 6장)**

1. 몰입 진입 → 퀘스트 1단계 표시 → 조이스틱으로 문 접근 → "예" → 실내 전환 + 퀘스트 2단계
2. 키오스크 접근 → 실물 화면 월드 고정 표시
3. 상단 카테고리 탭 → 주황 펄스 → 3회 후 "손이 닿지 않습니다"
4. 방치 → 타이머 바 소진 → 리셋 연출 → 발소리 시작(첫 리셋 후)
5. 메뉴 담기 → "주문하기" → 결제 화면 → "결제 확인" 3회 → "결제가 완료되지 않았습니다" → 퀘스트 3단계
6. 키오스크 재접근 → failed 화면("직원에게 문의해 주세요") 고정 확인
7. NPC 접근 → 대화 패널 → 폴백 선택지로 주문 → "주문이 접수되었습니다" + 퀘스트 완료 연출
8. 트리거 이탈/재진입 시 패널 표시가 깜빡이지 않는지
9. 몰입 공간 나갔다 재진입 → 키오스크·NPC·퀘스트 전부 초기 상태인지

- [ ] **Step 3: 실기 체크리스트를 팀원 전달용으로 기록**

`docs/superpowers/specs/2026-07-21-kiosk-experience-design.md`의 6장 "실기 수동 체크리스트" 항목이 최신 구현과 일치하는지 확인하고, 달라진 점(예: 카테고리는 정직 판정, 결제는 항상 실패)이 있으면 스펙에 반영.

- [ ] **Step 4: 최종 Commit**

```bash
git add -A
git commit -m "chore(kiosk): 통합 검증 마무리 — 체크리스트 반영"
```
(변경이 없으면 커밋 생략.)

---

## 스코프 밖(재확인)

- 주문 성공 이후 마무리 연출(팀 회의 보류)
- 몸 기울임-전복 연동(C안 확장)
- 군중 NPC 3D 배치(오디오로 대체), 헛기침 사운드(선택)
- 정교한 키오스크 비주얼 디자인
