# 공간 인터랙션 UI 설계 (feature/spatial-interaction)

- 날짜: 2026-07-12
- 작성: Wade(김현기) + Claude
- 브랜치: `feature/spatial-interaction` (kimhg 기반)
- 상태: 설계 승인됨 → 구현 계획(writing-plans) 진행

## 1. 배경과 목적

게임 흐름은 **Outdoor에서 Indoor로 들어가는** 구조다. 사용자가 Outdoor에서 카페 문 앞에 다가가면 시야의 문 앞 공간에 "안으로 입장하시겠습니까?" 패널(예/아니요)이 뜨고, "예"를 누르면 배경이 Indoor로 바뀌며 실내 문 앞 위치에 스폰된다(밖에서 문을 열고 들어온 것으로 가정). 이후 Indoor의 Kiosk 앞에서도 같은 방식의 인터랙션이 붙을 예정이므로, **트리거·패널 구조는 제네릭하게** 만들되 1차 스코프는 Outdoor→Indoor 전환만 구현한다.

## 2. 스코프

**포함:**
- 근접 트리거 시스템(진입 시 패널 표시, 이탈 시 숨김, 재접근 시 재표시)
- 문 앞 공간 고정(빌보드) 예/아니요 패널 — RealityKit `RealityView` attachments
- "예" → 씬 전환: 시각 맵 교체(Map→Indoor) + 콜리전 사본 교체 + 실내 문 앞 포즈로 리셋
- Indoor 검정 벽 임시 보정(코드에서 기본 머티리얼 덮어쓰기)
- 트리거 판정·스폰 계산 순수 로직 단위 테스트

**제외 (이후 단계):**
- Kiosk 인터랙션(트리거 하나 더 등록하면 되는 구조만 대비)
- Indoor→Outdoor 역방향(나가기)
- 실내 벽 콜리전(김선환 RCP 작업 몫 — 현재는 실내 벽 통과 허용)
- 문 열림 애니메이션, 사운드

## 3. 확정된 결정

| 결정 | 내용 |
|---|---|
| Indoor 맵 | 김선환 프로토타입 `Indoor.usda` 그대로 사용. 검정 벽만 코드에서 임시 보정 |
| 패널 배치 | 문 앞 공중(눈높이)에 공간 고정 + 사용자 방향 빌보드 |
| 아니요/이탈 | 패널 닫힘. 트리거 범위 재진입 시 재표시 |
| 씬 전환 방식 | 같은 ImmersiveSpace 유지, worldRoot 내용만 교체(접근 A). 몰입 공간 교체(B)는 깜빡임·오디오 이슈 재발 위험으로 기각 |
| **이윤서 파일 수정** | **`ImmersiveView.swift` 수정 허용받음(이번 작업 한정)** — RealityView `attachments:` 파라미터 추가 + 셋업 훅 호출. AppModel·WheelchairMovementSystem·ControlPanelView는 무수정 |

## 4. 현재 구조 (관련 사실)

- `ImmersiveView`(이윤서)는 `"Map"` 씬을 두 번 로드: worldRoot 아래 시각용 + 씬 원점 고정 투명 콜리전 사본(이름에 `collision` 포함 메시에만 static mesh 콜리전, `groundGroup`).
- 플레이어 포즈는 `AppModel.posX/posZ/heading`(맵 좌표). `WheelchairMovementSystem`이 매 프레임 콜리전 사본에 레이캐스트하고 worldRoot를 포즈의 역변환으로 배치.
- Map의 `_coffee` 건물은 맵 좌표 `(0, 0.3, 20)`에 배치, 내부에 `DOOR1`/`DOOR2`/`Door1Window` 프림 존재 → 문 위치는 `findEntity`로 런타임 조회 가능.
- `debugFloorCollision`(16×16m, y=-0.1)이 씬에 상주 → Indoor에 콜리전 메시가 없어도 바닥 주행은 동작.
- Indoor.usda: 16×12m, 바닥/벽4/천장/바 카운터+키오스크. `wall` 머티리얼에 diffuseColor가 없어 검정 렌더 이슈.

## 5. 컴포넌트 설계

새 파일은 전부 `Barrier City/Interaction/` 폴더(폴더 자동 동기화 → pbxproj 수정 불필요), 제(김현기) 소유.

### 5.1 `InteractionModel.swift` — 상태 단일 진실원 (@Observable, @MainActor)
- `enum GameScene { case outdoor, indoor }` / `var scene: GameScene = .outdoor`
- `struct ProximityTrigger`: id, 중심(맵 좌표 SIMD2), 반경, 패널 문구, 확인/취소 라벨. **순수 값 타입**(테스트 대상).
- `var activeTrigger: ProximityTrigger?` — 표시 중인 패널의 트리거(nil=숨김)
- `var dismissedTriggerID: String?` — "아니요"/이탈로 닫힌 트리거(범위 이탈 시 해제 → 재접근 재표시)
- `var isTransitioning: Bool` — 전환 중 중복 클릭 방지
- `static var current: InteractionModel?` — System이 읽는 전역(이윤서 AppModel.current와 같은 패턴)
- 순수 판정 함수 `nonisolated static func evaluate(playerX:playerZ:triggers:activeID:dismissedID:) -> (show: String?, clearDismissed: Bool)` — 진입/이탈/재접근 히스테리시스 로직. 단위 테스트 대상.

### 5.2 `ProximityInteractionSystem.swift` — RealityKit System
- 매 프레임: `AppModel.current`의 `(posX, posZ)` + `InteractionModel.current`의 트리거들로 `evaluate` 호출 → `activeTrigger` 갱신.
- 패널 엔티티(attachment) 위치·자세 갱신: 트리거 중심 위 눈높이(y≈1.3m, 맵 좌표) → worldRoot 자식이므로 맵과 함께 움직임. 빌보드: 사용자(원점 부근)를 바라보도록 yaw 회전.
- 등록은 `InteractionModel.init`에서 `registerSystem()` (이윤서 패턴 동일).

### 5.3 `EntryPromptView.swift` — 패널 SwiftUI 뷰
- 문구 + [예] [아니요] 버튼, `glassBackgroundEffect`. 폭 ~360pt.
- 예 → `SceneSwitcher.switchToIndoor()` 호출(전환 중 비활성화), 아니요 → `dismissedTriggerID` 설정.

### 5.4 `SceneSwitcher.swift` — 씬 전환
`@MainActor` 유틸. ImmersiveView make 훅에서 참조(worldRoot의 시각 맵 엔티티, 콜리전 사본 엔티티)를 등록받는다.
`switchToIndoor()` 순서:
1. `isTransitioning = true`
2. `"Indoor"` 씬 로드(시각용) — 실패 시 전환 취소, Outdoor 유지, 패널에 "지금은 들어갈 수 없어요" 문구
3. `stripPhysics` + **검정 벽 보정**: diffuse 미지정 UsdPreviewSurface 메시에 `SimpleMaterial(밝은 회색)` 덮어쓰기
4. worldRoot에서 기존 시각 맵 제거 → Indoor 추가
5. 콜리전 사본 제거 → Indoor 콜리전 사본 추가(이윤서 `addStaticCollision` 재사용 — 콜리전 메시 없으면 0개, debugFloor가 바닥 담당)
6. 포즈 리셋: `AppModel.restart()` 후 `posX/posZ/heading = 실내 스폰 상수` (`InteractionTuning.indoorSpawn*`, 실내 문 앞·카운터를 바라보는 방향. 시뮬레이터에서 튜닝)
7. `scene = .indoor`, 트리거 목록을 Indoor용으로 교체(1차엔 빈 목록), `isTransitioning = false`

### 5.5 트리거 정의 (Outdoor)
- 문 트리거 중심: 로드된 맵에서 `findEntity(named: "DOOR1")`의 맵 좌표(x, z). 실패 시 폴백 상수(건물 배치 (0,0.3,20) 기준 문 앞 좌표, 시뮬레이터에서 확정).
- 반경: 2.5m(튜닝 상수). 문구: "안으로 입장하시겠습니까?" / 예 / 아니요.

### 5.6 `ImmersiveView.swift` 수정 (이윤서 파일 — 허용받음, 최소 침습)
1. `RealityView { content in ... } update: { ... }` → `RealityView { content, attachments in ... } update: { content, attachments in ... } attachments: { Attachment(id: "entryPrompt") { EntryPromptView() } }`
2. make 클로저 끝에 훅 4~6줄: attachment 엔티티를 worldRoot에 추가(초기 숨김), `SceneSwitcher`/`InteractionModel`에 참조 등록.
3. 그 외 이윤서 로직(휠체어·조명·콜리전 빌드)은 그대로.

## 6. 데이터 흐름

```
매 프레임: ProximityInteractionSystem
  (posX,posZ) + triggers → evaluate() → activeTrigger 갱신 → 패널 show/hide·빌보드
사용자: [예] 클릭 → SceneSwitcher.switchToIndoor() → 맵·콜리전 교체 + 포즈 리셋 + scene=.indoor
사용자: [아니요] 클릭 → dismissedTriggerID 설정 → 패널 숨김 (범위 이탈 시 해제)
```

## 7. 에러 처리

| 상황 | 처리 |
|---|---|
| Indoor 로드 실패 | 전환 취소, Outdoor 유지, 패널에 실패 안내 문구 |
| DOOR1 못 찾음 | 폴백 좌표 상수 사용 + 콘솔 경고 |
| 전환 중 재클릭 | `isTransitioning`으로 버튼 비활성화 |
| AppModel/InteractionModel nil 프레임 | 해당 프레임 스킵 |

## 8. 테스트

- **자동 테스트는 이번 스코프에서 제외** — 프로젝트에 테스트 타깃이 없고, pbxproj 수동 편집으로 타깃을 새로 추가하는 것은 이 기능 대비 과대하다. 대신 `evaluate`는 nonisolated 순수 함수로 유지해(입력→출력만) 향후 테스트 타깃이 생기면 바로 테스트를 붙일 수 있게 한다. 로직 검증은 아래 수동 시나리오와 코드 리뷰로 커버.
- **수동 검증**(시뮬레이터): 조이스틱으로 문 접근 → 패널 표시(문 앞 고정·빌보드) → 멀어지면 숨김 → 재접근 재표시 → 아니요=닫힘 → 예=Indoor 전환 + 실내 문 앞 스폰 + 주행 정상.

## 9. 이후 단계 (스코프 밖)

1. Kiosk 트리거 등록(Indoor 트리거 목록에 추가) + 키오스크 대화/주문 UI
2. Indoor→Outdoor 나가기 트리거
3. 실내 벽 콜리전(김선환, `collision` 네이밍)
4. 문 열림 연출·사운드
