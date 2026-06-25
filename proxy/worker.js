// CloudFlare Worker — OpenAI 키 은닉 프록시. 스트림은 버퍼링 없이 그대로 전달.
// 보안 강화(레이트리밋·App Attest·월상한)는 제출 후. MVP는 키 은닉만.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — git/앱 미포함.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response("POST only", { status: 405 });

    const route =
      url.pathname === "/chat" ? "https://api.openai.com/v1/chat/completions"
      : url.pathname === "/tts" ? "https://api.openai.com/v1/audio/speech"
      : url.pathname === "/embeddings" ? "https://api.openai.com/v1/embeddings"
      : null;
    if (!route) return new Response("not found", { status: 404 });

    const upstream = await fetch(route, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.OPENAI_API_KEY}`, // Worker secret
        "Content-Type": "application/json",
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
