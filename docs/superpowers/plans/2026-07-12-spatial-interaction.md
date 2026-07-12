# 공간 인터랙션 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Outdoor에서 카페 문에 다가가면 문 앞 공간에 "안으로 입장하시겠습니까?" 예/아니요 패널이 뜨고, "예"를 누르면 같은 몰입 공간 안에서 배경이 Indoor로 바뀌며 실내 문 앞에 스폰된다.

**Architecture:** 상태·트리거·순수 판정 로직은 `InteractionModel`(싱글턴, @Observable)에 두고, `RealityView`의 `SceneEvents.Update` 구독이 매 프레임 플레이어 `(posX, posZ)`와 트리거 거리를 판정해 패널(attachment 엔티티, worldRoot 자식)을 표시·빌보드한다. "예"는 `SceneSwitcher`가 worldRoot의 시각 맵과 씬 원점의 투명 콜리전 사본을 Indoor로 갈아끼우고 포즈를 실내 스폰 상수로 리셋한다. 스펙의 "RealityKit System" 대신 `SceneEvents.Update` 구독을 쓴다 — System은 씬 생성 전(registerSystem) 등록이 필요해 AppModel(이윤서 파일) 수정이 강제되는 반면, 구독은 ImmersiveView 훅 안에서 완결된다(동일한 매 프레임 판정).

**Tech Stack:** Swift 6 / visionOS 26.5, RealityKit(`RealityView` attachments, `SceneEvents.Update`), SwiftUI, simd.

## Global Constraints

- **이윤서 파일 수정 허용 범위(이번 작업 한정): `Barrier City/ImmersiveView.swift`뿐.** 그 안에서도 Task 5에 명시된 정확한 편집만 — RealityView 시그니처(attachments), 참조 등록 2줄, install 호출 1블록, attachments 블록, `stripPhysics`/`addStaticCollision`의 `private` 제거. **AppModel·WheelchairMovementSystem·ControlPanelView·HandTrackingManager 등 다른 이윤서 파일은 절대 수정 금지.**
- 새 파일은 전부 `Barrier City/Interaction/` 폴더(폴더 자동 동기화 → pbxproj 수정 불필요), 김현기 소유.
- 자동 테스트 없음(프로젝트에 테스트 타깃 부재 — 스펙 §8). `evaluate`는 nonisolated 순수 함수로 유지. 각 태스크는 빌드 성공으로 검증, 최종 동작은 시뮬레이터 수동 시나리오.
- 빌드 검증 명령(각 태스크 공통):
  `cd "/Users/hyeongikim/Documents/2_Projects/barrier-city" && xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" -destination 'generic/platform=visionOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error: " | head -20`
  Expected: `** BUILD SUCCEEDED **`
- 주석·문구 한국어. 패널 문구 "안으로 입장하시겠습니까?" / "예" / "아니요" (스펙 §5.5 그대로).
- 커밋 메시지 말미: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 앱 타깃은 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — 클로저 격리 오류가 나면 `Task { @MainActor in ... }` 래핑으로 해결하고 리포트에 명시.
- 좌표 규약(이윤서 엔진): 맵 좌표 = 콜리전 사본이 놓인 세계 좌표. heading 0 = -Z 정면. 사용자(카메라)는 항상 세계 원점 부근(세계가 역변환으로 움직임).

## File Structure

**신규 (`Barrier City/Interaction/`):**
- `InteractionModel.swift` — GameScene/ProximityTrigger/InteractionTuning + `@Observable` 싱글턴 상태 + `evaluate` 순수 판정 함수
- `SceneSwitcher.swift` — Outdoor→Indoor 전환(시각 맵·콜리전 사본 교체, 검정 벽 보정, 포즈 리셋)
- `EntryPromptView.swift` — 예/아니요 유리 패널(SwiftUI, attachment 내용)
- `InteractionSetup.swift` — ImmersiveView 훅이 부르는 설치 함수(패널 배치·문 트리거 등록·Update 구독) + 매 프레임 `tick`(판정·패널 배치·빌보드)

**수정:**
- `Barrier City/ImmersiveView.swift` — Task 5의 명시된 편집만

---

### Task 1: InteractionModel — 상태·트리거·순수 판정 로직

**Files:**
- Create: `Barrier City/Interaction/InteractionModel.swift`

**Interfaces:**
- Produces (이후 태스크가 사용):
  - `enum GameScene { case outdoor, indoor }`
  - `struct ProximityTrigger: Identifiable, Equatable { let id: String; let center: SIMD2<Float>; let radius: Float; let prompt: String; let confirmLabel: String; let cancelLabel: String }`
  - `enum InteractionTuning` — `doorTriggerRadius: Float = 2.5`, `exitHysteresis: Float = 0.4`, `panelHeight: Float = 1.35`, `doorFallbackCenter = SIMD2<Float>(0, 15)`, `indoorSpawnX: Float = 0`, `indoorSpawnZ: Float = 4`, `indoorSpawnHeading: Float = 0`, `doorPrompt = "안으로 입장하시겠습니까?"`
  - `@Observable @MainActor final class InteractionModel` — `static let shared`, `scene`, `triggers`, `activeTrigger`, `dismissedTriggerID`, `isTransitioning`, `transitionError`, `dismissActive()`, `@ObservationIgnored panelEntity/visibleMap/collisionMap: Entity?`, `@ObservationIgnored updateSubscription: EventSubscription?`
  - `InteractionModel.evaluate(playerX:playerZ:triggers:activeID:dismissedID:) -> ProximityVerdict` (nonisolated 순수 함수), `struct ProximityVerdict { let showID: String?; let clearDismissed: Bool }`

- [ ] **Step 1: 파일 작성**

Create `Barrier City/Interaction/InteractionModel.swift`:

```swift
//
//  InteractionModel.swift
//  Barrier City
//
//  공간 인터랙션(근접 트리거 → 예/아니요 패널)의 상태 단일 진실원.
//  판정 로직(evaluate)은 nonisolated 순수 함수로 분리해 향후 테스트 타깃이
//  생기면 바로 단위 테스트를 붙일 수 있게 한다.
//

import RealityKit
import simd
import Observation

/// 현재 배경 씬.
enum GameScene {
    case outdoor
    case indoor
}

/// 근접 인터랙션 트리거 하나(문·키오스크 등). 순수 값 타입.
struct ProximityTrigger: Identifiable, Equatable {
    /// 고유 id (예: "door.enter")
    let id: String
    /// 트리거 중심(맵 좌표 x, z)
    let center: SIMD2<Float>
    /// 진입 반경(m)
    let radius: Float
    /// 패널에 표시할 질문 문구
    let prompt: String
    /// 확인 버튼 라벨
    let confirmLabel: String
    /// 취소 버튼 라벨
    let cancelLabel: String
}

/// 인터랙션 튜닝 상수 단일 진실원(시뮬레이터에서 보고 조정).
enum InteractionTuning {
    /// 문 트리거 진입 반경(m)
    static let doorTriggerRadius: Float = 2.5
    /// 이탈 히스테리시스(m). 경계에서 패널이 깜빡이지 않도록 진입 반경 + 이 값 밖으로
    /// 나가야 닫힌다.
    static let exitHysteresis: Float = 0.4
    /// 패널 표시 높이(m, 맵 좌표 y)
    static let panelHeight: Float = 1.35
    /// DOOR1 프림을 못 찾을 때의 문 트리거 폴백 좌표(맵 좌표 x, z).
    /// _coffee 건물이 (0, 0.3, 20)에 배치돼 있어 문은 그 앞쪽으로 추정. 수동 검증에서 확정.
    static let doorFallbackCenter = SIMD2<Float>(0, 15)
    /// Indoor 전환 직후 스폰 포즈(실내 문 앞, 카운터를 바라봄). 수동 검증에서 확정.
    static let indoorSpawnX: Float = 0
    static let indoorSpawnZ: Float = 4
    static let indoorSpawnHeading: Float = 0
    /// 문 패널 문구
    static let doorPrompt = "안으로 입장하시겠습니까?"
}

/// evaluate의 판정 결과.
struct ProximityVerdict {
    /// 표시해야 할 트리거 id (nil = 패널 숨김)
    let showID: String?
    /// true면 dismissedTriggerID를 해제(범위 이탈 → 재접근 시 재표시)
    let clearDismissed: Bool
}

/// 공간 인터랙션 전역 상태. System이 아닌 SceneEvents.Update 구독(tick)이 읽고 쓴다.
@Observable
@MainActor
final class InteractionModel {

    static let shared = InteractionModel()

    /// 현재 배경 씬.
    var scene: GameScene = .outdoor
    /// 현재 씬의 트리거 목록.
    var triggers: [ProximityTrigger] = []
    /// 표시 중인 패널의 트리거(nil = 숨김).
    var activeTrigger: ProximityTrigger?
    /// "아니요"로 닫힌 트리거 id. 범위 이탈 시 해제되어 재접근하면 다시 뜬다.
    var dismissedTriggerID: String?
    /// 씬 전환 중(패널 버튼 비활성화 + 판정 일시 정지).
    var isTransitioning = false
    /// 전환 실패 등 패널에 표시할 안내 문구.
    var transitionError: String?

    // MARK: - 엔티티·구독 참조(관찰 대상 아님)
    /// 패널 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var panelEntity: Entity?
    /// 현재 보이는 맵 엔티티(worldRoot 자식). SceneSwitcher가 교체.
    @ObservationIgnored var visibleMap: Entity?
    /// 씬 원점 고정 투명 콜리전 사본. SceneSwitcher가 교체.
    @ObservationIgnored var collisionMap: Entity?
    /// SceneEvents.Update 구독(해제 방지용 보관).
    @ObservationIgnored var updateSubscription: EventSubscription?

    /// "아니요": 현재 패널을 닫고, 범위를 벗어났다 재진입하기 전까지 다시 띄우지 않는다.
    func dismissActive() {
        dismissedTriggerID = activeTrigger?.id
        activeTrigger = nil
    }

    // MARK: - 순수 판정 로직

    /// 플레이어 위치와 트리거 목록으로 "어느 패널을 보여줄지"를 판정한다.
    /// - 진입: 가장 가까운 트리거의 radius 안이고 dismissed가 아니면 표시
    /// - 표시 중: radius + exitHysteresis 밖으로 나가야 닫힘(경계 깜빡임 방지)
    /// - dismissed: 범위 안에서는 유지, 범위 밖으로 나가면 해제(재접근 시 재표시)
    nonisolated static func evaluate(playerX: Float, playerZ: Float,
                                     triggers: [ProximityTrigger],
                                     activeID: String?,
                                     dismissedID: String?) -> ProximityVerdict {
        // 가장 가까운 트리거를 찾는다.
        var best: (trigger: ProximityTrigger, distance: Float)?
        for t in triggers {
            let d = simd_distance(SIMD2(playerX, playerZ), t.center)
            if best == nil || d < best!.distance { best = (t, d) }
        }
        guard let (t, d) = best else {
            return ProximityVerdict(showID: nil, clearDismissed: dismissedID != nil)
        }

        if activeID == t.id {
            // 이미 표시 중: 히스테리시스 반경 밖으로 나가야 닫힘.
            let stillInside = d <= t.radius + InteractionTuning.exitHysteresis
            return ProximityVerdict(showID: stillInside ? t.id : nil, clearDismissed: false)
        }
        if d <= t.radius {
            // 범위 안: 거절 상태면 숨김 유지, 아니면 표시.
            if dismissedID == t.id { return ProximityVerdict(showID: nil, clearDismissed: false) }
            return ProximityVerdict(showID: t.id, clearDismissed: false)
        }
        // 범위 밖: 거절 상태 해제(다시 다가오면 재표시).
        return ProximityVerdict(showID: nil, clearDismissed: dismissedID != nil)
    }
}
```

- [ ] **Step 2: 빌드 검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 커밋**

```bash
git add "Barrier City/Interaction/InteractionModel.swift"
git commit -m "feat(interaction): 근접 트리거 상태 모델 + 순수 판정 로직

- ProximityTrigger/GameScene/InteractionTuning + @Observable 싱글턴
- evaluate: 진입 표시·히스테리시스 이탈·거절 유지·재접근 재표시 (nonisolated 순수 함수)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SceneSwitcher — Outdoor→Indoor 전환

**Files:**
- Create: `Barrier City/Interaction/SceneSwitcher.swift`

**Interfaces:**
- Consumes: `InteractionModel.shared`(Task 1), `AppModel.current`/`worldRoot`/`restart()`/`collisionShapes`(이윤서), `ImmersiveView.stripPhysics`/`ImmersiveView.addStaticCollision`(Task 5에서 private 제거 예정 — **이 태스크 시점엔 아직 private이므로 임시로 컴파일되지 않는다. 아래 Step 1의 주석 참고: 이 태스크에서는 자체 로컬 복사 없이 `ImmersiveView.` 호출로 작성하고, 빌드 검증은 Task 5 완료 후에 통과된다. 따라서 이 태스크의 빌드 검증은 "컴파일 에러가 ImmersiveView.stripPhysics 접근 불가 2건뿐인지" 확인하는 것으로 대체한다.**
- Produces: `SceneSwitcher.switchToIndoor() async` — EntryPromptView(Task 3)가 호출.

- [ ] **Step 1: 파일 작성**

Create `Barrier City/Interaction/SceneSwitcher.swift`:

```swift
//
//  SceneSwitcher.swift
//  Barrier City
//
//  Outdoor("Map") → Indoor("Indoor") 배경 전환.
//  같은 몰입 공간을 유지한 채 ① worldRoot의 시각 맵 교체 ② 씬 원점의 투명 콜리전
//  사본 교체 ③ 포즈를 실내 문 앞 스폰 상수로 리셋한다.
//
//  stripPhysics/addStaticCollision은 이윤서 ImmersiveView의 검증된 로더 유틸을
//  그대로 호출한다(중복 구현 방지, Task 5에서 private 제거).
//

import RealityKit
import RealityKitContent
import SwiftUI

@MainActor
enum SceneSwitcher {

    /// "예" 선택 시 호출. Outdoor에서만 동작하며, 실패 시 Outdoor를 유지하고
    /// 패널에 안내 문구를 띄운다.
    static func switchToIndoor() async {
        let im = InteractionModel.shared
        guard !im.isTransitioning, im.scene == .outdoor,
              let app = AppModel.current, let worldRoot = app.worldRoot else { return }
        im.isTransitioning = true
        defer { im.isTransitioning = false }

        // 1) 실내 시각 맵 로드(실패 시 전환 취소, Outdoor 유지)
        guard let indoorVisible = try? await Entity(named: "Indoor", in: realityKitContentBundle) else {
            im.transitionError = "지금은 들어갈 수 없어요. 잠시 후 다시 시도해 주세요."
            print("⚠️ Indoor 씬(시각) 로드 실패 — 이름/번들 확인")
            return
        }
        ImmersiveView.stripPhysics(indoorVisible)
        brighten(indoorVisible)

        // 2) 시각 맵 교체(worldRoot 아래)
        im.visibleMap?.removeFromParent()
        worldRoot.addChild(indoorVisible)
        im.visibleMap = indoorVisible

        // 3) 콜리전 사본 교체(기존 사본과 같은 부모에).
        //    Indoor에 아직 'collision' 네이밍 메시가 없으면 0개가 부여되지만,
        //    씬에 상주하는 debugFloorCollision이 바닥을 담당해 주행은 정상이다
        //    (실내 벽 통과는 1차 스코프에서 허용 — 김선환 RCP 콜리전 작업 대기).
        if let oldCollision = im.collisionMap, let parent = oldCollision.parent {
            if let indoorCollision = try? await Entity(named: "Indoor", in: realityKitContentBundle) {
                ImmersiveView.stripPhysics(indoorCollision)
                let n = await ImmersiveView.addStaticCollision(indoorCollision)
                app.collisionShapes = n
                indoorCollision.components.set(OpacityComponent(opacity: 0))
                parent.addChild(indoorCollision)
                oldCollision.removeFromParent()
                im.collisionMap = indoorCollision
            } else {
                print("⚠️ Indoor 씬(콜리전) 로드 실패 — 기존 콜리전 유지")
            }
        }

        // 4) 포즈 리셋: 실내 문 앞(밖에서 문을 열고 들어온 위치)
        app.restart()
        app.posX = InteractionTuning.indoorSpawnX
        app.posZ = InteractionTuning.indoorSpawnZ
        app.heading = InteractionTuning.indoorSpawnHeading

        // 5) 인터랙션 상태 전환: 실내 트리거는 1차 스코프에 없음(Kiosk는 다음 단계)
        im.scene = .indoor
        im.triggers = []
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.panelEntity?.isEnabled = false
    }

    /// Indoor 프로토타입의 검정 벽 임시 보정: 모든 메시를 밝은 단색으로 덮어쓴다.
    /// (wall 머티리얼에 diffuseColor가 없어 검정으로 렌더되는 이슈 — 텍스처링은
    ///  김선환 일정의 몫이므로 코드에서 임시 처리)
    /// 조상 이름을 물려받아 바닥/바/키오스크만 다른 톤을 준다.
    private static func brighten(_ entity: Entity, inheritedLabel: String = "") {
        let label = (inheritedLabel + " " + entity.name).lowercased()
        if var model = entity.components[ModelComponent.self] {
            let color: UIColor
            if label.contains("floor") {
                color = UIColor(white: 0.55, alpha: 1)          // 바닥: 중간 회색
            } else if label.contains("kiosk") {
                color = UIColor(white: 0.25, alpha: 1)          // 키오스크: 짙은 회색
            } else if label.contains("bar") {
                color = UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1)  // 바: 나무톤
            } else {
                color = UIColor(white: 0.85, alpha: 1)          // 벽·천장: 밝은 회색
            }
            model.materials = [SimpleMaterial(color: color, isMetallic: false)]
            entity.components.set(model)
        }
        for child in entity.children {
            brighten(child, inheritedLabel: label)
        }
    }
}
```

- [ ] **Step 2: 빌드로 에러 범위 확인**

Global Constraints의 빌드 명령 실행.
Expected: **BUILD FAILED** — 에러가 `'stripPhysics' is inaccessible due to 'private' protection level`, `'addStaticCollision' is inaccessible ...` **2건뿐**인지 확인(다른 에러가 있으면 이 파일의 문제이므로 수정). 이 2건은 Task 5에서 private 제거로 해소된다.

- [ ] **Step 3: 커밋**

```bash
git add "Barrier City/Interaction/SceneSwitcher.swift"
git commit -m "feat(interaction): SceneSwitcher — Indoor 전환(맵·콜리전 교체+스폰 리셋)

- 실패 시 Outdoor 유지 + 패널 안내 문구, 검정 벽 임시 보정(brighten)
- 이윤서 로더 유틸 호출부는 Task 5(private 제거) 이후 컴파일됨

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: EntryPromptView — 예/아니요 패널

**Files:**
- Create: `Barrier City/Interaction/EntryPromptView.swift`

**Interfaces:**
- Consumes: `InteractionModel.shared`(Task 1), `SceneSwitcher.switchToIndoor()`(Task 2).
- Produces: `struct EntryPromptView: View` — Task 5의 attachments 블록이 사용.

- [ ] **Step 1: 파일 작성**

Create `Barrier City/Interaction/EntryPromptView.swift`:

```swift
//
//  EntryPromptView.swift
//  Barrier City
//
//  근접 트리거가 활성화되면 문 앞 공간에 뜨는 예/아니요 패널.
//  RealityView attachment로 렌더되어 worldRoot 자식 엔티티로 배치된다.
//

import SwiftUI

struct EntryPromptView: View {

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 프로퍼티가 관찰 의존성이 된다.
        let im = InteractionModel.shared

        VStack(spacing: 14) {
            Text(im.activeTrigger?.prompt ?? "")
                .font(.title3).bold()
                .multilineTextAlignment(.center)

            if let error = im.transitionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    im.dismissActive()
                } label: {
                    Text(im.activeTrigger?.cancelLabel ?? "아니요")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await SceneSwitcher.switchToIndoor() }
                } label: {
                    Text(im.activeTrigger?.confirmLabel ?? "예")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(im.isTransitioning)
        }
        .padding(24)
        .frame(width: 340)
        .glassBackgroundEffect()
    }
}
```

- [ ] **Step 2: 빌드로 에러 범위 확인**

Global Constraints의 빌드 명령 실행.
Expected: Task 2와 동일하게 `stripPhysics`/`addStaticCollision` 접근 불가 **2건만** 남아 있어야 함(EntryPromptView 자체 에러 없음).

- [ ] **Step 3: 커밋**

```bash
git add "Barrier City/Interaction/EntryPromptView.swift"
git commit -m "feat(interaction): 예/아니요 입장 패널 뷰(유리 배경, 전환 중 비활성)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: InteractionSetup — 설치 + 매 프레임 판정·패널 배치

**Files:**
- Create: `Barrier City/Interaction/InteractionSetup.swift`

**Interfaces:**
- Consumes: `InteractionModel`(Task 1)의 전 필드, `AppModel.current`(이윤서), `InteractionTuning`.
- Produces: `InteractionSetup.install(content:attachments:appModel:)` — Task 5의 make 클로저 끝에서 호출. attachment id 문자열 `"entryPrompt"`.

- [ ] **Step 1: 파일 작성**

Create `Barrier City/Interaction/InteractionSetup.swift`:

```swift
//
//  InteractionSetup.swift
//  Barrier City
//
//  ImmersiveView make 클로저 끝에서 한 번 호출되는 설치 함수와,
//  SceneEvents.Update 구독으로 매 프레임 도는 근접 판정(tick).
//
//  RealityKit System 대신 구독을 쓰는 이유: System은 씬 생성 전 registerSystem이
//  필요해 AppModel(이윤서 파일) 수정이 강제되지만, 구독은 이 훅 안에서 완결된다.
//

import RealityKit
import SwiftUI
import simd

@MainActor
enum InteractionSetup {

    /// ImmersiveView make 클로저 끝에서 호출. 전제: model.worldRoot와
    /// InteractionModel.shared.visibleMap이 설정된 뒤여야 한다.
    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        let im = InteractionModel.shared

        // 1) 패널 attachment를 worldRoot 아래에 배치(초기 숨김) — 맵과 함께 움직인다.
        if let panel = attachments.entity(for: "entryPrompt"), let worldRoot = appModel.worldRoot {
            panel.isEnabled = false
            worldRoot.addChild(panel)
            im.panelEntity = panel
        } else {
            print("⚠️ entryPrompt attachment 또는 worldRoot 없음 — 인터랙션 패널 비활성")
        }

        // 2) 문 트리거 등록: 로드된 맵에서 DOOR1 프림의 맵 좌표를 찾고, 실패 시 폴백 상수.
        var center = InteractionTuning.doorFallbackCenter
        if let worldRoot = appModel.worldRoot,
           let door = im.visibleMap?.findEntity(named: "DOOR1") {
            let p = door.position(relativeTo: worldRoot)
            center = SIMD2(p.x, p.z)
            print("문 트리거: DOOR1 위치 사용 (\(p.x), \(p.z))")
        } else {
            print("⚠️ DOOR1 프림을 찾지 못해 폴백 좌표 사용: \(center)")
        }
        im.triggers = [ProximityTrigger(
            id: "door.enter",
            center: center,
            radius: InteractionTuning.doorTriggerRadius,
            prompt: InteractionTuning.doorPrompt,
            confirmLabel: "예",
            cancelLabel: "아니요")]

        // 3) 매 프레임 근접 판정 구독(구독 객체를 보관해야 해제되지 않는다).
        im.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { _ in
            tick()
        }
    }

    /// 매 프레임: 판정 → activeTrigger 갱신 → 패널 표시·배치·빌보드.
    private static func tick() {
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
    }

    /// 패널을 트리거 위 눈높이에 놓고, 사용자(세계 원점 부근)를 바라보게 yaw 빌보드.
    private static func updatePanel(_ im: InteractionModel) {
        guard let panel = im.panelEntity else { return }
        guard let trigger = im.activeTrigger else {
            panel.isEnabled = false
            return
        }
        panel.isEnabled = true
        // 위치: 맵 좌표(worldRoot 로컬) — 트리거 중심 위 panelHeight.
        panel.setPosition([trigger.center.x, InteractionTuning.panelHeight, trigger.center.y],
                          relativeTo: panel.parent)
        // 빌보드: 사용자는 항상 세계 원점 부근(세계가 역변환으로 움직이므로).
        // 패널의 세계 위치에서 원점을 향하는 yaw만 적용한다.
        let worldPos = panel.position(relativeTo: nil)
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
    }
}
```

- [ ] **Step 2: 빌드로 에러 범위 확인**

Global Constraints의 빌드 명령 실행.
Expected: 여전히 `stripPhysics`/`addStaticCollision` 접근 불가 **2건만** (InteractionSetup 자체 에러 없음). 만약 `content.subscribe` 클로저에서 MainActor 격리 에러가 나면 `{ _ in tick() }`를 `{ _ in Task { @MainActor in tick() } }`로 바꾸고 커밋 메시지에 명시.

- [ ] **Step 3: 커밋**

```bash
git add "Barrier City/Interaction/InteractionSetup.swift"
git commit -m "feat(interaction): 설치 훅 + 매 프레임 근접 판정·패널 빌보드

- attachment 패널을 worldRoot에 배치(초기 숨김), DOOR1 위치로 문 트리거 등록(폴백 상수)
- SceneEvents.Update 구독 tick: evaluate → activeTrigger → 패널 표시·yaw 빌보드

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: ImmersiveView 훅 (이윤서 파일 — 허용받은 편집만)

**Files:**
- Modify: `Barrier City/ImmersiveView.swift` (아래 6개 편집 외 금지)

**Interfaces:**
- Consumes: `InteractionSetup.install`(Task 4), `EntryPromptView`(Task 3), `InteractionModel.shared`(Task 1).
- Produces: `ImmersiveView.stripPhysics`/`ImmersiveView.addStaticCollision`이 internal이 되어 SceneSwitcher(Task 2)가 컴파일됨. 전체 기능 연결 완료.

- [ ] **Step 1: RealityView 시그니처에 attachments 추가**

`Barrier City/ImmersiveView.swift`에서:
```swift
        return RealityView { content in
```
→
```swift
        return RealityView { content, attachments in
```
그리고:
```swift
        } update: { _ in
```
→
```swift
        } update: { _, _ in
```

- [ ] **Step 2: 시각 맵 참조 등록 (1줄)**

```swift
                Self.hideColliders(cafeVisible)   // 충돌용 단순 도형은 시각에서 숨김
                worldRoot.addChild(cafeVisible)
```
→
```swift
                Self.hideColliders(cafeVisible)   // 충돌용 단순 도형은 시각에서 숨김
                worldRoot.addChild(cafeVisible)
                InteractionModel.shared.visibleMap = cafeVisible   // [김현기] 씬 전환용 참조
```

- [ ] **Step 3: 콜리전 사본 참조 등록 (1줄)**

```swift
                cafeCollision.components.set(OpacityComponent(opacity: 0))   // 안 보이게(충돌만)
                content.add(cafeCollision)
```
→
```swift
                cafeCollision.components.set(OpacityComponent(opacity: 0))   // 안 보이게(충돌만)
                content.add(cafeCollision)
                InteractionModel.shared.collisionMap = cafeCollision   // [김현기] 씬 전환용 참조
```

- [ ] **Step 4: make 클로저 끝에 설치 훅 (1블록)**

make 클로저의 마지막(휠체어 로드 블록 닫힌 뒤, `} update:` 직전):
```swift
            } else {
                print("⚠️ WhellChair.usdz 로드 실패 — 이름/번들 확인")
            }

        } update: { _, _ in
```
→
```swift
            } else {
                print("⚠️ WhellChair.usdz 로드 실패 — 이름/번들 확인")
            }

            // [김현기] 공간 인터랙션: 근접 패널 attachment + 문 트리거 + 매 프레임 판정 구독
            InteractionSetup.install(content: content, attachments: attachments, appModel: model)

        } update: { _, _ in
```

- [ ] **Step 5: attachments 블록 추가**

update 클로저가 닫히는 부분:
```swift
            setMaterials(rightWheelMesh, model.rightGrabbed ? rightHiMats : rightBaseMats)
        }
        .onAppear {
```
→
```swift
            setMaterials(rightWheelMesh, model.rightGrabbed ? rightHiMats : rightBaseMats)
        } attachments: {
            // [김현기] 문 앞 입장 패널(공간 고정 + 빌보드는 InteractionSetup이 처리)
            Attachment(id: "entryPrompt") {
                EntryPromptView()
            }
        }
        .onAppear {
```

- [ ] **Step 6: 로더 유틸 2개의 private 제거 (SceneSwitcher가 재사용)**

```swift
    @discardableResult
    private static func addStaticCollision(_ entity: Entity, inherited: Bool = false) async -> Int {
```
→
```swift
    @discardableResult
    static func addStaticCollision(_ entity: Entity, inherited: Bool = false) async -> Int {
```
그리고:
```swift
    /// USDA에 딸려온 물리(RigidBody)/콜리전을 제거 — 물리·충돌은 코드에서만 관리.
    private static func stripPhysics(_ entity: Entity) {
```
→
```swift
    /// USDA에 딸려온 물리(RigidBody)/콜리전을 제거 — 물리·충돌은 코드에서만 관리.
    static func stripPhysics(_ entity: Entity) {
```

- [ ] **Step 7: 빌드 검증 (이제 전체가 통과해야 함)**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **` (Task 2의 접근 불가 2건 해소 포함).

- [ ] **Step 8: 커밋**

```bash
git add "Barrier City/ImmersiveView.swift"
git commit -m "feat(interaction): ImmersiveView에 공간 인터랙션 훅 연결

- RealityView attachments(entryPrompt) + InteractionSetup.install 호출
- 씬 전환용 시각 맵·콜리전 사본 참조 등록(각 1줄)
- stripPhysics/addStaticCollision private 제거(SceneSwitcher 재사용)
- 허용받은 편집 범위(ImmersiveView 한정) 내 변경

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: 시뮬레이터 수동 검증 + 튜닝 (Wade 수행, Claude가 상수 반영)

**Files:**
- Modify: `Barrier City/Interaction/InteractionModel.swift` (InteractionTuning 상수만)
- Modify: `Barrier City/Interaction/InteractionSetup.swift` (빌보드 방향 뒤집힘 시 yaw 보정만)

**Interfaces:**
- Consumes: Task 5까지의 전체 기능.

- [ ] **Step 1: 수동 검증 시나리오 (Xcode 시뮬레이터)**

1. 앱 실행 → "체험 시작" → Outdoor(카페 건물) 확인.
2. 콘솔에서 `문 트리거: DOOR1 위치 사용 (x, z)` 로그 확인(폴백 경고가 뜨면 그 좌표 기록).
3. 조이스틱으로 문 앞 접근 → 반경(2.5m) 진입 시 패널 표시, **글자가 사용자를 향하는지** 확인(뒤집혀 보이면 Step 2의 yaw 보정).
4. 뒤로 물러나면(반경+0.4m 밖) 패널 자동 닫힘 → 재접근 시 재표시.
5. "아니요" → 닫힘, 범위 안에 머물러도 안 뜸 → 나갔다 재접근 시 재표시.
6. "예" → Indoor로 전환 + 실내 문 앞 스폰. 위치·방향이 어색하면 좌표 기록.
7. Indoor에서 조이스틱 주행 정상(바닥 위 이동) 확인. 벽 통과는 알려진 제약(허용).

- [ ] **Step 2: 발견값 반영**

- 빌보드가 뒤집혀 보이면 `InteractionSetup.updatePanel`의 `let yaw = atan2(-worldPos.x, -worldPos.z)`를 `let yaw = atan2(worldPos.x, worldPos.z)`로 교체.
- 스폰이 어색하면 `InteractionTuning.indoorSpawnX/Z/Heading` 값을 관찰값으로 수정.
- DOOR1 폴백이 쓰였거나 트리거 위치가 어긋나면 `doorFallbackCenter`/`doorTriggerRadius` 수정.
- 패널 높이가 어색하면 `panelHeight` 수정.

- [ ] **Step 3: 빌드 재검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 커밋**

```bash
git add "Barrier City/Interaction/InteractionModel.swift" "Barrier City/Interaction/InteractionSetup.swift"
git commit -m "chore(interaction): 시뮬레이터 실측 튜닝(스폰·트리거·빌보드)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 실행 후 다음 단계 (이 계획 범위 밖)

1. Kiosk 트리거(Indoor 트리거 목록에 등록) + 키오스크 주문 UI/대화 연결
2. Indoor→Outdoor 나가기 트리거
3. 실내 벽 콜리전(김선환, `collision` 네이밍)
4. 문 열림 연출·사운드
