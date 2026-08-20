# Barrier City OpenAI 프록시 (Cloudflare Worker)

앱 바이너리에 OpenAI 키를 넣지 않기 위한 Realtime 전용 프록시. 흐름: `앱 → Worker(키 부착) → OpenAI`.

허용 엔드포인트와 모델:

- `POST /realtime-token` → `gpt-realtime-2.1` 단기 클라이언트 토큰

그 외 경로는 거절한다. OpenAI 키는 Worker Secret에만 저장하고 앱에는 단기 클라이언트
토큰만 전달한다. Worker가 모델·음성·VAD 구성을 고정하며 응답을 캐시하지 않는다.

`/realtime-token`에는 Cloudflare Rate Limiting binding이 연결된다. 현재 한도는
IP·Cloudflare POP 기준 10회/분이다. 이 카운터는 정확한 과금 장부나 사용자 인증
수단으로 취급하지 않는다.

## 사전 준비 (개발자 — 키/계정 필요)
1. **OpenAI 키 발급:** platform.openai.com → Billing 활성화 → API keys → 프로젝트 전용 키 생성.
2. **Cloudflare 계정** + 이 디렉터리에서 `npm install`.

## 배포
```bash
cd proxy
npm install
npm run types:check
npm run deploy:check
npm run deploy
npx wrangler secret put OPENAI_API_KEY   # 프롬프트에 키 입력 — git/앱 미포함
```
배포 후 출력된 `https://<name>.<account>.workers.dev` 가 `WORKER_URL`. 이 값을 앱의 `ProxyConfig(base:)`에 넣는다(키 아님, URL만).

`wrangler.jsonc`의 rate limit `namespace_id`는 Cloudflare 계정 전체에서 고유해야 한다.
동일 계정에 이미 같은 ID가 있다면 배포 전에 다른 양의 정수 문자열로 변경한다.

## 검증
```bash
# 앱에는 장기 API 키 대신 수명이 짧은 value만 전달된다.
curl -X POST "$WORKER_URL/realtime-token"
```

## 보안 메모

- OpenAI 프로젝트에 낮은 월 사용 한도와 알림을 설정한다.
- 현재 레이트 리밋은 익명 앱의 IP 기반 공통 방어다. 모바일 NAT에서는 여러 사용자가 같은 IP를
  공유할 수 있고 공격자는 IP를 바꿀 수 있으므로 사용자 인증을 대신하지 않는다.
- 외부 공개 배포 전 Apple Developer Team ID, Bundle ID, App Attest 키를 준비해 서버 측
  assertion 검증을 추가한다. 검증되지 않은 장치에는 Realtime 토큰을 발급하지 않아야 한다.
- Worker URL은 비밀이 아니므로 URL만으로 사용자를 인증할 수 있다고 가정하지 않는다.
