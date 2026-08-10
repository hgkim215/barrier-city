// Barrier City 전용 OpenAI 프록시.
// 앱이 실제로 사용하는 경로와 모델만 허용해 개인 API 키의 오용 범위를 줄인다.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — 소스/앱에 저장하지 않는다.

const MAX_BODY_BYTES = 128 * 1024;
const REALTIME_MODEL = "gpt-realtime-2.1";

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
      "Cache-Control": "no-store",
    },
  });
}

async function createRealtimeClientSecret(env) {
  // 앱이 모델이나 세션 종류를 바꿔 프록시를 범용 OpenAI 게이트웨이로 쓰지 못하도록
  // 세션의 민감한 기본값은 신뢰할 수 있는 Worker에서 고정한다.
  const body = JSON.stringify({
    session: {
      type: "realtime",
      model: REALTIME_MODEL,
      output_modalities: ["audio"],
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24000 },
          turn_detection: {
            type: "semantic_vad",
            eagerness: "low",
            create_response: true,
            interrupt_response: true,
          },
        },
        output: {
          format: { type: "audio/pcm", rate: 24000 },
          voice: "marin",
        },
      },
    },
  });

  const upstream = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body,
  });

  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "Content-Type": upstream.headers.get("Content-Type") || "application/json",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-store",
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return jsonResponse({ error: "POST only" }, 405);
    }

    if (!env.OPENAI_API_KEY) {
      return jsonResponse({ error: "Server is not configured" }, 503);
    }

    if (url.pathname === "/realtime-token") {
      return createRealtimeClientSecret(env);
    }

    const route = ROUTES[url.pathname];
    if (!route) return jsonResponse({ error: "Not found" }, 404);

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
