# Barrier City OpenAI 프록시 (Cloudflare Worker)

앱 바이너리에 OpenAI 키를 넣지 않기 위한 제한형 프록시. 흐름: `앱 → Worker(키 부착) → OpenAI`.

허용 엔드포인트와 모델:

- `POST /chat` → `gpt-4o-mini`
- `POST /tts` → `gpt-4o-mini-tts`
- `POST /embeddings` → `text-embedding-3-small`
- `POST /realtime-token` → `gpt-realtime-2.1` 단기 클라이언트 토큰

그 외 경로·모델과 128KiB를 넘는 요청은 거절한다. OpenAI 키는 Worker Secret에만 저장한다.
Realtime 토큰 경로는 모델·음성·VAD 구성을 Worker에서 고정하며 응답을 캐시하지 않는다.

## 사전 준비 (개발자 — 키/계정 필요)
1. **OpenAI 키 발급:** platform.openai.com → Billing 활성화 → API keys → 프로젝트 전용 키 생성.
2. **Cloudflare 계정** + 이 디렉터리에서 `npm install`.

## 배포
```bash
cd proxy
npm install
npm run deploy
npx wrangler secret put OPENAI_API_KEY   # 프롬프트에 키 입력 — git/앱 미포함
```
배포 후 출력된 `https://<name>.<account>.workers.dev` 가 `WORKER_URL`. 이 값을 앱의 `ProxyConfig(base:)`에 넣는다(키 아님, URL만).

## wrangler.toml (필요 시)
```toml
name = "barrier-city-openai-proxy"
main = "worker.js"
compatibility_date = "2026-07-25"

[placement]
region = "aws:us-west-2"
```

## 검증 (스트림 확인)
```bash
curl -N -X POST "$WORKER_URL/chat" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"한 문장으로 인사해줘"}]}'
```
기대: `data: {...}` SSE 청크가 흐르고 마지막 `data: [DONE]`. 응답에 키 노출 없음.

```bash
# TTS 확인 (wav 바이트가 내려오면 성공)
curl -X POST "$WORKER_URL/tts" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini-tts","voice":"alloy","input":"안녕하세요","response_format":"wav"}' --output /tmp/tts.wav
```

```bash
# 앱에는 장기 API 키 대신 수명이 짧은 value만 전달된다.
curl -X POST "$WORKER_URL/realtime-token"
```

## 보안 메모

- OpenAI 프로젝트에 낮은 월 사용 한도와 알림을 설정한다.
- 외부 배포 전 Cloudflare 레이트리밋과 Apple App Attest를 추가한다.
- Worker URL은 비밀이 아니므로 URL만으로 사용자를 인증할 수 있다고 가정하지 않는다.
