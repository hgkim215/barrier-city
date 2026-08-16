# Kiosk Screen UI 병합 결함 복구 설계

## 목표

`develop`의 안전한 실내 장면 전환 구조와 `codex/kiosk-screen-ui`의 키오스크 상태 및 실제 Screen 부착 기능을 함께 보존하면서, 병합 커밋 `d6d7cd3`에서 잘못 해결된 두 충돌을 제거한다.

## 원인

병합 시 `InteractionModel.requestKioskStaffHelp()`의 닫는 본문 대신 `develop`의 `tearDown()`과 구형 `acknowledgeKioskBarrier()`가 삽입되었다. 같은 병합에서 키오스크 브랜치의 이전 실내 전환 본문이 `SceneSwitcher.resolveIndoorLayout()` 내부에 중복 삽입되어 동기 레이아웃 함수가 장면 상태를 변경하고 존재하지 않는 지역 변수와 `await`를 참조하게 되었다.

## 설계

- `InteractionModel.requestKioskStaffHelp()`는 키오스크 상태가 도움 요청을 수락한 경우 활성 트리거와 손 도달 감지기를 정리하고 `true`를 반환한다.
- `tearDown()`은 독립 메서드로 유지하되 `endImmersiveSession()`이 새 키오스크 상태를 초기화하므로 제거된 `kioskTooHighShown`을 참조하지 않는다.
- 사용처가 없고 새 상태 모델로 대체된 `acknowledgeKioskBarrier()`는 복원하지 않는다.
- `SceneSwitcher.switchToIndoor()`는 `develop`의 준비 후 원자적 커밋 구조를 유지한다. 키오스크 상태 초기화와 Screen 부착은 새 Indoor 엔티티가 worldRoot에 연결된 뒤, 이전 장면을 제거하기 전에 수행한다.
- `resolveIndoorLayout()`은 좌표 계산과 `IndoorLayout` 반환만 담당한다.

## 오류 처리와 상태 일관성

Screen 또는 attachment가 없으면 기존 `billboardFallback`과 Mission 2 fail-open 경로를 유지한다. 몰입 공간 종료 시 entity 참조, 트리거, 전환 오류, 키오스크 세션 상태를 모두 초기화한다.

## 검증

1. 수정 전 `swiftc -parse` 및 상호작용 회귀 실행 파일 컴파일 실패를 RED 증거로 사용한다.
2. 수정 후 두 파일 구문 검사와 `InteractionFlowRegressionTests`를 통과시킨다.
3. 키오스크 순수 테스트, 관련 기존 회귀 테스트, DialogueKit 전체 테스트를 실행한다.
4. visionOS Simulator generic destination으로 전체 앱을 빌드한다.
5. `project.pbxproj`의 기존 로컬 변경을 스테이징하지 않고 두 소스 파일만 커밋한다.
