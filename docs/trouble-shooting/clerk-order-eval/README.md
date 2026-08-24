# 점원 주문 케이스 LLM 평가 하네스

전체 방법론과 결과 분석은 [`../clerk-order-llm-eval.md`](../clerk-order-llm-eval.md)를 보라. 이 폴더는 재현에 필요한 스크립트와 마지막 실행 결과의 스냅샷이다.

## 파일

- `PromptDumpTool.swift` — 실제 `RealtimeConversationGuide` 프롬프트 텍스트를 뽑는 임시 Swift 도구 소스. 재사용하려면 `Packages/DialogueKit/Package.swift`의 `targets`에 `.executableTarget(name: "PromptDumpTool", dependencies: ["DialogueKit"])`을 임시로 추가하고, 이 파일을 `Packages/DialogueKit/Sources/PromptDumpTool/main.swift`로 복사한 뒤 `swift run PromptDumpTool`로 실행한다. 끝나면 Package.swift와 그 소스 디렉터리를 다시 제거한다 — 앱 빌드에는 필요 없다.
- `prompt_dump.json` — 위 도구의 마지막 실행 출력(2026-08-24 기준 프롬프트 스냅샷). 프롬프트가 바뀌면 다시 뽑아야 한다.
- `harness.mjs` — WebSocket 기반 평가 엔진. `RealtimeMissionCoordinator`의 게임 상태 로직을 JS로 이식해 담고 있다.
- `scenarios.mjs` — 98개 시나리오 정의(카테고리별로 정리).
- `run.mjs` — 실행 진입점. `node run.mjs smoke|full <출력파일> [동시성]`.
- `results-2026-08-24.json` — 2026-08-24 전체 실행의 원본 결과(로그 포함).

## 재실행

```bash
node run.mjs smoke smoke_results.json      # 3개만 빠르게 확인
node run.mjs full results.json 1           # 전체 98개(동시성 1 권장 — TPM 40,000 한도)
```

Node.js 내장 `fetch`/`WebSocket`만 쓰므로 `npm install`이 필요 없다. 프록시(`barrier-city-openai-proxy.roiyeon.workers.dev`)에 대한 네트워크 접근과, 그 프록시가 유효한 OpenAI Realtime 세션 토큰을 계속 발급할 수 있어야 한다 — **실제 호출이라 비용이 발생한다.**
