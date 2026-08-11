# Realtime WebRTC 릴리스 준비 상태

기준일: 2026-08-11  
현재 운영 기본값: **WebSocket**  
판정: **코드·배포 준비 완료, 실기기 승격 판정 보류**

OpenAI는 모바일 클라이언트에서 더 일관된 성능을 위해 WebSocket보다 WebRTC 사용을
권장한다. Barrier City는 이 권장 구조를 구현했지만, 실제 Apple Vision Pro에서 동일 조건의
A/B 측정을 통과하기 전에는 Release 빌드의 기본 전송을 변경하지 않는다.

- OpenAI 공식 규약: <https://developers.openai.com/api/docs/guides/realtime-webrtc>
- WebRTC 바이너리: <https://github.com/livekit/webrtc-xcframework>
- 실기기 체크리스트: [realtime-device-validation.md](realtime-device-validation.md)

## 구현 결과

| 단계 | 결과 | Commit |
| --- | --- | --- |
| 검증 기준 | 시나리오·지표·릴리스 게이트 정의 | `8cdf583` |
| Worker 구성 | JSONC, Secret 요구, Rate Limit, observability | `0351734` |
| Worker 배포 | 허용 엔드포인트 E2E와 구조화 로그 검증 | `dc2d11b` |
| WebSocket 기준선 | 토큰·연결·턴·끼어들기·오류 계측 | `e1f0e64` |
| 공간 성능 | ARKit·World Tracking·물리·메모리·thermal 시나리오 계측 | `19a21d9` |
| 전송 추상화 | 대화 세션에서 네트워크 구현 분리 | `a99e87a` |
| WebRTC | SDP 교환, 오디오 미디어 트랙, `oai-events` 데이터 채널 | `4c70831` |
| A/B 도구 | Debug 전송 선택, 평균·p95·오류 누적 비교 | `0f631ab` |

WebRTC는 Worker가 발급한 짧은 수명의 클라이언트 토큰으로 OpenAI
`/v1/realtime/calls`에 SDP를 직접 교환한다. 장기 API 키는 앱에 들어가지 않는다. 오디오는
WebRTC 미디어 트랙이 담당하고, 세션 설정·transcript·함수 호출은 데이터 채널이 담당한다.

## 검증 완료 범위

- Cloudflare Worker 배포 URL:
  `https://barrier-city-openai-proxy.roiyeon.workers.dev`
- Worker version: `048291da-e54e-4067-9158-403e592a6a9f`
- Worker 테스트 7개 통과 및 배포 dry-run 통과
- DialogueKit 테스트 71개 통과
- visionOS Simulator Debug·Release 빌드와 WebRTC XCFramework 링크 통과
- WebRTC 의존성 `144.7559.11` 및 revision 고정
- XCFramework의 `xros-arm64`, `xros-arm64-simulator` 슬라이스 확인
- API 키·단기 토큰·음성·transcript를 애플리케이션 로그에 기록하지 않음

## 실기기에서 남은 필수 검증

`xcrun devicectl list devices`에서 등록된 Apple Vision Pro가 `unavailable` 상태여서 이번
작업에서는 아래 항목을 실행하지 못했다.

- Vision Pro 마이크 권한 승인·거부·재승인
- WebRTC Opus 입력·출력과 효과음의 AVAudioSession 공존
- 손 추적과 World Tracking 유실·복구
- S1~S8 시나리오의 WebSocket/WebRTC 각 10회 실행
- `turn_ms`, `interrupt_ms`, 오류율의 평균·p95 비교
- 제한 네트워크에서 ICE 연결, 오디오 끊김, 복구 확인
- RealityKit Trace의 missed deadline과 Time Profiler 병목 확인
- 5분 통합 세션 10회 및 몰입 공간 재진입 10회에서 crash·hang 없음

실기기 결과가 없으므로 현재 상태만으로 WebRTC를 운영 기본값으로 승격하면 안 된다.

## 승격과 롤백

Debug 빌드에서는 제어 패널의 segmented picker로 전송을 선택한다. Release 빌드는 코드에서
WebSocket으로 고정되어 있어 개발용 UserDefaults가 남아 있어도 WebRTC로 바뀌지 않는다.

실기기 릴리스 게이트를 모두 통과하면 다음 변경을 별도 커밋으로 수행한다.

1. `DevelopmentOptions.realtimeTransport`의 Release 기본값을 WebRTC로 변경한다.
2. WebSocket을 즉시 되돌릴 수 있는 운영 플래그 또는 새 앱 빌드 롤백 절차를 확정한다.
3. App Attest 검증을 Worker 토큰 발급 앞단에 추가한다.
4. Release Archive와 실제 배포 후보 빌드로 S6·S7을 재검증한다.

WebRTC 연결 실패율, 오디오 잔류, thermal 악화, crash 또는 hang이 기준을 넘으면 WebSocket을
유지하고 실패한 기기·visionOS·네트워크 조건과 Instruments trace를 결과 표에 남긴다.

## 알려진 제약

- LiveKitWebRTC의 visionOS Simulator 바이너리는 arm64만 제공하므로 x86_64 simulator
  architecture를 제외했다. Apple Silicon 개발 환경을 전제로 한다.
- WebSocket과 WebRTC의 끼어들기 계측 경계가 다르다. WebSocket은 로컬 재생 중단,
  WebRTC는 서버의 `output_audio_buffer.cleared` 이벤트를 종료점으로 사용한다.
- A/B 누적값은 현재 프로세스 메모리에만 유지되며 앱 재실행 시 초기화된다. 공식 결과는
  검증 문서와 Instruments trace에 별도로 기록한다.
- 공개 서비스 전에는 IP 기반 Rate Limit만으로 부족하므로 App Attest가 필수다.
