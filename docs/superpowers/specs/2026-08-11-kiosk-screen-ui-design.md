# Indoor 키오스크 Screen UI 설계

날짜: 2026-08-11  
대상 브랜치: `codex/kiosk-screen-ui`  
대상: visionOS `Barrier City` 몰입 체험

## 1. 목적

Indoor 씬의 키오스크 전면에 이미 배치된 `Screen` 평면에 코드 기반 카페 메뉴 UI를 고정한다. 사용자는 카페에 들어온 순간 실제 키오스크가 켜져 있는 모습을 보고, 가까이에서 시선+핀치 또는 손 뻗기로 메뉴 사용을 시도한다. 주문은 진행되지 않고 화면 하단에 접근 불가 안내가 나타나며, 기존 Mission 3와 NPC 도움 대화로 이어진다.

이 기능은 키오스크 주문 성공 UI가 아니라, 휠체어 이용자가 높은 키오스크를 독립적으로 사용할 수 없는 서비스 접근성 장벽을 체험시키는 장치다.

## 2. 확인된 자산과 제약

- 참고 이미지는 1080×1920의 세로형 UI다.
- `Screen.usdz`의 `Plane`은 약 0.30×0.52m의 세로형 평면이어서 참고 이미지와 화면비가 가깝다.
- `Indoor.usda`에서 `Kiosk`와 `Screen`은 `Root` 아래 형제 엔티티다. `Screen`이 키오스크 전면에 위치·회전·스케일되어 있다.
- 현재 `KioskOrderView`는 `Screen`에 붙지 않고 `worldRoot` 아래에서 사용자 쪽을 향하는 별도 빌보드로 표시된다.
- 현재 Quest 흐름은 키오스크 실패 `kioskFailed` 후 Mission 3로 넘어가고, 사용자가 NPC에게 접근하면 기존 대화가 시작된다.
- Reality Composer Pro 워크스페이스 메타데이터에는 사용자 소유 미커밋 변경이 있으므로 이 기능의 커밋에 포함하지 않는다.

## 3. 확정된 제품 동작

### 3.1 표시와 활성화

- Indoor 씬이 표시되는 순간부터 키오스크 메뉴 UI를 항상 켠다.
- 키오스크 근접 트리거 밖에서는 메뉴를 볼 수 있지만 입력은 받지 않는다.
- 근접 트리거 안이고 Mission 2가 활성 상태일 때 시선+핀치와 손 뻗기 입력을 활성화한다.
- UI는 사용자를 따라 회전하지 않고 `Screen` 평면의 위치·각도·스케일을 그대로 따른다.

### 3.2 사용 시도와 장벽 피드백

- 메뉴 카드 중 하나를 시선+핀치로 선택하면 키오스크 사용 시도로 처리한다.
- 손을 키오스크 화면 쪽으로 올려 뻗어도 동일한 사용 시도로 처리한다.
- 어느 입력이 먼저 들어와도 화면 하단에 한 번만 접근 불가 카드를 표시한다.
- 카드 문구:
  - 제목: `손이 닿지 않습니다`
  - 설명: `앉은 자세에서는 이 메뉴를 선택할 수 없습니다.`
  - 행동: `직원에게 도움 받기`
- 메뉴 선택, 장바구니, 결제, 주문 완료는 구현하지 않는다.

### 3.3 도움 흐름

- `직원에게 도움 받기`를 누르면 `GuideFlowModel.handleQuestEvent(.kioskFailed)`를 한 번 호출한다.
- 접근 불가 카드는 닫히고 키오스크 입력은 현재 몰입 세션 동안 잠긴다.
- 키오스크 메뉴 화면 자체는 계속 켜진 상태로 남는다.
- 기존 Mission 3 안내를 확인한 뒤 NPC에게 접근하면 기존 NPC 대화가 시작된다.
- 몰입 공간에 재진입하면 메뉴, 접근 불가 카드, 입력 잠금, 손 시도 판정을 초기 상태로 되돌린다.

## 4. 화면 디자인

첨부 이미지의 정보 구조와 따뜻한 갈색·주황 계열 분위기를 참고하되 외부 카페 로고와 이미지를 그대로 사용하지 않는다.

- 브랜드: `BARRIER CAFE`
- 상단: 브랜드와 간단한 상태 표시
- 카테고리: `베스트`, `커피`, `에이드`, `기타`
- 메뉴: 아메리카노, 카페라떼, 카페모카, 에스프레소, 아이스티, 핫초코 등 6~9개 고정 항목
- 메뉴 이미지는 프로젝트에 별도 음료 이미지가 없으므로 SwiftUI Shape 또는 시스템 컵 심볼을 사용한다.
- 메뉴 그리드는 Screen 비율에 맞춘 3열 구성으로 단순화한다.
- 하단 장바구니 영역은 실제 주문 상태를 갖지 않는 정적 장식으로 둔다.
- 접근 불가 카드는 메뉴를 가리지 않는 하단 카드로 표시한다.
- 전체 UI는 `Screen` 평면과 거의 같은 9:16 비율의 고정 캔버스를 사용한다.

## 5. 아키텍처와 책임

### 5.1 엔티티 계층

```text
worldRoot
└─ Indoor
   └─ Screen
      └─ Plane
         └─ kioskScreen attachment
```

`Screen` 루트가 아니라 실제 메시인 `Plane`을 기준으로 attachment를 붙인다. `Plane`은 자체 회전을 포함하므로 자식 attachment가 화면 면과 동일한 좌표계를 상속할 수 있다.

### 5.2 `KioskScreenPresenter`

새로운 작은 배치 유틸리티다.

- Indoor 씬에서 `Screen`과 그 하위 `Plane`을 찾는다.
- 기존 `kioskScreen` attachment를 `Plane` 자식으로 재부착한다.
- Plane과 attachment의 local visual bounds를 비교해 화면 안에 98%로 맞는 균일 스케일을 계산한다.
- z-fighting을 피하도록 Plane 로컬 정면으로 0.002m 띄운다.
- attachment 앞면이 반대로 보이는 경우에만 `KioskScreenTuning.faceRotation`으로 180도 보정할 수 있게 한다. 초기값은 identity다.
- `Screen/Plane`을 찾지 못하거나 bounds가 유효하지 않으면 현재의 월드 고정 키오스크 패널 배치로 폴백한다.

### 5.3 `KioskOrderView`

기존 단순 안내 화면을 항상 보이는 카페 메뉴 화면으로 교체한다.

- 표시만 담당하며 외부 서비스나 메뉴 데이터에 의존하지 않는다.
- `InteractionModel`에서 입력 활성 여부와 접근 불가 카드 상태를 읽는다.
- 모든 메뉴 카드는 동일한 `attemptKioskUse(.gazePinch)` 동작을 호출한다.
- 도움 버튼은 중복 호출을 막은 뒤 기존 `kioskFailed` Quest 이벤트를 발행한다.

### 5.4 `KioskReachAttemptDetector`

RealityKit과 ARKit에 의존하지 않는 순수 상태 기계다.

- 입력: Screen 로컬 좌표로 변환된 추적 손 위치, 타임스탬프, 추적 여부
- 출력: `idle`, `tracking`, `attempted`
- 기본 감지 조건:
  - Screen 정면 0.08~0.65m
  - Screen 좌우 bounds에 0.12m 여유를 더한 범위
  - 0.45초 이내 Screen 방향 또는 위쪽으로 0.08m 이상 이동
  - 조건을 0.20초 유지
  - 판정 후 1초 쿨다운
- 추적 손실 또는 0.25초 이상 샘플 정체 시 즉시 초기화한다.
- 키오스크 근접, Mission 2 활성, 가이드 잠금 해제 조건을 만족할 때만 샘플을 받는다.
- 바퀴 근처의 낮은 손 위치는 Screen 시도 영역 밖이므로 주행 중 오감지하지 않는다.

모든 수치는 `KioskReachTuning`에 모아 실기기에서 조정 가능하게 한다.

### 5.5 입력 통합

`InteractionModel`이 키오스크 사용 시도의 단일 진입점을 제공한다.

```text
SwiftUI menu tap ───────────┐
                            ├─ attemptKioskUse → barrier card
HandTrackingManager sample ─ KioskReachAttemptDetector ┘
```

- 장벽 카드가 이미 열렸거나 Mission 3로 넘어간 뒤 들어온 시도는 무시한다.
- `HandTrackingManager`는 기존 휠체어 바퀴 입력을 유지하면서 필요한 손 위치 샘플만 detector에 전달한다.
- 손 추적이 꺼졌거나 권한이 거부돼도 시선+핀치 경로는 유지한다.

## 6. 상태 흐름

```text
Indoor 진입
  → menuVisible, inputDisabled
키오스크 근접 + Mission 2
  → menuVisible, inputEnabled
시선+핀치 또는 손 뻗기
  → barrierVisible, inputDebounced
직원에게 도움 받기
  → menuVisible, inputLocked, kioskFailed
Mission 3 확인
  → NPC 접근 시 기존 대화
```

키오스크에서 멀어졌다 다시 접근해도 Mission 2 동안에는 메뉴가 유지되고 입력이 다시 활성화된다. Mission 3로 넘어간 뒤에는 같은 몰입 세션에서 키오스크 입력을 다시 열지 않는다.

## 7. 오류 처리

| 상황 | 처리 |
|---|---|
| `Screen` 또는 `Plane` 없음 | 현재 월드 고정 패널 배치로 폴백하고 경고 로그 |
| Plane/attachment bounds가 0 또는 비정상 | 튜닝 상수의 폴백 scale·offset 사용 |
| attachment 없음 | 경고 로그 후 키오스크 근접 시 기존 Quest가 영구 잠기지 않도록 fail-open 경로 제공 |
| 손 추적 미지원·권한 거부 | 시선+핀치만 활성화 |
| 손 추적 손실·샘플 정체 | 진행 중 손 시도 초기화 |
| 두 입력 동시 발생 | 첫 시도만 수락, 나머지 무시 |
| 씬 전환 취소·몰입 종료 | detector와 키오스크 상태 초기화 |

attachment 자체가 없는 fail-open은 사용자에게 접근 불가 안내를 별도 HUD 문구로 보여준 뒤 `kioskFailed`를 한 번 발행한다. 정상 자산에서는 실행되지 않는 최후 방어선이다.

## 8. 검증

### 8.1 자동 검증

`KioskReachAttemptDetector` 순수 테스트:

1. Screen 방향 손 이동이 유지 시간 뒤 한 번만 시도로 판정된다.
2. 위쪽 손 이동이 유지 시간 뒤 시도로 판정된다.
3. 좌우·정면 거리 범위 밖 손은 무시된다.
4. 정지 손과 바퀴 근처 손은 무시된다.
5. 추적 손실과 stale timeout이 후보 상태를 초기화한다.
6. 쿨다운 동안 중복 시도를 무시하고 이후 새 시도를 허용한다.

키오스크 상태 테스트:

1. Indoor 진입 시 메뉴는 보이고 입력은 비활성이다.
2. Mission 2 근접 상태에서만 입력이 활성화된다.
3. 시선+핀치와 손 시도는 동일한 장벽 상태를 만든다.
4. 도움 버튼은 `kioskFailed`를 한 번만 발행하고 입력을 잠근다.
5. 세션 재진입은 모든 키오스크 상태를 초기화한다.
6. Screen 설치 실패는 폴백을 선택하고 Quest 진행을 막지 않는다.

그다음 기존 standalone 회귀 테스트, DialogueKit 54개 테스트, generic visionOS Simulator 빌드를 실행한다.

### 8.2 수동 검증

Simulator:

1. Indoor 진입 직후 메뉴 화면이 Screen에 계속 표시된다.
2. UI가 Screen 면을 채우고 이동·회전 시 분리되거나 사용자 쪽을 따라 돌지 않는다.
3. 근접 전 메뉴 입력이 비활성이고 근접 후 시선+핀치가 장벽 카드를 연다.
4. 도움 버튼이 Mission 3로 연결되고 기존 NPC 대화가 정상 시작된다.
5. 몰입 종료 후 재진입하면 키오스크 상태가 초기화된다.

Vision Pro:

1. 시선+핀치 경로가 Simulator와 동일하게 동작한다.
2. 손을 Screen 쪽으로 올려 뻗으면 장벽 카드가 한 번 표시된다.
3. 바퀴를 잡고 미는 동안 손 뻗기 오감지가 없다.
4. UI와 Screen 사이에 깜빡임, z-fighting, 앞뒤 반전이 없다.
5. 장벽 카드 문구가 앉은 시야에서 읽히고 도움 버튼을 선택할 수 있다.

## 9. 완료 기준

- UI가 Indoor의 실제 `Screen` 위치에 고정된다.
- UI는 Indoor 동안 항상 표시되며 Mission 2 근접 상태에서만 입력을 받는다.
- 시선+핀치와 손 뻗기 모두 동일한 접근 불가 카드를 연다.
- 도움 버튼이 기존 Mission 3와 NPC 대화 흐름을 회귀 없이 이어 준다.
- Screen·손 추적 실패 시에도 3~5분 데모 경로가 중단되지 않는다.
- 자동 테스트와 visionOS Simulator 빌드가 통과한다.
- Vision Pro 수동 검증 항목은 실기기에서 별도로 확인한다.

## 10. 제외 범위

- 실제 장바구니, 결제, 주문 성공
- 외부 메뉴 API 또는 서버 데이터
- `Screen.usdz`, `Indoor.usda`, 키오스크 3D 모델 수정
- NPC 대화 내용·애니메이션·이동 로직 변경
- 키오스크 사운드와 음료 수령 연출
