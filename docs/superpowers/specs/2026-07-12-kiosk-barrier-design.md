# 키오스크 장벽 인터랙션 설계 (feature/spatial-interaction)

- 날짜: 2026-07-12
- 작성: Wade(김현기) + Claude
- 브랜치: `feature/spatial-interaction` (문 인터랙션 위에 이어서)
- 상태: 설계 승인됨 → 구현 계획(writing-plans) 진행

## 1. 배경과 목적

Barrier City의 핵심은 **장벽의 1인칭 체험**이다. 키오스크 인터랙션의 목적은 주문에 성공하는 UI가 아니라, **휠체어 사용자가 키오스크 앞에 갔지만 화면이 너무 높아 주문을 정상적으로 진행하지 못하는 상황**을 연출하는 것이다(팀 확정 의도).

원리: 비장애인 기준으로 설계된 키오스크(서 있는 눈높이 화면, 서 있는 리치 기준 버튼 배치)가 앉은 사용자에게 어떻게 장벽이 되는지를 UI 그 자체로 체험시킨다.

## 2. 확정된 결정

| 결정 | 내용 |
|---|---|
| 장벽 연출 | **높이 고정 + 닿지 않음**: 주문 화면을 키오스크 앞면 서 있는 눈높이(~1.5m)에 고정(빌보드 없음). 위쪽 메뉴·결제 버튼은 탭해도 "손이 닿지 않습니다" 피드백만 — 앉은 리치 시뮬레이션. 아래쪽 일부만 눌리지만 그것만으로 주문 완료 불가 → 좌절 경험 |
| 트리거 방식 | 문과 동일한 근접 트리거 인프라 재사용(접근 A). `ProximityTrigger`에 kind 추가 |
| 직원 호출 | 화면 하단 "직원 호출" 버튼 → "직원을 호출했습니다..." 상태 표시까지(스텁). AI 대화 연계는 다음 단계 |
| **이윤서 파일 수정** | **ImmersiveView attachments 블록에 3줄 추가 허용받음**(지난 작업에서 김현기가 추가한 블록 내). 그 외 이윤서 파일 무수정 |

## 3. 스코프

**포함:**
- Indoor 전환 시 `Kiosk` 프림 위치로 키오스크 근접 트리거 등록(반경 진입 시 화면 표시, 이탈 시 숨김·재접근 재표시 — 기존 evaluate 재사용)
- 키오스크 주문 화면(`KioskOrderView`): 메뉴 그리드(상단=닿지 않음), 하단 행 일부만 반응, "손이 닿지 않습니다" 피드백, 직원 호출 스텁
- 화면 배치: 키오스크 앞면 고정 자세·고정 높이(빌보드 없음)

**제외 (이후 단계):**
- AI 직원 대화 연계(직원 호출 후 흐름), 주문 성공 경로, 음료 수령·퀘스트 완료 처리
- 키오스크 화면 텍스처/브랜딩 디테일, 사운드

## 4. 컴포넌트 설계

### 4.1 `KioskOrderView.swift` (신규, 김현기 소유)
실제 카페 키오스크를 본뜬 SwiftUI 화면:
- 상단: 메뉴 그리드 2행×3열(아메리카노·카페라떼·바닐라라떼·카푸치노·아이스티·핫초코) — **전부 리치 밖**. 탭 → 버튼 흔들림 + "손이 닿지 않습니다" 토스트(1.5초).
- 그 아래: "결제하기" 버튼 — **리치 밖**(동일 피드백).
- 하단(리치 안): "직원 호출" 버튼 → 눌리면 "직원을 호출했습니다. 잠시만 기다려 주세요..." 상태로 전환(스텁, 상태는 InteractionModel에 보관해 재표시에도 유지). "처음으로" 버튼 → 호출 상태 리셋.
- 리치 판정은 정적 태깅(화면이 고정 높이이므로 상단 요소=닿지 않음이 항상 성립). 동적 높이 계산은 하지 않는다(YAGNI).

### 4.2 `InteractionModel.swift` 수정 (김현기 소유)
- `ProximityTrigger`에 `kind: TriggerKind` 추가 — `enum TriggerKind { case yesNoPrompt, kioskScreen }`. 기존 문 트리거는 `.yesNoPrompt`.
- 키오스크 상태: `var staffCalled = false` (직원 호출 스텁 상태).
- 엔티티 참조: `@ObservationIgnored var kioskPanelEntity: Entity?`.
- 튜닝 상수 추가(`InteractionTuning`): `kioskTriggerRadius: Float = 2.0`, `kioskScreenHeight: Float = 1.5`(화면 중심, 서 있는 눈높이), `kioskScreenYaw: Float = 0`(화면이 방 안쪽 +Z를 향함 — 카운터가 -Z 벽이므로. 시뮬레이터에서 실측 조정), `kioskFallbackCenter = SIMD2<Float>(-4, -4)`(카운터 좌측 부근 추정, 실측 조정), `kioskTitle = "주문하기"`(KioskOrderView 상단 타이틀 겸 트리거 prompt 값).
- `evaluate`는 **무수정**(트리거 목록이 다를 뿐 판정 로직 동일).

### 4.3 `InteractionSetup.swift` 수정 (김현기 소유)
- `install`: 두 번째 attachment `"kioskScreen"`을 worldRoot에 배치(초기 숨김) → `kioskPanelEntity`.
- `updatePanel`: activeTrigger의 kind로 라우팅 —
  - `.yesNoPrompt`: 기존 그대로(entryPrompt 패널, 빌보드)
  - `.kioskScreen`: kiosk 패널 표시. 위치 = 트리거 중심 + 높이 `kioskScreenHeight`, 자세 = `kioskScreenYaw` **고정**(빌보드 없음 — 높이 장벽 연출의 핵심)
  - 어느 쪽이든 비활성 트리거의 패널은 숨김.

### 4.4 `SceneSwitcher.swift` 수정 (김현기 소유)
- `switchToIndoor()`의 `im.triggers = []` 부분을 키오스크 트리거 등록으로 교체:
  - `indoorVisible.findEntity(named: "Kiosk")` 위치(worldRoot 기준 x, z) → 트리거 중심. 실패 시 `kioskFallbackCenter` + 경고 로그(문의 DOOR1 패턴과 동일).
  - `ProximityTrigger(id: "kiosk.order", kind: .kioskScreen, ...)`
- `staffCalled` 리셋 포함(재입장·전환 시 초기화).

### 4.5 `ImmersiveView.swift` 수정 (이윤서 파일 — **허용받음, 아래 3줄만**)
attachments 블록(김현기가 문 작업에서 추가한 블록)에:
```swift
            Attachment(id: "kioskScreen") {
                KioskOrderView()
            }
```

## 5. 데이터 흐름

```
Indoor 전환(SceneSwitcher) → 키오스크 트리거 등록(Kiosk 프림 위치)
매 프레임 tick(기존) → evaluate → activeTrigger → kind 라우팅 → 키오스크 화면 표시/숨김
사용자: 상단 버튼 탭 → 닿지 않음 피드백(로컬 상태) | 직원 호출 → staffCalled = true(스텁)
```

## 6. 에러 처리

| 상황 | 처리 |
|---|---|
| Kiosk 프림 못 찾음 | 폴백 좌표 + 콘솔 경고(DOOR1 패턴 동일) |
| Outdoor/전환 중 | 키오스크 트리거가 Indoor 목록에만 존재 + tick의 isTransitioning 가드로 표시 불가 |
| 체험 종료 후 재입장 | install의 상태 리셋(기존) + staffCalled 리셋 추가 |

## 7. 테스트 (시뮬레이터 수동 — 기존 방침)

1. Outdoor→예→Indoor 진입 → 콘솔에 키오스크 트리거 등록 로그(Kiosk 위치 or 폴백) 확인
2. 키오스크 접근(2.0m) → 주문 화면 표시, **고정 높이(올려다보임)·고정 방향** 확인
3. 메뉴/결제 버튼 탭 → "손이 닿지 않습니다" 피드백, 주문 진행 불가 확인
4. "직원 호출" → 호출 상태 표시, 멀어졌다 재접근해도 호출 상태 유지 확인
5. 이탈 시 화면 숨김, 재접근 시 재표시
6. 문 인터랙션(기존)이 회귀 없이 그대로 동작

## 8. 이후 단계 (스코프 밖)

1. 직원 호출 → AI 직원(NPC) 대화 연계(NPCDialogueController, 시뮬레이터는 파일 기반 STT 경로)
2. 직원 통한 주문 성공 → 음료 수령 → 퀘스트 완료 흐름
3. 키오스크 화면 비주얼 폴리시(텍스처·브랜딩), 효과음
