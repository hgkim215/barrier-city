# Realtime 음성·실기기 검증 계획

이 문서는 Barrier City의 Cloudflare Worker, OpenAI Realtime 음성, ARKit/RealityKit을
실제 Apple Vision Pro에서 검증하기 위한 단일 체크리스트다. API 키나 단기 토큰,
사용자 음성 원문은 결과 문서와 로그에 기록하지 않는다.

## 검증 목표

1. 배포된 Worker가 허용된 요청만 OpenAI로 전달하고 비밀 값을 노출하지 않는다.
2. 현재 WebSocket 음성 경로의 지연과 안정성을 WebRTC 전환 전 기준선으로 남긴다.
3. 손 추적, World Tracking, 물리, Realtime 음성을 동시에 실행해도 몰입 경험을
   방해하는 프레임 지연, 멈춤, 오디오 끊김이 발생하지 않는지 확인한다.
4. WebRTC 전환 후 같은 조건으로 다시 측정해 기본 전송 방식 변경 여부를 판단한다.

## 측정 환경 기록

각 실행 전에 아래 정보를 채운다. 네트워크와 기기 상태가 다른 결과를 직접 비교하지 않는다.

| 항목 | 기록 값 |
| --- | --- |
| Git commit | |
| Worker version ID | |
| 앱 빌드 구성 | Debug / Release |
| Vision Pro 모델·visionOS | |
| 배터리 및 전원 연결 상태 | |
| 네트워크 | 안정 Wi-Fi / 제한 Wi-Fi |
| Realtime transport | WebSocket / WebRTC |
| 측정 시작 시 thermal state | nominal / fair / serious / critical |

## 공통 지표

### 음성

- `token_ms`: 토큰 요청 시작부터 임시 토큰 응답까지
- `connect_ms`: 연결 시작부터 `session.created`까지
- `ready_ms`: 연결 시작부터 `session.updated`까지
- `turn_ms`: `speech_stopped`부터 첫 모델 음성 또는 출력 transcript까지
- `interrupt_ms`: `speech_started`부터 모델 음성이 실제로 멈출 때까지
- 세션별 연결 실패, Realtime 오류, timeout, 재시도 횟수
- 입력 transcript, 함수 호출, 호감도/미션 결과의 성공 여부

지연은 벽시계 시간이 아니라 `ContinuousClock`으로 측정한다. 사용자 발화나 응답 내용은
저장하지 않고 이벤트 종류, 경과 시간, 오류 코드만 기록한다.

### 공간·성능

- 앱 내부 FPS, frame time, physics update time, raycasts/frame
- RealityKit Frames의 missed deadline과 CPU/GPU render rate
- RealityKit Metrics의 physics, animation, spatial systems, entity commit 병목
- Time Profiler의 main-thread 장기 작업
- Hangs, memory high-water mark, thermal state 변화
- 손 추적 유실/복구 및 World Tracking 폴백 횟수

앱 내부 FPS는 빠른 상태 확인용이다. 최종 성능 판정은 실기기의 Instruments
`RealityKit Trace`와 `Time Profiler` 결과를 기준으로 한다.

## 테스트 시나리오

각 시나리오는 앱을 새로 실행한 뒤 5분 이상 수행한다. WebSocket과 WebRTC 비교 시에는
같은 장소, 같은 기기, 같은 네트워크에서 아래 순서를 반복한다.

| ID | 활성 기능 | 수행 내용 |
| --- | --- | --- |
| S1 | 기본 몰입 공간 | 이동 없이 장면 렌더링 기준선 측정 |
| S2 | ARKit | 손 추적 이동, 손 가림/복구, HUD head-follow 확인 |
| S3 | 물리 | 직진, 회전, 경사로, 충돌을 반복하고 물리 지표 측정 |
| S4 | Realtime 음성 | NPC 대화 10턴, transcript와 함수 호출 확인 |
| S5 | 음성 끼어들기 | 모델 발화 중 10회 끼어들어 중단 지연과 대화 문맥 확인 |
| S6 | 전체 통합 | S2~S5를 동시에 수행하고 프레임·오디오 회귀 측정 |
| S7 | 수명주기 | 몰입 공간 진입/종료와 대화 시작/종료를 10회 반복 |
| S8 | 제한 네트워크 | 지연·손실이 있는 네트워크에서 연결과 복구 확인 |

## Cloudflare 배포 체크리스트

- [x] `npm test`
- [x] `npx wrangler deploy --dry-run`
- [x] `npx wrangler whoami`로 대상 계정 확인
- [x] `OPENAI_API_KEY`가 Worker Secret으로 존재하는지 확인
- [x] 배포 후 Worker version ID와 Git commit 기록
- [x] `/chat`, `/tts`, `/embeddings`, `/realtime-token` 정상 응답 확인
- [x] 미허용 경로, 메서드, 모델, 형식, 과대 요청 거절 확인
- [x] 429 응답과 `Retry-After` 확인(로컬 회귀 테스트)
- [x] 장기 API 키가 응답·로그에 없고 단기 토큰이 Workers Logs에 남지 않는지 확인
- [x] `npx wrangler tail`에서 요청 ID, 경로, 상태 코드 확인

## 실기기 기능 체크리스트

- [ ] 손 추적, 마이크, World Sensing 권한 승인/거부 경로 확인
- [ ] 손을 가렸다가 다시 보였을 때 휠체어 입력 정상 복구
- [ ] World Tracking 실패 시 HUD 고정 배치 폴백
- [ ] Realtime 연결 후 한국어 인사와 마이크 감도 표시
- [ ] transcript 완료와 NPC 함수 호출 결과 반영
- [ ] 모델 발화 중 사용자 끼어들기
- [ ] 무응답 timeout 후 대화·오디오 세션 정상 종료
- [ ] 몰입 공간 재진입 후 ARKit·마이크 재시작
- [ ] 다른 효과음과 Realtime 출력이 오디오 세션을 교착시키지 않음

## 릴리스 판정 기준

다음을 모두 만족해야 Realtime 전송 방식을 기본값으로 승격한다.

- 10회의 5분 통합 세션에서 crash와 hang이 없다.
- 토큰, 연결, `session.updated`, transcript, 함수 호출의 실패 원인이 모두 계측된다.
- 영구 API 키가 앱 바이너리, 응답, 저장 로그에 존재하지 않는다.
- WebRTC의 `turn_ms`와 `interrupt_ms` p95가 WebSocket 기준보다 나빠지지 않는다.
- WebRTC에서 제한 네트워크 연결 실패와 오디오 끊김이 WebSocket보다 줄거나 동등하다.
- 전체 통합 시나리오에서 RealityKit missed deadline과 thermal state가 기준선보다
  유의미하게 악화되지 않는다.

수치가 기준에 미달하면 WebSocket을 기본값으로 유지하고, 실패 조건과 trace를 첨부해
WebRTC를 실험 기능으로 남긴다.

## 실행 결과

| 날짜 | Commit | Worker version | Transport | 시나리오 | 결과 | 비고 |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11 | `0351734` | `048291da-e54e-4067-9158-403e592a6a9f` | HTTP | Worker 배포 | 통과 | Startup 5ms, 허용 엔드포인트 4개 정상 |

### 2026-08-11 Worker 배포 검증

- 계정: 배포 전 `wrangler whoami`로 앱 소유 계정 확인
- Secret: 이름이 `OPENAI_API_KEY`, 타입이 `secret_text`임을 확인하고 값은 조회하지 않음
- 배포 URL: `https://barrier-city-openai-proxy.roiyeon.workers.dev`
- 정상 경로: chat JSON 200, TTS PCM WAV 200, embeddings 1536차원 200,
  Realtime `gpt-realtime-2.1` 단기 토큰 200
- 거절 경로: 미허용 경로 404, GET 405, 미허용 모델 400, 잘못된 content type 415
- Rate Limit: 로컬 회귀 테스트에서 429와 `Retry-After: 60`, upstream 미호출 확인
- 로그: 배포 버전 ID, 요청 ID, 경로, 상태와 거절 코드가 구조화 로그에 남고
  Worker 애플리케이션 로그에는 요청 본문, API 키, 단기 토큰을 기록하지 않음

## 앱 내 측정 절차

1. Debug 빌드의 제어 패널에서 `Realtime 전송`을 WebSocket 또는 WebRTC로 선택한다.
2. `공간 성능 측정`에서 S1~S7 중 수행할 시나리오를 선택하고 측정을 시작한다.
3. NPC 대화를 수행한다. 현재 세션 지표와 전송별 누적 평균/p95가 자동 갱신된다.
4. 측정을 종료하고 Xcode Console의 `RealtimeMetrics`, `SpatialPerformance` 로그를 보관한다.
5. 같은 장소·기기·네트워크·thermal state에서 반대 전송 방식으로 반복한다.
6. Instruments의 RealityKit Trace와 Time Profiler 결과를 실행 결과 표에 연결한다.

WebRTC의 끼어들기 시간은 `input_audio_buffer.speech_started`부터 WebRTC 전용
`output_audio_buffer.cleared`까지 측정한다. WebSocket은 로컬 마이크 임계값 감지부터
AVAudioPlayerNode 중단까지 측정하므로 두 값의 측정 경계가 완전히 같지는 않다. 최종 판정에서는
수치와 함께 사용자가 실제로 들은 잔여 음성 여부를 반드시 기록한다.
