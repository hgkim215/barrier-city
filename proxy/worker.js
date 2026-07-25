// Barrier City 전용 OpenAI 프록시.
// 앱이 실제로 사용하는 경로와 모델만 허용해 개인 API 키의 오용 범위를 줄인다.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — 소스/앱에 저장하지 않는다.

const MAX_BODY_BYTES = 128 * 1024;

const ROUTES = {
  "/chat": {
    upstreamPath: "/v1/chat/completions",
    models: new Set(["gpt-4o-mini"]),
  },
  "/tts": {
    upstreamPath: "/v1/audio/speech",
    models: new Set(["gpt-4o-mini-tts"]),
  },
  "/embeddings": {
    upstreamPath: "/v1/embeddings",
    models: new Set(["text-embedding-3-small"]),
  },
};

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return jsonResponse({ error: "POST only" }, 405);
    }

    const route = ROUTES[url.pathname];
    if (!route) return jsonResponse({ error: "Not found" }, 404);
    if (!env.OPENAI_API_KEY) {
      return jsonResponse({ error: "Server is not configured" }, 503);
    }

    const contentType = request.headers.get("Content-Type") || "";
    if (!contentType.toLowerCase().startsWith("application/json")) {
      return jsonResponse({ error: "application/json required" }, 415);
    }

    const declaredLength = Number(request.headers.get("Content-Length") || 0);
    if (declaredLength > MAX_BODY_BYTES) {
      return jsonResponse({ error: "Request too large" }, 413);
    }

    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_BODY_BYTES) {
      return jsonResponse({ error: "Request too large" }, 413);
    }

    let payload;
    try {
      payload = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return jsonResponse({ error: "Invalid JSON" }, 400);
    }

    if (!route.models.has(payload?.model)) {
      return jsonResponse({ error: "Model not allowed" }, 400);
    }

    const upstream = await fetch("https://api.openai.com" + route.upstreamPath, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body,
    });

    // 응답 본문은 읽지 않아 Chat Completions SSE 스트림을 그대로 전달한다.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("Content-Type") || "application/octet-stream",
        "X-Content-Type-Options": "nosniff",
      },
    });
  },
};
