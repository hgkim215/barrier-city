# 퀘스트 가이드 HUD 설계 스펙

날짜: 2026-07-13
브랜치: `feature/quest-hud` (kimhg 기준)
작성: Wade (김현기) + Claude

## 목적

첫 체험 유저는 시작 방법과 목표를 모른다. 게임 퀘스트 알림처럼 특정 트리거
달성 시 사용자 옆에 가이드 패널이 떠서 "지금 무엇을 해야 하는지"를 안내한다.
성격은 **알림 + 상시 목표** 결합형: 새 목표가 알림처럼 등장한 뒤, 현재 목표가
시야 근처에 계속 떠 있다.

## 배경 지식 (구현자 필독)

- 이 앱은 world-inverse 이동: 사용자 카메라는 항상 씬 원점 근처, 조이스틱/손
  입력은 worldRoot(시각 맵)를 역변환으로 움직인다. 플레이어 맵 좌표는
  `AppModel.current`의 `posX`/`posZ`.
- 근접 인터랙션(문·키오스크)은 `InteractionModel`(@Observable 싱글턴) +
  `InteractionSetup.install()`(설치 훅) + SceneEvents.Update 구독(tick) 패턴.
  퀘스트도 같은 패턴을 따른다.
- 실기기 입력은 손으로 휠 림을 잡고 미는 방식(HandTrackingManager)이므로
  **퀘스트 문구는 실기기 흐름 기준**으로 쓴다. 시뮬레이터 테스트는 조이스틱을
  쓰지만 완료 판정은 입력 방식과 무관한 이벤트라 동일하게 동작한다.
- 제약: 실기기 없음. 모든 기능은 visionOS 시뮬레이터에서 검증 가능해야 한다.

## 팀 코드 수정 경계 (하드 제약)

이윤서 파일 수정은 **딱 1줄, 사전 허락 완료**:

- `Barrier City/ImmersiveView.swift` attachments 블록에
  `Attachment(id: "questHUD") { QuestHUDView() }` 추가.

그 외 이윤서 파일(AppModel, HandTrackingManager, ControlPanelView,
WheelchairMovementSystem, Dialogue/*)은 읽기만 하고 수정하지 않는다.
NPC 대화 완료 연결(`.npcHelpDone` 발행)은 NPC가 몰입 씬에 배치되는 미래
작업에서 별도 허락 후 진행한다 — 이번 스코프에서는 이벤트 정의만 한다.

## 파일 구성 (모두 새 파일, `Barrier City/Quest/`)

폴더 자동 동기화(PBXFileSystemSynchronizedRootGroup)라 pbxproj 수정 불필요.

| 파일 | 책임 |
|---|---|
| `QuestModel.swift` | @Observable @MainActor 싱글턴. 단계 목록·현재 단계 인덱스·완료 이벤트 API(`advance(on:)`)·전이 판정 순수 로직 |
| `QuestHUDView.swift` | SwiftUI 패널. 상시 목표 카드 + 새 목표 등장/완료 트랜지션 |
| `QuestHUDFollower.swift` | lazy-follow. 자체 ARKitSession + WorldTrackingProvider로 head 포즈 조회, 매 프레임 패널 스무딩 이동. 폴백 고정 배치 포함 |
| `QuestSetup.swift` | 설치 훅. attachment를 씬 루트에 장착, follower 시작, 초기 퀘스트 등록, 자체 SceneEvents.Update 구독 |

설치 호출: 기존 `InteractionSetup.install()`(Wade 파일) 끝에서
`QuestSetup.install(content:attachments:appModel:)` 호출.

## 퀘스트 데이터 모델

```swift
enum QuestEvent {
    case enteredIndoor    // SceneSwitcher.switchToIndoor 성공 시 발행
    case kioskFailed      // KioskOrderView "키오스크 사용하기" 버튼 → 장벽 안내 시 발행
    case npcHelpDone      // 정의만. 발행처는 NPC 씬 배치 후 연결(미래 작업)
}

struct QuestStep: Identifiable, Equatable {
    let id: String            // 예: "quest.reachCafe"
    let title: String         // 목표(행동) 한 줄
    let detail: String        // 보조 설명(방법) 한 줄
    let completionEvent: QuestEvent
}
```

### 퀘스트 시퀀스 (고정 3단계)

| # | id | title | detail | completionEvent |
|---|---|---|---|---|
| 1 | `quest.reachCafe` | 카페 입구로 이동하세요 | 양손으로 바퀴를 잡고 앞으로 밀면 휠체어가 움직입니다 | `.enteredIndoor` |
| 2 | `quest.tryKiosk` | 키오스크에서 주문을 시도해 보세요 | 키오스크에 가까이 다가가면 화면이 나타납니다 | `.kioskFailed` |
| 3 | `quest.askStaff` | 직원에게 도움을 요청하세요 | 키오스크가 너무 높아 혼자서는 주문할 수 없습니다 | `.npcHelpDone` |

3단계는 완료 이벤트가 이번 스코프에서 발행되지 않으므로 체험 끝까지 목표로
남는다(의도된 동작).

### 진행 규칙

- `advance(on event: QuestEvent)`: 현재 단계의 completionEvent와 일치할 때만
  다음 단계로 진행. 불일치 이벤트는 무시(중복 발행·순서 꼬임에 안전).
- 완료 연출을 위해 "방금 완료된 단계"를 잠깐 유지하는 상태를 둔다:
  완료 시 `justCompletedStep`에 저장 → 1.5초 후 nil로 리셋하고 다음 단계 표시.
- 몰입 공간 재진입 시(`QuestSetup.install`) 1단계로 전체 리셋
  (InteractionModel과 동일한 싱글턴 리셋 패턴).

## HUD 패널 UI (QuestHUDView)

- 유리 배경(`glassBackgroundEffect`), 폭 약 420pt의 컴팩트 카드.
- 평상시: 「목표」 라벨 + title(볼드) + detail(보조 색).
- 완료 순간(justCompletedStep 표시 중): 체크마크 + "완료!" 강조.
- 새 목표 등장: "새 목표" 배지와 함께 스케일+페이드 트랜지션.
- 3단계까지 완료 이벤트가 없으므로 종료 상태 UI는 이번 스코프에 없음.

## lazy-follow 동작 (QuestHUDFollower)

- **타깃 포즈**: head 위치 + head yaw 방향(pitch/roll 무시) 앞 1.2m,
  왼쪽 0.35m, 세로 -0.15m(눈높이보다 살짝 아래).
- **데드존**: head 기준 「head→현재 패널」과 「head→타깃」 두 수평 방향의
  사잇각 15° 이내 & 패널-타깃 거리 0.2m 이내면 정지.
- **스무딩**: 데드존을 벗어나면 지수 스무딩(수렴 속도 초당 약 4배,
  `1 - exp(-4 * dt)` 보간)으로 타깃을 향해 이동. 도착 판정 후 정지.
- **빌보드**: 항상 head 위치를 향해 yaw 회전(pitch 없음).
- **head 포즈 취득**: 자체 `ARKitSession` + `WorldTrackingProvider`,
  `queryDeviceAnchor(atTimestamp:)`. HandTrackingManager(이윤서 파일)의
  세션과는 독립 — 한 앱에서 세션 여러 개 허용.
- **갱신 주기**: QuestSetup이 등록하는 자체 SceneEvents.Update 구독에서
  매 프레임 갱신. InteractionSetup의 tick과 분리(책임 분리).
- **패널 부모**: worldRoot가 아닌 **씬 루트**(content에 직접 add).
  맵과 함께 움직이면 안 되는 HUD이기 때문.

## 폴백 & 에러 처리

- `WorldTrackingProvider.isSupported == false`이거나 `session.run()` 실패,
  또는 DeviceAnchor가 계속 nil이면 → **원점 기준 고정 배치**
  (x -0.35, y 1.4, z -1.2)로 폴백. HUD는 어떤 경우에도 표시된다.
- 가드 패턴은 HandTrackingManager의 `isSupported` 선체크 방식을 따른다
  (미지원 기기에서 run() 호출로 인한 강제종료 방지).
- attachment(`questHUD`)를 못 찾으면 경고 로그 후 HUD 비활성
  (InteractionSetup의 entryPrompt 패턴과 동일).

## 튜닝 상수 단일 진실원

`QuestTuning` enum에 모아 시뮬레이터에서 보며 조정:
forwardDistance 1.2, lateralOffset -0.35, verticalOffset -0.15,
deadZoneAngle 15°, deadZoneDistance 0.2, smoothingRate 4.0,
completedHoldSeconds 1.5, fallbackPosition (-0.35, 1.4, -1.2).

## 테스트 계획

시뮬레이터 수동 검증 시나리오:

1. 체험 시작 → HUD에 1단계(카페 입구로 이동) 표시.
2. 카메라 드래그로 시야 회전 → 패널이 데드존 밖에서 부드럽게 따라옴
   (DeviceAnchor 미동작 시 폴백 고정 배치 확인).
3. 문 접근 → "예" → 실내 진입 → "완료!" 연출 후 2단계(키오스크 주문 시도)로 전환.
4. 키오스크 접근 → "키오스크 사용하기" → 장벽 안내와 동시에 3단계(직원에게
   도움 요청)로 전환.
5. 체험 종료 후 재진입 → 1단계로 리셋(재진입 버그 회귀 확인).
6. 기존 문·키오스크 인터랙션 회귀 확인.

`QuestModel.advance(on:)`의 전이 판정은 순수 로직으로 작성해 테스트 타깃이
생기면 단위 테스트를 붙일 수 있게 한다(InteractionModel.evaluate 패턴).

## 빌드 검증 (필수 절차)

```
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

빌드 후 반드시: ① `git restore "Barrier City.xcodeproj/project.pbxproj"`
(DEVELOPMENT_TEAM 자동 변경 원복 — 팀원 서명 설정) ② 생성된
`hyeongikim.rcuserdata` 삭제.

## 스코프 밖 (명시)

- NPC 씬 배치 및 `.npcHelpDone` 발행 연결
- 사운드/햅틱 알림
- 퀘스트 로그(지난 목표 목록) UI
- 실기기 head 앵커 검증 (시뮬레이터 우선 제약)
