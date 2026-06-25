# OpenAI 키 은닉 프록시 (CloudFlare Worker)

앱 바이너리에 OpenAI 키를 넣지 않기 위한 최소 프록시. 흐름: `앱 → Worker(키 부착) → OpenAI`.
엔드포인트: `POST /chat`(Chat Completions, 스트림), `POST /tts`(gpt-4o-mini-tts).

## 사전 준비 (개발자 — 키/계정 필요)
1. **OpenAI 키 발급:** platform.openai.com → Billing 충전 → API keys → Create(가능하면 restricted key).
2. **CloudFlare 계정** + `wrangler` CLI (`npm i -g wrangler` 또는 `npx wrangler`).

## 배포
```bash
cd proxy
npx wrangler deploy
npx wrangler secret put OPENAI_API_KEY   # 프롬프트에 키 입력 — git/앱 미포함
```
배포 후 출력된 `https://<name>.<account>.workers.dev` 가 `WORKER_URL`. 이 값을 앱의 `ProxyConfig(base:)`에 넣는다(키 아님, URL만).

## wrangler.toml (필요 시)
```toml
name = "xr-openai-proxy"
main = "worker.js"
compatibility_date = "2025-01-01"
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

## 보안 메모 (제출 후)
레이트리밋, App Attestation, 월 비용 상한은 보안 후순위 정책상 제출 후. 현재는 키 은닉만.
