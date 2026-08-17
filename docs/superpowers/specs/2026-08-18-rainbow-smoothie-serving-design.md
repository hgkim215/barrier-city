# 레인보우 스무디 준비·카운터 제공 설계

작성일: 2026-08-18
대상 브랜치: `codex/rainbow-smoothie-serving`

## 1. 목표

휠체어 사용자가 접근하기 어려운 키오스크 대신 점원 NPC에게 레인보우 스무디 한 잔을 주문하면 다음 흐름을 제공한다.

1. 점원이 주문을 확정하고 조금만 기다려 달라고 말한다.
2. 주문 확정 음성이 완전히 끝난 시점부터 10초를 센다.
3. 10초 후 `RainbowSmoothie.usdz` 한 개를 `Indoor`의 `BarTable` 빈 상판에 표시한다.
4. 점원이 "주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요."라고 한 번 안내한다.
5. 같은 실내 세션에서는 주문, 타이머, 스무디, 완료 안내가 중복되지 않는다.
6. 이후 대화에서 점원은 주문이 준비 중인지, 카운터에 준비됐는지 기억한다.

이 기능은 키오스크 접근 장벽을 겪은 사용자가 직원 주문을 통해 서비스를 이어 가는 현재 데모 동선을 강화한다.

## 2. 이번 범위

### 포함

- 주문 상태 `notOrdered → preparing → readyAtCounter`
- 주문 확정 음성 종료 후 10초 준비 시간
- 실내 진입 시 스무디 에셋 선로딩과 숨김 배치
- `BarTable` 기준 런타임 배치 앵커
- 완료 시 스무디 표시와 NPC 확정 TTS 안내
- 일반 대화와 Realtime 대화가 동일한 주문 상태를 인지
- 중복 주문, 장면 종료, 지연 작업, 음성 충돌에 대한 방어
- 자동 테스트와 Simulator·Vision Pro 직접 검증

### 제외

- 쟁반 에셋 또는 임시 쟁반 메시
- 사용자가 스무디를 집거나 휠체어에 적재하는 상호작용
- 휠체어 적재 후 좌석까지 이동하거나 좌석에 내려놓는 흐름
- 여러 메뉴 또는 여러 잔 주문
- 주문 완료 이후 새로운 퀘스트 단계

## 3. 검토한 접근

### A. 전용 주문 세션과 RealityKit 프레젠터 분리 — 채택

논리적 주문 상태와 3D 엔티티의 로딩·배치·표시를 분리한다. NPC 대화는 주문 상태만 읽고, 프레젠터는 같은 스무디 엔티티의 공간상 위치만 책임진다.

- 장점: 상태의 단일 출처, 중복 방지, 테스트 용이성, 향후 휠체어 적재 확장에 적합
- 단점: AppModel에서 세 구성 요소를 명시적으로 연결해야 함

### B. Indoor 장면에 스무디를 미리 배치하고 활성화만 전환

- 장점: Reality Composer Pro에서 위치를 눈으로 맞추기 쉬움
- 단점: 장면 파일 변경이 커지고 주문 상태는 별도로 필요하며, 향후 휠체어로 옮길 때 장면 종속성이 커짐

### C. NPCClerkController에 상태·타이머·에셋을 모두 추가

- 장점: 파일과 연결 코드가 적음
- 단점: NPC 이동·대화·주문·3D 배치 책임이 한 클래스에 섞여 테스트와 확장이 어려움

## 4. 아키텍처

### CafeOrderSession

앱 수명 동안 한 인스턴스를 `AppModel`이 소유하는 주문 상태의 단일 출처다.

상태:

- `notOrdered`: 주문 전
- `preparing`: 주문 확정 음성이 끝났고 10초 준비 중
- `readyAtCounter`: 스무디가 카운터에 표시됨
- `failed`: 에셋 또는 배치 준비 실패로 완료할 수 없음

책임:

- `notOrdered`에서 들어온 최초 주문만 수락
- 이후 주문 이벤트에는 상태 변경 없이 `false` 반환
- 현재 상태를 NPC 대화에 읽기 전용으로 제공
- 장면 세션 세대 값을 관리해 이전 세션의 지연 결과를 거부
- 초기화 시 `notOrdered`로 복귀

`carriedOnWheelchair`와 `placedAtSeat`는 향후 개념적 후속 상태지만 이번 구현에는 추가하지 않는다. 현재 API는 같은 엔티티를 다른 앵커로 옮길 수 있게 경계를 유지한다.

### RainbowSmoothiePresenter

`RainbowSmoothie.usdz` 한 개의 수명과 공간 배치를 관리한다.

책임:

- Indoor 전환 준비 중 에셋을 미리 로드
- `BarTable`을 찾고 그 아래에 `BarTableServingAnchor` 런타임 엔티티 생성
- `ServingPlacementTuning` 한곳에서 관리하는 로컬 위치·회전·스케일을 앵커에 적용
- 스무디를 앵커 아래에 숨겨 설치해 첫 프레임 노출 방지
- 준비 완료 시 기존 엔티티를 표시
- 초기화 시 엔티티 제거와 참조 정리

배치값은 소스 여러 곳에 분산하지 않는다. 첨부 이미지의 계산대 왼쪽과 진열장 사이 빈 상판을 목표로 Simulator에서 조정하고, 상판 관통·부유·진열장 겹침이 없는 상태를 승인 기준으로 삼는다.

향후 수령 기능은 같은 엔티티를 `BarTableServingAnchor`에서 사용자 기준 공간의 `WheelchairCarryAnchor`로 재부모화한다. 현재 카페는 `worldRoot`가 휠체어 이동의 역변환을 받지만 휠체어는 RealityView의 사용자 기준 루트에 고정되므로, 이 재부모화가 운반 중 추종을 보장한다. 자리에서는 다시 `worldRoot` 아래 `SeatDropAnchor`로 이동한다.

### RainbowSmoothieServingController

주문 세션, 준비 타이머, 프레젠터를 조율한다.

책임:

- 최초 주문 수락 시 `preparing`으로 전환
- 기본 10초 sleeper 실행
- 테스트에서는 제어 가능한 sleeper를 주입해 실제 10초를 기다리지 않음
- 현재 세션이 유지되고 프레젠터가 준비된 경우에만 스무디 표시
- 표시 성공 뒤에만 `readyAtCounter`로 전환하고 NPC 완료 안내 요청
- 초기화 시 타이머 취소

### NPCDialogueController

기존 주문 판정과 음성 세션을 유지하면서 앱 소유 주문 상태를 매 응답에 반영한다.

책임:

- 일반 `DialogueOrchestrator` 경로와 Realtime 지시문에 같은 주문 상태 전달
- `preparing`에서는 이미 레인보우 스무디 한 잔이 주문됐으며 준비 중임을 사실로 유지
- `readyAtCounter`에서는 카운터에 준비됐음을 사실로 유지
- `preparing`, `readyAtCounter`, `failed`에서는 주문 완료 이벤트를 다시 만들지 않도록 앱 상태 가이드 적용
- `failed`에서는 주문 가능 또는 준비 완료라고 말하지 않고 현재 제공이 어렵다는 확정 폴백 사용
- `announceOrderReady()`로 확정 문구를 TTS와 자막에 한 번 전달
- 다른 발화나 대화가 진행 중이면 완료 안내를 예약하고 음성 채널이 빈 뒤 재생
- TTS가 실패해도 자막과 `readyAtCounter` 상태 유지

완료 안내 문구:

> 주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요.

### NPCClerkController

기존 `.orderPlaced` 미션 이벤트를 `RainbowSmoothieServingController`에 한 번 전달한다. NPC 이동·애니메이션은 그대로 유지하고 주문 타이머나 3D 엔티티를 직접 소유하지 않는다.

### AppModel과 장면 생명주기

`AppModel`은 `CafeOrderSession`, `NPCDialogueController`, `RainbowSmoothiePresenter`, `RainbowSmoothieServingController`, `NPCClerkController`를 한 그래프로 구성한다. Indoor 전환 성공 전에 프레젠터를 설치하고, 몰입 공간 종료 또는 Outdoor 초기화에서 serving controller를 먼저 초기화한 뒤 NPC 대화를 초기화한다.

## 5. 데이터 흐름

1. `SceneSwitcher`가 Indoor 시각 엔티티를 준비한다.
2. 프레젠터가 `RainbowSmoothie`를 선로딩하고 `BarTableServingAnchor`에 숨겨 설치한다.
3. 사용자가 NPC에게 레인보우 스무디 한 잔을 주문한다.
4. 기존 대화 계층이 주문 확인 음성을 끝낸 뒤 `.orderPlaced`를 발행한다.
5. `NPCClerkController`가 serving controller에 주문을 전달한다.
6. `CafeOrderSession`이 최초 주문만 수락하고 `preparing`으로 전환한다.
7. serving controller가 10초를 기다린다.
8. 세션 세대와 프레젠터 설치 상태를 다시 확인한다.
9. 프레젠터가 스무디를 표시한다.
10. 표시 성공 뒤 세션을 `readyAtCounter`로 전환한다.
11. `NPCDialogueController`가 완료 문구를 즉시 또는 현재 발화 종료 후 한 번 말한다.
12. 이후 대화는 현재 주문 상태를 바탕으로 응답한다.

10초의 시작점은 주문 의도를 인식한 순간이 아니라 주문 확인 TTS가 완전히 끝난 뒤 `.orderPlaced`가 발행되는 순간이다.

## 6. 중복 및 대화 정책

- 한 Indoor 세션에서 주문은 정확히 한 번만 수락한다.
- 중복 `.orderPlaced`는 타이머를 재시작하거나 스무디를 추가하지 않는다.
- `preparing` 중 재대화 예시: "레인보우 스무디는 이미 주문됐어요. 조금만 기다려 주세요."
- `readyAtCounter` 후 재대화 예시: "주문하신 레인보우 스무디가 준비됐어요. 카운터에서 가져가 주세요."
- 위 예시는 사실 제약이며 LLM은 기존 NPC 성향과 말투 안에서 자연스럽게 표현할 수 있다.
- 자동 완료 안내만은 누락과 메뉴 환각을 막기 위해 LLM이 아닌 확정 TTS 문구를 사용한다.

## 7. 예외 처리

- 중복 주문 이벤트: 무시
- 10초 안에 몰입 공간 종료: 타이머 취소, 숨긴 엔티티 제거, 예약 음성 취소
- 이전 세션 타이머의 늦은 완료: 세션 세대 불일치로 폐기
- 에셋 로드 또는 `BarTable` 탐색 실패: `failed` 기록, 완료 상태·표시·완료 음성 금지
- `failed` 상태의 주문 시도: 로컬 완료 이벤트를 차단하고 제공 불가 폴백으로 응답
- NPC 발화 또는 대화 진행 중: 완료 안내를 보류하고 음성 채널이 빈 뒤 한 번 재생
- 완료 안내 TTS 실패: 자막과 준비 완료 상태 유지
- 초기화: 타이머, 예약 발화, 엔티티, 상태, 세션 세대를 함께 정리

오류 시 스무디를 월드 원점이나 임의 폴백 좌표에 표시하지 않는다. 잘못된 공간 배치는 접근성 체험의 신뢰도를 해치므로 실패를 명시적으로 기록한다.

## 8. 테스트와 검증

### 자동 테스트

- `notOrdered → preparing → readyAtCounter` 정상 전이
- `notOrdered`가 아닌 상태의 주문 거부
- 제어 가능한 sleeper 완료 전 숨김, 완료 후 한 번만 표시
- 초기화 시 sleeper 취소와 상태 복귀
- 세대가 바뀐 뒤 이전 지연 결과 폐기
- 프레젠터 실패 시 `failed`와 완료 안내 미발행
- 완료 안내 요청이 한 번만 발생
- `preparing`과 `readyAtCounter`가 일반 PromptBuilder에 반영
- 같은 상태가 Realtime 지시문에 반영
- 상태가 이미 주문됨일 때 추가 `.orderPlaced`가 발행되지 않음
- RealityKitContent에 `RainbowSmoothie.usdz`가 존재하고 Indoor 계약에 `BarTable` 이름이 유지됨

### 빌드 검증

- `swift test --package-path Packages/DialogueKit`
- 프로젝트의 독립 Swift 계약 테스트 실행
- `xcodebuild`로 visionOS Simulator 대상 빌드

### 직접 검증

1. Outdoor에서 Indoor로 진입한다.
2. 첨부 이미지의 빈 상판에 스무디가 처음에는 보이지 않는지 확인한다.
3. NPC에게 레인보우 스무디 한 잔을 주문한다.
4. 주문 확인 음성 종료 시점부터 시간을 잰다.
5. 10초 전에는 스무디가 보이지 않고 10초 후 한 개만 표시되는지 확인한다.
6. 스무디가 상판을 관통하거나 떠 있지 않고 진열장·결제 기기와 겹치지 않는지 확인한다.
7. NPC가 완료 문구를 한 번 말하고 자막도 표시하는지 확인한다.
8. 준비 중과 준비 완료 후 재대화에서 상태를 기억하는지 확인한다.
9. 반복 주문 시 타이머·엔티티·음성이 중복되지 않는지 확인한다.
10. 준비 중 몰입 공간을 종료하고 재진입했을 때 초기 상태인지 확인한다.

Simulator에서 전체 흐름을 직접 확인하고, 실제 Vision Pro에서는 공간 크기·시야·음성·재진입을 다시 확인한다. 빌드와 테스트 통과만으로 몰입 기능 완료를 선언하지 않는다.

## 9. 완료 기준

- 주문 확인 음성 종료 후 10초 뒤 스무디 한 개가 지정 상판에 나타난다.
- NPC 완료 안내가 한 번 재생된다.
- NPC가 준비 중과 카운터 준비 완료 상태를 이후 대화에서 일관되게 인지한다.
- 동일 Indoor 세션에서 중복 주문·타이머·스무디·안내가 발생하지 않는다.
- 재진입 시 상태가 완전히 초기화된다.
- 자동 테스트, visionOS Simulator 빌드, Simulator 직접 흐름 검증을 통과한다.
- Vision Pro 확인 전에는 실제 기기 완료로 보고하지 않는다.
