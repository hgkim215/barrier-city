# 온보딩 가이드 및 Mission HUD 개선 설계

날짜: 2026-08-07

브랜치: `codex/onboarding-guide-redesign`

대상: visionOS `Barrier City` 몰입 체험

디자인 기준: [Figma Map 복사본](https://www.figma.com/design/Hl56XSp23HYGlBXGEOgCv5/Map--%EB%B3%B5%EC%82%AC-?node-id=0-1)

## 1. 목적

현재 `QuestHUDView`는 사용자의 머리를 따라다니며 현재 미션 한 개와 짧은 완료 연출만 표시한다. 첫 사용자는 체험의 목적, 휠체어 조작법, 전체 진행 맥락을 충분히 이해하기 어렵다.

이번 작업은 Figma의 온보딩 및 Mission List 시안을 현재 체험 흐름에 맞게 적용한다.

- 몰입 체험 시작 시 소개 1화면과 조작 가이드 3화면을 제공한다.
- 조작 가이드에는 추후 실제 플레이 루프 영상을 넣을 수 있는 미디어 슬롯을 둔다.
- 미션 시작마다 중앙 안내 카드를 표시하고 사용자가 확인한 뒤 체험을 재개한다.
- 체험 중에는 완료한 미션과 현재 미션을 누적한 Mission List가 시야 좌측 상단을 따라다닌다.
- 모든 안내 모달이 열린 동안 이동과 공간 상호작용을 안전하게 잠근다.
- 기존 3단계 미션 및 완료 이벤트는 보존한다.

## 2. 확정된 제품 규칙

### 2.1 노출 및 건너뛰기

- 몰입 공간에 진입할 때마다 온보딩을 처음부터 표시한다.
- 소개 화면과 Guide 1~3에는 항상 `건너뛰기`를 제공한다.
- 건너뛰면 조작 가이드를 종료하고 `Mission 1` 중앙 안내 카드로 이동한다.
- 몰입 공간을 나갔다가 다시 들어오면 온보딩과 미션을 모두 초기화한다.

### 2.2 조작 잠금

다음 상태에서는 휠체어 이동과 문·키오스크·NPC 공간 상호작용을 잠근다.

- 체험 소개
- Guide 1~3
- 각 Mission 시작 안내
- 최종 체험 완료 안내

Mission List가 보이는 실제 미션 진행 상태와 최종 완료 확인 이후에는 잠금을 해제한다.

### 2.3 미션 시퀀스

기존 세 단계를 유지한다.

| 순서 | 미션 | 완료 이벤트 |
|---|---|---|
| 1 | 카페 입구로 이동해 카페 안으로 진입하기 | `.enteredIndoor` |
| 2 | 키오스크로 이동해 주문을 시도하기 | `.kioskFailed` |
| 3 | 직원에게 도움을 요청하기 | `.npcHelpDone` |

새 미션은 중앙 `Mission` 카드로 먼저 안내한다. 사용자가 `확인`을 누르면 카드가 사라지고 Mission List가 나타나며 체험 입력이 활성화된다.

마지막 미션 완료 시 중앙 `체험 완료` 카드를 표시한다. 사용자가 확인한 뒤에는 세 항목이 모두 `Clear`인 Mission List를 유지하고 체험 입력을 다시 활성화한다.

## 3. 상태 흐름

`GuideFlowModel`이 화면 상태와 잠금 상태를 관리한다.

```swift
enum GuidePhase: Equatable {
    case introduction
    case tutorial(index: Int)
    case missionAnnouncement(index: Int)
    case missionActive(index: Int)
    case completionAnnouncement
    case completed
}
```

정상 흐름은 다음과 같다.

```text
몰입 공간 진입
  → introduction [잠금]
  → tutorial 0...2 [잠금]
  → missionAnnouncement 0 [잠금]
  → missionActive 0 [해제]
  → 이벤트 .enteredIndoor
  → missionAnnouncement 1 [잠금]
  → missionActive 1 [해제]
  → 이벤트 .kioskFailed
  → missionAnnouncement 2 [잠금]
  → missionActive 2 [해제]
  → 이벤트 .npcHelpDone
  → completionAnnouncement [잠금]
  → completed [해제, 모든 미션 Clear]
```

건너뛰기는 `introduction` 또는 모든 `tutorial` 상태에서 `missionAnnouncement(0)`으로 전환한다.

## 4. 책임 분리

### 4.1 `GuideFlowModel`

새 `@Observable @MainActor` 모델이다.

- 현재 `GuidePhase`
- 현재 가이드 페이지와 미션 안내 상태
- `isInteractionLocked`
- 안내 패널 배치 모드(`centerModal`, `upperLeadingHUD`)
- 소개 확인, 이전·다음, 건너뛰기, 미션 확인, 최종 완료 확인 API
- 미션 이벤트 수신 및 `QuestModel`과의 조정
- 몰입 공간 재진입 초기화

화면 전환이 잠금 상태로 들어갈 때 입력과 속도를 즉시 중립화한다. 모델은 `AppModel`의 구체적인 물리 계산을 직접 수행하지 않고 명시적인 입력 초기화 API를 호출한다.

### 4.2 `QuestModel`

기존 세 미션과 순서 검증을 유지한다. `advance(on:)`은 화면을 직접 바꾸지 않고 진행 결과를 반환한다.

```swift
enum QuestAdvanceOutcome: Equatable {
    case ignored
    case advanced(completed: QuestStep, next: QuestStep?)
}
```

`GuideFlowModel.handleQuestEvent(_:)`가 이 결과를 받아 다음 Mission 안내 또는 최종 완료 안내로 전환한다. 문 진입, 키오스크 실패, NPC 도움 완료의 기존 발행 지점은 `QuestModel`을 직접 호출하지 않고 `GuideFlowModel`의 단일 진입점을 호출한다.

### 4.3 `ExperienceGuideView`

현재 `QuestHUDView`의 역할을 대체한다. 하나의 attachment 안에서 현재 단계에 맞는 내용을 렌더링한다.

- `IntroductionCardView`
- `TutorialGuideView`
- `MissionAnnouncementView`
- `MissionListView`
- `ExperienceCompletionView`

세부 뷰는 표시만 담당하고 상태 변경은 `GuideFlowModel`의 명시적 메서드를 호출한다. 기존 attachment ID `questHUD`는 유지해 RealityKit 연결 변경을 최소화한다.

### 4.4 `QuestHUDFollower`

헤드 포즈 조회와 패널 위치 갱신만 담당한다.

- 중앙 모달: head 정면 약 1.2m, 눈높이보다 약간 아래
- Mission List: head 정면 약 1.2m, 좌측 약 0.4m, 위쪽 약 0.2m
- 배치 모드가 바뀌면 기존 위치에서 길게 이동시키지 않고, 콘텐츠를 숨긴 상태에서 새 목표 위치로 즉시 재배치한 뒤 페이드 인한다.
- WorldTracking 실패 시 각 모드에 대응하는 고정 위치 폴백을 사용한다.

정확한 거리와 오프셋은 `QuestTuning`에 모아 visionOS Simulator에서 조정한다.

### 4.5 입력 및 상호작용 잠금

`GuideFlowModel.isInteractionLocked`를 단일 잠금 신호로 사용한다.

- `WheelchairMovementSystem`은 잠금 상태에서 새 이동 계산을 수행하지 않는다.
- 잠금 진입 시 좌우 속도, 대기 중인 충격량, 브레이크, 손 속도, 잡힘 상태, 테스트 주먹 조작 목표를 중립화한다.
- 잠금 해제 후에는 잠금 전에 들어온 입력을 재사용하지 않고 새로운 손 입력부터 반영한다.
- `InteractionSetup.tick`은 잠금 중 문·키오스크·NPC 근접 판정을 진행하지 않고, 이미 표시 중인 공간 패널을 숨긴다.
- 잠금 전환은 다음 RealityKit 프레임을 기다리지 않고 즉시 입력 초기화 API를 호출해 관성 이동을 멈춘다.

## 5. 화면 설계

### 5.1 공통 시각 언어

- visionOS `glassBackgroundEffect`를 기본 재질로 사용한다.
- Figma의 청록색을 브랜드 배지, 현재 `Progress`, 주요 포커스에만 사용한다.
- 본문은 실제 헤드셋 거리에서 읽히도록 Figma보다 대비를 높이고 최소 `.callout` 크기를 유지한다.
- 버튼 높이는 약 52pt를 기준으로 충분한 응시·탭 영역을 확보한다.
- 카드 등장은 짧은 scale + opacity를 사용한다.
- 중앙 카드와 Mission List 사이의 큰 공간 이동 애니메이션은 사용하지 않는다.
- Reduce Motion 환경에서는 scale을 제거하고 opacity 전환만 사용한다.

### 5.2 소개 화면

- 중앙 약 760pt 폭의 glass 카드
- 상단 `Barrier City` 청록색 배지
- 제목: `휠체어 체험을 시작합니다.`
- 체험 목적을 설명하는 2줄 본문
- 하단 `확인` 버튼
- 우측 상단 `건너뛰기`

### 5.3 Guide 1~3

- 중앙 약 760×396pt의 2열 glass 카드
- 좌측: 16:9에 가까운 루프 영상 영역
- 우측: `Guide n / 3` 배지, 제목, 설명, 이전·다음 버튼
- Guide 3의 다음 버튼은 `시작하기`로 표시
- 모든 페이지 우측 상단에 `건너뛰기`

가이드 문구는 다음과 같다.

| 단계 | 제목 | 설명 |
|---|---|---|
| 1 | 바퀴 조작하기 | 바퀴를 잡으면 파란색으로 표시됩니다. 손을 앞뒤로 움직여 바퀴를 회전시켜 보세요. |
| 2 | 방향 전환하기 | 한쪽 바퀴를 움직여 원하는 방향으로 회전할 수 있습니다. |
| 3 | 직진·후진하기 | 양쪽 바퀴를 같은 방향으로 움직이면 앞으로 또는 뒤로 이동할 수 있습니다. |

### 5.4 미션 시작 안내

- 중앙 glass 카드
- `Mission` 청록색 배지
- 미션의 상황 설명과 사용자가 수행할 행동
- 하단 `확인` 버튼
- 확인 전까지 입력 잠금

미션 1과 2는 Figma의 내러티브 문구를 현재 실제 동작에 맞게 사용한다. 미션 3은 키오스크 장벽을 경험한 뒤 직원에게 직접 도움을 요청하는 행동을 안내한다.

| 미션 | 상황 문구 | 행동 문구 |
|---|---|---|
| 1 | 음료 한 잔이 마시고 싶다. 앞에 보이는 카페로 들어가자. | 휠체어를 이동하여 카페 입구로 이동하세요. |
| 2 | 이번에 신상으로 나온 ‘레인보우 마카롱 스무디’가 마시고 싶다. | 키오스크에서 음료 주문을 시도해 보세요. |
| 3 | 키오스크 화면이 너무 높아 혼자 주문하기 어렵다. | 직원에게 직접 도움을 요청해 보세요. |

최종 카드는 제목 `Barrier City 체험을 완료했습니다.`와 본문 `접근하기 어려운 공간과 서비스가 일상에 어떤 장벽이 되는지 돌아보세요.`를 표시한다.

### 5.5 Mission List

- 약 400pt 폭, 내용에 따라 세로 크기 증가
- 시야 좌측 상단 lazy-follow
- 완료된 미션과 현재 미션만 누적 표시
- 완료 항목: 중립색 `Clear`
- 현재 항목: 청록색 `Progress`
- 미래 미션은 미리 표시하지 않음
- 최종 완료 확인 이후 세 항목 모두 `Clear`

## 6. 영상 슬롯과 더미 자산

각 가이드 단계는 미래의 실제 영상 파일명을 가진다.

```text
guide-wheel-control
guide-turning
guide-straight-drive
```

`LoopingGuideVideoView`는 다음 순서로 자산을 찾는다.

1. 단계별 실제 영상
2. 공통 `onboarding-placeholder` 더미 영상
3. `영상 준비 중` 정적 대체 화면

초기 구현에는 4초 길이, 1280×720, H.264, 무음인 `onboarding-placeholder.mp4`를 번들에 포함하고 세 단계가 공통으로 사용한다. 화면에는 짙은 중립 배경 위에 청록색 진행 도형과 `Guide video placeholder` 문구를 넣어 실제 영상과 혼동되지 않게 한다. `AVQueuePlayer`와 `AVPlayerLooper`로 컨트롤 없이 자동 반복한다. 페이지가 사라지거나 몰입 공간을 종료하면 플레이어와 looper 참조를 정리한다.

이 구조로 실제 영상이 준비되면 약속된 파일명으로 자산만 추가해 단계별 영상으로 자동 교체할 수 있다.

## 7. 오류 및 예외 처리

| 상황 | 동작 |
|---|---|
| 단계별 영상 없음 | 공통 더미 영상을 사용 |
| 더미 영상도 로드 실패 | 정적 `영상 준비 중` 화면을 표시하고 탐색은 계속 허용 |
| WorldTracking 미지원 또는 DeviceAnchor 없음 | 배치 모드별 고정 위치 폴백 사용 |
| `questHUD` attachment 생성 실패 | 오류 로그 후 안내 흐름을 fail-open 처리해 이동 잠금을 해제 |
| 순서가 맞지 않거나 중복된 Quest 이벤트 | `QuestAdvanceOutcome.ignored`, 화면 상태 유지 |
| 잠금 중 Quest 이벤트 유입 | 무시하고 현재 안내 상태 유지 |
| 몰입 공간 재진입 | Quest, Guide, 영상, follower 상태를 모두 초기화 |

오류 때문에 사용자가 영구적으로 움직일 수 없는 상태가 생기지 않는 것을 최우선으로 한다.

## 8. 검증 계획

### 8.1 SwiftUI Preview

- 소개 화면
- Guide 1, 2, 3
- 미션 시작 카드
- Mission List: 첫 단계, 2단계 진행, 3단계 진행, 전체 Clear
- 영상 로드 실패 정적 폴백
- 체험 완료 카드

### 8.2 visionOS Simulator 수동 시나리오

1. 체험 시작 시 소개 카드 표시 및 이동 잠금 확인
2. Guide 1~3 이전·다음 이동, 더미 영상 반복·음소거 확인
3. 소개와 각 Guide 화면에서 건너뛰기 → Mission 1 안내 확인
4. Mission 1 확인 전 이동·문 상호작용 불가 확인
5. Mission 1 확인 후 Mission List 표시와 이동 활성화 확인
6. 카페 진입 → Mission 1 Clear + Mission 2 안내 및 잠금 확인
7. 키오스크 실패 → Mission 2 Clear + Mission 3 안내 및 잠금 확인
8. 직원 대화 완료 → 최종 완료 카드 확인
9. 완료 확인 → 세 항목 Clear Mission List와 이동 활성화 확인
10. 체험 종료 후 재입장 → 소개 화면부터 초기화 확인
11. WorldTracking 또는 영상 폴백에서도 영구 잠금이 발생하지 않는지 확인

### 8.3 빌드 및 회귀

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

- 기존 Outdoor→Indoor 전환
- 키오스크 장벽 화면
- NPC 접근 및 대화 완료
- 손 추적과 테스트 주먹 조작
- 몰입 공간 종료·재진입

빌드가 사용자 서명 설정이나 Reality Composer 사용자 데이터를 자동 변경하면 해당 자동 생성 변경만 원복하고, 기능 변경 파일은 보존한다.

## 9. 예상 변경 범위

주요 변경 후보는 다음과 같다. 상세 파일 단위 작업은 후속 구현 계획에서 확정한다.

- `Barrier City/Quest/GuideFlowModel.swift` 추가
- `Barrier City/Quest/ExperienceGuideView.swift` 추가
- `Barrier City/Quest/LoopingGuideVideoView.swift` 추가
- `Barrier City/Quest/QuestModel.swift` 진행 결과 API 조정
- `Barrier City/Quest/QuestHUDFollower.swift` 중앙·좌측 상단 배치 모드 지원
- `Barrier City/Quest/QuestSetup.swift` 새 흐름 초기화와 수명주기 연결
- `Barrier City/ImmersiveView.swift` attachment의 루트 뷰 교체
- `Barrier City/AppModel.swift` 안내 잠금용 입력·속도 초기화 API
- `Barrier City/WheelchairMovementSystem.swift` 잠금 가드
- `Barrier City/Interaction/InteractionSetup.swift` 잠금 중 공간 상호작용 억제
- Quest 이벤트 발행 지점 3곳을 `GuideFlowModel` 단일 진입점으로 변경
- `onboarding-placeholder.mp4` 더미 자산 추가

## 10. 스코프 밖

- 실제 플레이 루프 영상 촬영·편집
- 미션 내용 추가 또는 순서 변경
- 온보딩 완료 여부의 영구 저장
- 설정 화면의 온보딩 다시 보기
- 음성 안내, 효과음, 햅틱
- Figma 파일 자체 수정
