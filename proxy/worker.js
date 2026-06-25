// CloudFlare Worker — OpenAI 키 은닉 프록시 (제네릭 패스스루). 스트림은 버퍼링 없이 그대로 전달.
// 별칭(/chat·/tts·/embeddings)은 유지하고, 그 외 /v1/* 경로는 그대로 OpenAI로 전달한다.
// → 새 엔드포인트를 쓸 때 Worker 재배포 불필요. "무엇을 허용할지"는 OpenAI 키 권한이 단독 통제.
// 보안 강화(레이트리밋·App Attest·월상한)는 제출 후. MVP는 키 은닉만.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — git/앱 미포함.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response("POST only", { status: 405 });

    const alias = {
      "/chat": "/v1/chat/completions",
      "/tts": "/v1/audio/speech",
      "/embeddings": "/v1/embeddings",
    };
    // 별칭이면 매핑, 아니면 /v1/* 경로를 그대로 통과 (예: /v1/audio/transcriptions)
    const path = alias[url.pathname]
      ?? (url.pathname.startsWith("/v1/") ? url.pathname : null);
    if (!path) return new Response("not found", { status: 404 });

    const upstream = await fetch("https://api.openai.com" + path, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.OPENAI_API_KEY}`, // Worker secret
        // 클라이언트 Content-Type 그대로 전달 (multipart/form-data 등도 지원)
        "Content-Type": request.headers.get("Content-Type") || "application/json",
      },
      body: request.body, // 클라이언트 바디 그대로 전달
    });

    // 스트림 패스스루 — body를 읽지 말 것(버퍼링 금지)
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("Content-Type") || "application/octet-stream",
      },
    });
  },
};
