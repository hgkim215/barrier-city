# 키오스크 장벽 인터랙션 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Indoor에서 키오스크에 다가가면 서 있는 눈높이(1.5m)에 고정된 주문 화면이 뜨는데, 메뉴·결제 버튼은 앉은 리치 밖이라 "손이 닿지 않습니다"만 뜨고 눌리지 않아 스스로 주문할 수 없는 장벽을 체험시킨다(하단 "직원 호출"만 가능).

**Architecture:** 문 인터랙션에서 만든 근접 트리거 인프라(`InteractionModel`/`InteractionSetup`/`SceneSwitcher`)를 확장한다. `ProximityTrigger`에 `kind`(.yesNoPrompt / .kioskScreen)를 추가하고, Indoor 전환 시 `Kiosk` 프림 위치로 키오스크 트리거를 등록한다. 매 프레임 `updatePanel`이 활성 트리거의 kind에 따라 문 패널(빌보드)과 키오스크 화면(고정 높이·고정 방향)을 라우팅한다. 키오스크 화면(`KioskOrderView`)은 상단 메뉴·결제를 리치 밖으로 정적 태깅해 탭 시 흔들림+토스트만 준다.

**Tech Stack:** Swift 6 / visionOS 26.5, RealityKit(`RealityView` attachments), SwiftUI, simd.

## Global Constraints

- **이윤서 파일 수정 허용 범위(이번 작업 한정): `Barrier City/ImmersiveView.swift`의 attachments 블록에 3줄 추가뿐**(Task 5). 그 외 이윤서 파일(AppModel·WheelchairMovementSystem·ControlPanelView·HandTrackingManager 등) 절대 수정 금지.
- 신규 파일은 `Barrier City/Interaction/` 폴더(폴더 자동 동기화 → pbxproj 수정 불필요), 김현기 소유. 기존 인터랙션 파일 3개도 김현기 소유.
- 자동 테스트 없음(프로젝트에 테스트 타깃 부재). `evaluate`는 이번 작업에서 무수정. 각 태스크는 빌드 성공으로 검증, 최종 동작은 시뮬레이터 수동 시나리오.
- 빌드 검증 명령(각 태스크 공통):
  `cd "/Users/hyeongikim/Documents/2_Projects/barrier-city" && xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" -destination 'generic/platform=visionOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error: " | head -20`
  Expected: `** BUILD SUCCEEDED **`
- **빌드 후 정리**: xcodebuild가 `project.pbxproj`의 `DEVELOPMENT_TEAM`을 팀 값(`H2WD8C55D7`)에서 로컬 팀으로 자동 변경하고 `hyeongikim.rcuserdata`를 생성한다. 커밋 전 반드시:
  `git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"`
- 주석·문구 한국어. 커밋 메시지 말미: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 각 태스크는 컴파일되는 상태로 끝난다(중간 깨짐 없음). Task 5까지 키오스크 화면은 안 보이지만 문 인터랙션은 매 태스크에서 정상 동작한다.
- SourceKit 에디터 진단(`No such module`, `Cannot find ... in scope`)은 인덱싱 오탐이다 — `xcodebuild` 결과가 권위.

## File Structure

**신규 (`Barrier City/Interaction/`):**
- `KioskOrderView.swift` — 키오스크 주문 화면(메뉴·결제=리치 밖, 직원 호출=리치 안) + ShakeEffect

**수정 (전부 김현기 소유):**
- `Barrier City/Interaction/InteractionModel.swift` — TriggerKind, ProximityTrigger.kind, staffCalled, kioskPanelEntity, 키오스크 튜닝 상수
- `Barrier City/Interaction/InteractionSetup.swift` — 키오스크 attachment 장착 + staffCalled 리셋 + updatePanel kind 라우팅
- `Barrier City/Interaction/SceneSwitcher.swift` — Indoor 전환 시 키오스크 트리거 등록

**수정 (이윤서 — 허용받은 3줄):**
- `Barrier City/ImmersiveView.swift` — attachments 블록에 kioskScreen 추가

---

### Task 1: InteractionModel 확장 (TriggerKind·kind·staffCalled·튜닝)

**Files:**
- Modify: `Barrier City/Interaction/InteractionModel.swift`

**Interfaces:**
- Produces:
  - `enum TriggerKind { case yesNoPrompt, kioskScreen }`
  - `ProximityTrigger`에 `let kind: TriggerKind` + 커스텀 init(`kind` 기본값 `.yesNoPrompt`, `confirmLabel`/`cancelLabel` 기본값 `""`) — 기존 문 트리거 생성부 무수정 유지
  - `InteractionModel.staffCalled: Bool`, `InteractionModel.kioskPanelEntity: Entity?`
  - `InteractionTuning.kioskTriggerRadius`(2.0), `.kioskScreenHeight`(1.5), `.kioskScreenYaw`(0), `.kioskFallbackCenter`(SIMD2(-4,-4)), `.kioskTitle`("주문하기")

- [ ] **Step 1: TriggerKind enum 추가 + ProximityTrigger에 kind + 커스텀 init**

`Barrier City/Interaction/InteractionModel.swift`에서:
```swift
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
```
→
```swift
/// 트리거가 활성화됐을 때 띄우는 UI 종류.
enum TriggerKind {
    /// 예/아니요 확인 패널(문 등)
    case yesNoPrompt
    /// 키오스크 주문 화면(고정 높이 장벽)
    case kioskScreen
}

/// 근접 인터랙션 트리거 하나(문·키오스크 등). 순수 값 타입.
struct ProximityTrigger: Identifiable, Equatable {
    /// 고유 id (예: "door.enter")
    let id: String
    /// 트리거 중심(맵 좌표 x, z)
    let center: SIMD2<Float>
    /// 진입 반경(m)
    let radius: Float
    /// 활성화 시 띄울 UI 종류
    let kind: TriggerKind
    /// 패널에 표시할 질문 문구(kioskScreen은 화면 타이틀로 사용)
    let prompt: String
    /// 확인 버튼 라벨(yesNoPrompt 전용)
    let confirmLabel: String
    /// 취소 버튼 라벨(yesNoPrompt 전용)
    let cancelLabel: String

    /// kind 기본값 .yesNoPrompt, 라벨 기본값 ""이라 기존 문 트리거 생성부는 무수정.
    init(id: String, center: SIMD2<Float>, radius: Float,
         kind: TriggerKind = .yesNoPrompt,
         prompt: String, confirmLabel: String = "", cancelLabel: String = "") {
        self.id = id
        self.center = center
        self.radius = radius
        self.kind = kind
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
    }
}
```

- [ ] **Step 2: 키오스크 튜닝 상수 추가**

`InteractionTuning` enum의 `doorPrompt` 줄:
```swift
    /// 문 패널 문구
    static let doorPrompt = "안으로 입장하시겠습니까?"
}
```
→
```swift
    /// 문 패널 문구
    static let doorPrompt = "안으로 입장하시겠습니까?"

    /// 키오스크 트리거 진입 반경(m)
    static let kioskTriggerRadius: Float = 2.0
    /// 키오스크 화면 중심 높이(m, 맵 좌표 y). 서 있는 눈높이 → 앉으면 올려다봄.
    static let kioskScreenHeight: Float = 1.5
    /// 키오스크 화면이 향하는 방향(라디안, 맵 좌표 yaw 고정. 빌보드 안 함).
    /// 0 = 방 안쪽(+Z)을 향함. 시뮬레이터에서 실측 조정.
    static let kioskScreenYaw: Float = 0
    /// Kiosk 프림을 못 찾을 때의 키오스크 트리거 폴백 좌표(카운터 좌측 부근 추정. 실측 조정).
    static let kioskFallbackCenter = SIMD2<Float>(-4, -4)
    /// 키오스크 화면 타이틀 겸 트리거 prompt 값.
    static let kioskTitle = "주문하기"
}
```

- [ ] **Step 3: staffCalled + kioskPanelEntity 필드 추가**

`InteractionModel` 클래스의 패널 참조 부분:
```swift
    /// 패널 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var panelEntity: Entity?
```
→
```swift
    /// 문 예/아니요 패널 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var panelEntity: Entity?
    /// 키오스크 주문 화면 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var kioskPanelEntity: Entity?
    /// 키오스크에서 "직원 호출"을 누른 상태(스텁). 재진입 시 install에서 리셋.
    var staffCalled = false
```

- [ ] **Step 4: 빌드 검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`
(기존 문 트리거 생성부는 `kind` 기본값 덕에 무수정으로 컴파일됨.)

- [ ] **Step 5: 정리 후 커밋**

```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/Interaction/InteractionModel.swift"
git commit -m "feat(kiosk): InteractionModel에 TriggerKind·kind·staffCalled·키오스크 튜닝 추가

- ProximityTrigger에 kind(기본 .yesNoPrompt) → 기존 문 트리거 무수정
- 키오스크 화면 높이/방향/반경/폴백/타이틀 상수, kioskPanelEntity·staffCalled

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: KioskOrderView — 주문 화면(리치 장벽)

**Files:**
- Create: `Barrier City/Interaction/KioskOrderView.swift`

**Interfaces:**
- Consumes: `InteractionModel.shared`(staffCalled), `InteractionTuning.kioskTitle`(Task 1).
- Produces: `struct KioskOrderView: View` — Task 5의 attachments 블록이 사용.

- [ ] **Step 1: 파일 작성**

Create `Barrier City/Interaction/KioskOrderView.swift`:

```swift
//
//  KioskOrderView.swift
//  Barrier City
//
//  키오스크 주문 화면. 서 있는 눈높이(1.5m)에 고정 표시되어, 앉은 휠체어 시점에서는
//  올려다보게 된다. 메뉴·결제 버튼은 앉은 리치 밖(정적 태깅)이라 탭하면 흔들림 +
//  "손이 닿지 않습니다" 토스트만 뜨고 진행이 안 된다. 하단 "직원 호출"만 누를 수 있어,
//  스스로 주문할 수 없는 장벽을 체험시킨다.
//

import SwiftUI

struct KioskOrderView: View {

    /// 메뉴 항목(상단 배치 = 리치 밖).
    private let menu = ["아메리카노", "카페라떼", "바닐라라떼", "카푸치노", "아이스티", "핫초코"]

    /// "손이 닿지 않습니다" 토스트 표시 여부.
    @State private var showUnreachable = false
    /// 흔들림 애니메이션 트리거(증가할 때마다 흔들림).
    @State private var shakeToken = 0

    var body: some View {
        // @Observable 싱글턴: body에서 읽는 staffCalled가 관찰 의존성이 된다.
        let im = InteractionModel.shared

        ZStack(alignment: .bottom) {
            VStack(spacing: 20) {
                Text(InteractionTuning.kioskTitle)
                    .font(.largeTitle).bold()

                if im.staffCalled {
                    calledView(im)
                } else {
                    orderView(im)
                }
            }
            .padding(40)
            .frame(width: 720)

            if showUnreachable {
                Text("손이 닿지 않습니다")
                    .font(.title3).bold()
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .glassBackgroundEffect()
    }

    /// 주문 화면(메뉴 그리드=리치 밖, 결제=리치 밖, 직원 호출=리치 안).
    @ViewBuilder
    private func orderView(_ im: InteractionModel) -> some View {
        // 상단 메뉴(닿지 않음)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
            ForEach(menu, id: \.self) { item in
                Button { triggerUnreachable() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill").font(.title)
                        Text(item).font(.callout)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                }
                .buttonStyle(.bordered)
            }
        }
        .modifier(ShakeEffect(shakes: CGFloat(shakeToken)))

        // 결제(닿지 않음)
        Button { triggerUnreachable() } label: {
            Text("결제하기").font(.title2)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .modifier(ShakeEffect(shakes: CGFloat(shakeToken)))

        // 직원 호출(닿음) — 앉은 사용자가 유일하게 할 수 있는 것.
        Button { im.staffCalled = true } label: {
            Label("직원 호출", systemImage: "bell.fill").font(.title3)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    /// 직원 호출 후 상태(스텁).
    @ViewBuilder
    private func calledView(_ im: InteractionModel) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("직원을 호출했습니다.\n잠시만 기다려 주세요...")
                .font(.title2).multilineTextAlignment(.center)
            Button("처음으로") { im.staffCalled = false }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 30)
    }

    /// 리치 밖 버튼 탭 반응: 흔들림 + 토스트(1.5초).
    private func triggerUnreachable() {
        withAnimation(.linear(duration: 0.4)) { shakeToken += 1 }
        withAnimation { showUnreachable = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showUnreachable = false }
        }
    }
}

/// 좌우로 짧게 흔드는 지오메트리 효과(shakes가 바뀔 때 애니메이션 구간 동안 진동).
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = sin(shakes * .pi * 4) * 8
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

#Preview(windowStyle: .automatic) {
    KioskOrderView()
        .padding()
}
```

- [ ] **Step 2: 빌드 검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`
(뷰가 아직 마운트되지 않아 화면엔 안 나오지만 컴파일됨.)

- [ ] **Step 3: 정리 후 커밋**

```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/Interaction/KioskOrderView.swift"
git commit -m "feat(kiosk): 주문 화면 뷰(메뉴·결제=리치 밖, 직원 호출=리치 안)

- 리치 밖 버튼 탭 → 흔들림 + '손이 닿지 않습니다' 토스트, 진행 불가
- 직원 호출 → 호출 상태(스텁), '처음으로'로 리셋

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: InteractionSetup — 키오스크 attachment 장착 + kind 라우팅

**Files:**
- Modify: `Barrier City/Interaction/InteractionSetup.swift`

**Interfaces:**
- Consumes: `InteractionModel`(kioskPanelEntity, staffCalled)(Task 1), attachment id `"kioskScreen"`(Task 5), `InteractionTuning.kioskScreenHeight/kioskScreenYaw`(Task 1).
- Produces: 매 프레임 kind별 패널 라우팅(문=빌보드, 키오스크=고정).

- [ ] **Step 1: install에 staffCalled 리셋 추가**

`install`의 리셋 블록:
```swift
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.isTransitioning = false
        im.transitionError = nil
```
→
```swift
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.isTransitioning = false
        im.transitionError = nil
        im.staffCalled = false
```

- [ ] **Step 2: install에 키오스크 attachment 장착**

문 패널 배치 블록:
```swift
        // 1) 패널 attachment를 worldRoot 아래에 배치(초기 숨김) — 맵과 함께 움직인다.
        if let panel = attachments.entity(for: "entryPrompt"), let worldRoot = appModel.worldRoot {
            panel.isEnabled = false
            worldRoot.addChild(panel)
            im.panelEntity = panel
        } else {
            print("⚠️ entryPrompt attachment 또는 worldRoot 없음 — 인터랙션 패널 비활성")
        }
```
→
```swift
        // 1) 패널 attachment들을 worldRoot 아래에 배치(초기 숨김) — 맵과 함께 움직인다.
        if let worldRoot = appModel.worldRoot {
            if let panel = attachments.entity(for: "entryPrompt") {
                panel.isEnabled = false
                worldRoot.addChild(panel)
                im.panelEntity = panel
            } else {
                print("⚠️ entryPrompt attachment 없음 — 문 패널 비활성")
            }
            if let kiosk = attachments.entity(for: "kioskScreen") {
                kiosk.isEnabled = false
                worldRoot.addChild(kiosk)
                im.kioskPanelEntity = kiosk
            } else {
                print("⚠️ kioskScreen attachment 없음 — 키오스크 화면 비활성")
            }
        } else {
            print("⚠️ worldRoot 없음 — 인터랙션 패널 비활성")
        }
```

- [ ] **Step 3: updatePanel을 kind 라우팅으로 교체**

`updatePanel` 함수 전체:
```swift
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
```
→
```swift
    /// 활성 트리거의 kind에 따라 알맞은 패널만 표시·배치한다.
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger

        // 문 예/아니요 패널: 눈높이 + 사용자를 향한 yaw 빌보드.
        if let entry = im.panelEntity {
            if let t = trigger, t.kind == .yesNoPrompt {
                entry.isEnabled = true
                entry.setPosition([t.center.x, InteractionTuning.panelHeight, t.center.y],
                                  relativeTo: entry.parent)
                let worldPos = entry.position(relativeTo: nil)
                let yaw = atan2(-worldPos.x, -worldPos.z)
                entry.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
            } else {
                entry.isEnabled = false
            }
        }

        // 키오스크 화면: 서 있는 눈높이 + 고정 방향(빌보드 안 함 = 높이 장벽 연출).
        // 방향은 맵 로컬(부모=worldRoot) 기준이라 키오스크에 붙박이처럼 고정된다.
        if let kiosk = im.kioskPanelEntity {
            if let t = trigger, t.kind == .kioskScreen {
                kiosk.isEnabled = true
                kiosk.setPosition([t.center.x, InteractionTuning.kioskScreenHeight, t.center.y],
                                  relativeTo: kiosk.parent)
                kiosk.setOrientation(simd_quatf(angle: InteractionTuning.kioskScreenYaw, axis: [0, 1, 0]),
                                     relativeTo: kiosk.parent)
            } else {
                kiosk.isEnabled = false
            }
        }
    }
```

- [ ] **Step 4: 빌드 검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`
(kioskScreen attachment는 Task 5에서 추가되므로 지금은 `entity(for: "kioskScreen")`가 nil → 경고 로그만. 문 인터랙션은 정상.)

- [ ] **Step 5: 정리 후 커밋**

```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/Interaction/InteractionSetup.swift"
git commit -m "feat(kiosk): InteractionSetup에 키오스크 패널 장착 + kind 라우팅

- 두 attachment(entryPrompt·kioskScreen) 배치, staffCalled 리셋
- updatePanel: 문=눈높이 빌보드, 키오스크=고정 높이·고정 방향

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: SceneSwitcher — Indoor 전환 시 키오스크 트리거 등록

**Files:**
- Modify: `Barrier City/Interaction/SceneSwitcher.swift`

**Interfaces:**
- Consumes: `ProximityTrigger(kind:)`(Task 1), `InteractionTuning.kioskTriggerRadius/kioskFallbackCenter/kioskTitle`(Task 1).
- Produces: Indoor 씬에 `kiosk.order` 트리거 등록(Kiosk 프림 위치 또는 폴백).

- [ ] **Step 1: triggers = [] 을 키오스크 트리거 등록으로 교체**

`switchToIndoor()`의 5)번 블록:
```swift
        // 5) 인터랙션 상태 전환: 실내 트리거는 1차 스코프에 없음(Kiosk는 다음 단계)
        im.scene = .indoor
        im.triggers = []
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.panelEntity?.isEnabled = false
```
→
```swift
        // 5) 인터랙션 상태 전환: 실내에는 키오스크 트리거를 등록한다.
        //    Kiosk 프림의 맵 좌표(worldRoot 기준)를 찾고, 실패 시 폴백 상수(문 DOOR1 패턴 동일).
        var kioskCenter = InteractionTuning.kioskFallbackCenter
        if let kiosk = indoorVisible.findEntity(named: "Kiosk") {
            let p = kiosk.position(relativeTo: worldRoot)
            kioskCenter = SIMD2(p.x, p.z)
            print("키오스크 트리거: Kiosk 위치 사용 (\(p.x), \(p.z))")
        } else {
            print("⚠️ Kiosk 프림을 찾지 못해 폴백 좌표 사용: \(kioskCenter)")
        }
        im.scene = .indoor
        im.triggers = [ProximityTrigger(
            id: "kiosk.order",
            center: kioskCenter,
            radius: InteractionTuning.kioskTriggerRadius,
            kind: .kioskScreen,
            prompt: InteractionTuning.kioskTitle)]
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.staffCalled = false
        im.panelEntity?.isEnabled = false
        im.kioskPanelEntity?.isEnabled = false
```

- [ ] **Step 2: 빌드 검증**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`
(키오스크 트리거가 등록되지만 attachment가 아직 없어 접근해도 화면은 안 뜬다 — Task 5에서 완성. 문 인터랙션 정상.)

- [ ] **Step 3: 정리 후 커밋**

```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/Interaction/SceneSwitcher.swift"
git commit -m "feat(kiosk): Indoor 전환 시 Kiosk 프림 위치로 키오스크 트리거 등록(폴백 포함)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: ImmersiveView attachments에 키오스크 화면 추가 (이윤서 파일 — 허용받은 3줄)

**Files:**
- Modify: `Barrier City/ImmersiveView.swift` (attachments 블록에 3줄 추가만)

**Interfaces:**
- Consumes: `KioskOrderView`(Task 2).
- Produces: `kioskScreen` attachment → InteractionSetup이 kioskPanelEntity에 저장 → 전체 기능 연결.

- [ ] **Step 1: attachments 블록에 kioskScreen 추가**

`Barrier City/ImmersiveView.swift`의 attachments 블록:
```swift
        } attachments: {
            // [김현기] 문 앞 입장 패널(공간 고정 + 빌보드는 InteractionSetup이 처리)
            Attachment(id: "entryPrompt") {
                EntryPromptView()
            }
        }
```
→
```swift
        } attachments: {
            // [김현기] 문 앞 입장 패널(공간 고정 + 빌보드는 InteractionSetup이 처리)
            Attachment(id: "entryPrompt") {
                EntryPromptView()
            }
            // [김현기] 키오스크 주문 화면(고정 높이 장벽은 InteractionSetup이 처리)
            Attachment(id: "kioskScreen") {
                KioskOrderView()
            }
        }
```

- [ ] **Step 2: 변경 범위 확인 + 빌드**

`git diff --stat "Barrier City/ImmersiveView.swift"` → attachments 블록만 변경(약 +4줄)인지 확인.
그다음 Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 정리 후 커밋**

```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/ImmersiveView.swift"
git commit -m "feat(kiosk): ImmersiveView attachments에 키오스크 주문 화면 연결

- 허용받은 편집 범위(attachments 블록 3줄 추가)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: 시뮬레이터 수동 검증 + 튜닝 (Wade 수행, Claude가 상수 반영)

**Files:**
- Modify: `Barrier City/Interaction/InteractionModel.swift` (InteractionTuning 키오스크 상수만)

**Interfaces:**
- Consumes: Task 5까지의 전체 기능.

- [ ] **Step 1: 수동 검증 시나리오 (Xcode 시뮬레이터)**

1. Outdoor → 문 접근 → 예 → Indoor 진입.
2. 콘솔에서 `키오스크 트리거: Kiosk 위치 사용 (x, z)` 로그 확인(폴백 경고가 뜨면 좌표 기록).
3. 조이스틱으로 키오스크 접근(2.0m) → 주문 화면 표시. **높이가 올려다보이는지**, **화면 방향이 정면으로 보이는지**(키오스크 앞에 섰을 때) 확인.
4. 메뉴 항목·"결제하기" 탭 → 흔들림 + "손이 닿지 않습니다" 토스트, 진행 안 됨 확인.
5. "직원 호출" → 호출 상태 화면 전환. 멀어졌다 재접근해도 문제없는지, "처음으로"로 복귀되는지 확인.
6. 키오스크에서 멀어지면 화면 숨김, 재접근 재표시.
7. 문 인터랙션(회귀): 문 접근 패널·전환이 그대로 동작하는지 확인.

- [ ] **Step 2: 발견값 반영**

- 화면이 옆으로 틀어져 보이면 `kioskScreenYaw`를 90°(`Float.pi/2`)·180°(`.pi`) 등으로 조정.
- 트리거 위치가 카운터/키오스크와 어긋나거나 폴백이 쓰였으면 `kioskFallbackCenter`/`kioskTriggerRadius` 조정.
- 화면 높이가 어색하면 `kioskScreenHeight` 조정.

- [ ] **Step 3: 빌드 재검증 + 정리 후 커밋**

Global Constraints의 빌드 명령 실행. Expected: `** BUILD SUCCEEDED **`
```bash
git restore "Barrier City.xcodeproj/project.pbxproj"; rm -f "Packages/RealityKitContent/Package.realitycomposerpro/WorkspaceData/hyeongikim.rcuserdata"
git add "Barrier City/Interaction/InteractionModel.swift"
git commit -m "chore(kiosk): 시뮬레이터 실측 튜닝(화면 방향·높이·트리거 위치)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 실행 후 다음 단계 (이 계획 범위 밖)

1. "직원 호출" → AI 직원(NPC) 대화 연계(NPCDialogueController, 시뮬레이터는 파일 기반 STT)
2. 직원 통한 주문 성공 → 음료 수령 → 퀘스트 완료 흐름
3. 키오스크 화면 비주얼 폴리시(텍스처·브랜딩), 효과음
4. Indoor 벽 콜리전(김선환, `collision` 네이밍)
