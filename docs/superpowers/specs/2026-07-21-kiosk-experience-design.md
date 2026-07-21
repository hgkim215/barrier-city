# 키오스크 체험 구체화 설계 — 좌절에서 도움 요청까지

날짜: 2026-07-21
작성: 브레인스토밍 세션 (Wade + Claude)
브랜치: kimhg

## 1. 배경과 목표

현재 키오스크 인터랙션은 "사용하기" 버튼을 누르면 즉시 "너무 높아 사용할 수
없습니다" 안내가 뜨는 구조다. 사용자가 장벽을 *겪는* 게 아니라 *통보받는*
경험이라 공감 유도가 약하다.

**목표:** 휠체어 사용자가 키오스크 주문을 직접 시도하다 누적된 장벽에 좌절하고,
결국 NPC 직원에게 도움을 요청해 음성으로 주문하는 흐름을 입체적으로 구현한다.
"커피 한 잔 주문"이라는 일상적 행위가 누군가에게는 도전이라는 깨달음을,
설명이 아니라 좌절의 경험으로 전달한다.

## 2. 확정된 설계 결정

| 결정 항목 | 선택 |
|---|---|
| 실패 방식 | 직접 조작하다 실패 (실제 메뉴·결제 UI + 물리적 도달 실패) |
| 리치 판정 | 하이브리드 — 실기: 핸드 트래킹 손 위치 기반 / 시뮬레이터: 상단 버튼 탭 시 '닿지 않음' 연출 |
| 실패 시나리오 | 누적 장벽 3개 + 사회적 압박 (오디오) |
| NPC 주문 | 음성 대화(기존 DialogueKit 파이프라인) + STT/네트워크 실패 시 선택지 폴백 |
| 마무리 연출 | **보류** — 주문 성공 이후 연출은 팀 회의로 결정 (이번 스코프 밖) |
| 새 파일 위치 | `Barrier City/Kiosk/` 폴더 신설 |
| 기존 KioskOrderView | `KioskScreenView`로 대체 |
| NPC 트리거 | 처음부터 활성화 (퀘스트는 3단계에서만 반응 — QuestModel이 불일치 이벤트 무시) |
| 단위 테스트 | 앱에 `Barrier CityTests` 유닛 테스트 타깃 신설 |

## 3. 체험 시나리오

1. **키오스크 접근** — 카페 실내에서 접근하면 Kiosk 프림 표면에 실물 크기
   세로 화면이 켜진다. 하단(~0.8–1.2m) 기본 메뉴 그리드, 상단(~1.4–1.7m)
   카테고리 탭·장바구니·결제 버튼.
   → 효과: 익숙한 일상에서 시작하는 동일한 출발점.
2. **장벽 ① 카테고리 탭이 안 닿음** — 상단 탭에 손을 뻗으면 하이라이트만
   반짝하고 눌리지 않는다. 반복 시 "손이 닿지 않습니다" 안내. 하단 기본
   메뉴로만 주문 진행.
   → 효과: 선택권의 박탈 — "먹고 싶은 걸 고르는 게 아니라 닿는 걸 골라야 한다."
3. **장벽 ② 시간 초과 리셋** — 유휴 타이머 만료 시 장바구니가 비워지고 첫
   화면으로 리셋. 이후 뒤에서 압박 오디오 시작(발소리, 한숨, 헛기침,
   "저기… 얼마나 걸릴까요?").
   → 효과: 시스템이 내 속도를 기다려주지 않는 좌절 + 뒤에 줄 선 사람들에 대한
   미안함. 장애가 '개인의 문제'가 아니라 '설계의 문제'임을 체감.
4. **장벽 ③ 결제 불가 (최종 실패)** — 재시도 끝에 결제 화면 진입. 결제 확인
   버튼·카드 삽입구가 최상단(~1.6m)이라 닿지 않는다. 임계 횟수 실패 시
   "결제가 완료되지 않았습니다" → 최종 실패, `QuestEvent.kioskFailed` 발행.
   → 효과: 거의 다 왔는데 마지막에 무너지는 극대화된 좌절 — 노력으로 극복할
   수 없는 구조적 장벽.
5. **일어서기 가드 (상시)** — 머리 높이가 기준 대비 +0.25m 이상 오르면 화면이
   흐려지며 "휠체어 사용자는 일어설 수 없습니다" 오버레이. 다시 앉으면 해제.
   → 효과: "그냥 일어나면 되잖아"라는 탈출구 차단.
6. **직원에게 도움 요청** — 카운터의 NPC(Skull 모델, Greeting 애니메이션)에게
   접근하면 대화 UI 등장. push-to-talk로 말해서 주문 → NPC가 음성+자막으로
   응답. `orderPlaced`/`helpRequested` 이벤트로 `QuestEvent.npcHelpDone` 발행,
   퀘스트 3단계 완료. 주문 완료 시 Happy 애니메이션.
   → 효과: "혼자 할 수 있는 일"이 "도움을 요청해야 하는 일"이 되는 전환.

**시뮬레이터 경로:** 리치 판정 불가 → 상단 버튼 탭이 곧 '닿지 않음' 연출로
라우팅. 타이머·리셋·결제 실패·NPC 폴백 선택지는 실기와 동일하게 동작해
시뮬레이터만으로 전체 흐름 완주 가능.

## 4. 아키텍처

기존 패턴 준수: `@Observable @MainActor` 싱글턴 + 순수 판정 함수 분리 +
Tuning 상수 enum + `InteractionSetup`의 SceneEvents.Update 틱.

### 4.1 새 컴포넌트 (`Barrier City/Kiosk/`)

- **`KioskFlowModel`** — 키오스크 상태 머신 싱글턴.
  상태: `browsing` → `resetting` → `payment` → `failed`.
  데이터: 장바구니, 유휴 타이머 잔여, 리셋 횟수, 존별 near-miss 횟수,
  결제 시도 횟수. `failed` 진입 시 `QuestModel.shared.advance(on: .kioskFailed)`.
- **`KioskFlowLogic`** — 상태 전이 규칙 순수 함수(nonisolated static).
  `QuestProgression` 패턴. 리치 판정 verdict 함수도 여기에.
- **`KioskScreenView`** — 실물 키오스크 SwiftUI attachment.
  상단 존(카테고리·결제)과 하단 존(기본 메뉴 그리드) 명시 분리.
  상단 존 버튼은 자체 액션 대신 KioskFlowModel에 "도달 시도" 보고.
- **`StandUpGuard`** — WorldTracking head 포즈(QuestHUDFollower 방식 재사용)로
  기준 높이 캡처, 임계 초과 시 오버레이 + 키오스크 입력 정지.
- **`PressureAudio`** — ImpactAudio 패턴(AudioFileResource)으로 번들 오디오
  재생. KioskFlowModel 상태 변화(첫 리셋 이후)에 반응해 단계적 강도 상승.
- **`KioskTuning`** — 상수 단일 진실원: 존 높이 경계, 판정 여유, 유휴 타이머
  시간, 실패 임계 횟수, 일어서기 임계(+0.25m), NPC 트리거 반경, 폴백 좌표.
  실기 전용 상수(리치 높이 등)는 실기 테스트 때 조정한다.

### 4.2 NPC 주문 배선 (`Barrier City/Dialogue/` 확장)

- Indoor 카운터 위치에 Skull NPC 배치(프림 탐색 + 폴백 좌표 상수).
- `TriggerKind.npcDialogue` 추가, 근접 트리거 등록(처음부터 활성).
- 새 attachment **`NPCOrderView`**: push-to-talk 버튼(누르는 동안 듣기),
  자막·상태 표시, STT/네트워크 실패 시 선택지 버튼 3개 폴백.
- 기존 `NPCDialogueController` 무수정 재사용. 이벤트 수신 →
  `QuestModel.shared.advance(on: .npcHelpDone)`.

### 4.3 리치 판정 (하이브리드)

- `HandTrackingManager`의 `gripWorldPosition`을 `AppModel.handWorldLeft/Right`로
  노출(신규 프로퍼티).
- 틱마다 순수 함수 판정: 손이 키오스크 XZ 근방 + 손 높이 ≥ (상단 존 최소 높이
  − 여유) → "닿음". 앉은 사용자는 자연 실패.
- 상단 버튼이 시선+핀치로 탭되면(손이 존에 없으면) '닿지 않음' 경로로 라우팅.
  시뮬레이터도 같은 경로라 분기 최소화.

### 4.4 데이터 흐름

```
HandTrackingManager ─→ AppModel(handWorld L/R)
                              │
InteractionSetup.tick ─→ 근접 판정(기존) + 리치 판정(신규) ─→ KioskFlowModel
                                                                │
KioskScreenView ←─ 상태 관찰 ─┘        failed ─→ QuestModel(.kioskFailed)
NPCOrderView ─→ NPCDialogueController ─→ orderPlaced/helpRequested
                                              ─→ QuestModel(.npcHelpDone)
```

### 4.5 기존 코드 변경 범위

| 파일 | 변경 |
|---|---|
| `KioskOrderView.swift` | `KioskScreenView`로 대체 |
| `InteractionSetup.swift` | 키오스크 패널 월드 고정 배치, 리치 판정 틱, NPC 트리거 등록, 싱글턴 리셋 목록에 KioskFlowModel 추가 |
| `InteractionModel.swift` | `TriggerKind.npcDialogue` 추가, `kioskTooHighShown` 제거 |
| `AppModel.swift` | `handWorldLeft/Right` 프로퍼티 추가 (최소 변경) |
| `HandTrackingManager.swift` | 손 월드 좌표를 AppModel에 기록 (2줄 수준) |
| `ImmersiveView.swift` | attachment 추가/교체 (kioskScreen 교체, npcOrder·standUpOverlay 추가) |
| `QuestModel.swift` | 무수정 (`.npcHelpDone` 발행처만 새로 연결됨) |

## 5. 에러 처리

**공간·에셋 폴백 (기존 패턴):**
- Kiosk 프림 못 찾음 → 폴백 좌표에 월드 고정 배치.
- NPC 모델 로드 실패 → 트리거는 폴백 좌표에 등록, 대화 UI는 정상 동작.
- 애니메이션 클립 없음 → 연출 생략, 기능 유지.

**입력 계열 — 전부 fail-open (체험이 막히지 않게):**
- 핸드 트래킹 거부/불가 → 탭 = '닿지 않음' 연출 경로. 완주 가능.
- head 포즈 불가 → StandUpGuard 비활성.
- STT 권한 거부/인식 실패 → 선택지 버튼 폴백.
- 네트워크/프록시 실패 → DialogueCache 캔드 라인 + 폴백 선택지에 고정 응답
  대사 매핑. LLM 없이도 `orderPlaced`까지 도달 가능(오프라인 완주).
- TTS 실패 → 자막만 표시.

**상태 꼬임 방지:**
- 몰입 공간 재진입 시 `KioskFlowModel.reset()` — InteractionSetup.install
  0단계 리셋 목록에 추가.
- 유휴 타이머 일시정지 조건: 일어서기 오버레이 표시 중, 씬 전환 중, 트리거
  이탈. 재진입 시 타이머만 리셋(진행 상태 유지 — 리셋 연출은 시간 초과로만).
- 최종 `failed` 후 재접근 → "직원에게 문의하세요" 고정 안내(반복 없음).
  퀘스트 중복 발행은 QuestModel이 무시.

## 6. 테스트 전략

개발 환경 제약: 실기기는 다른 팀원 보유. 개발·1차 검증은 전부 시뮬레이터에서
수행하고, 실기 항목은 체크리스트로 팀원에게 위임한다.

**1) 단위 테스트 — `Barrier CityTests` 타깃 신설 (Swift Testing):**
- `KioskFlowLogic` 상태 전이: 리셋 조건, 실패 임계, failed 후 불변.
- 리치 판정: 손 좌표 케이스별 닿음/안 닿음/근접(near-miss).
- StandUpGuard 임계 판정.
- (선택) 기존 순수 함수 `QuestProgression`, `InteractionModel.evaluate`도
  같은 타깃에 추가 가능 — 이번 스코프 밖.

**2) 시뮬레이터 수동 체크리스트 (Wade 수행):**
- 조이스틱으로 접근 → 화면 켜짐 → 상단 탭 → '닿지 않음' 피드백 → 방치 →
  시간 초과 리셋 + 압박 오디오 → 메뉴 담기 → 결제 실패 임계 → 최종 실패 +
  퀘스트 3단계 전환 → NPC 접근 → 폴백 선택지 주문 → 퀘스트 완료.
- 트리거 이탈/재진입, 몰입 공간 재진입 리셋 확인.

**3) 실기 수동 체크리스트 (팀원 위임):**
- 앉은 자세에서 상단 버튼 실제 도달 불가 확인(존 높이 상수 실측 튜닝).
- 일어서기 가드 발동/해제.
- push-to-talk 음성 주문 전체 흐름(마이크 권한 포함).
- 시선+핀치 원격 탭이 '닿지 않음' 경로로 빠지는지.

## 7. 스코프 밖 (명시)

- **주문 성공 이후 마무리 연출** — 팀 회의로 결정 후 별도 스펙.
- **몸 기울임-전복 연동(C안 확장)** — A안 검증 후 얹을 수 있는 확장으로 보류.
- 압박용 군중 NPC 3D 배치 — 오디오로 대체(에셋 없음). Skull 재사용 배치는 선택.
- 정교한 키오스크 비주얼 디자인 — 레이아웃·존 구조까지만 이번 스코프.
