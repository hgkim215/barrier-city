// Barrier City Realtime API 전용 OpenAI 프록시.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — 소스/앱에 저장하지 않는다.

const REALTIME_PATH = "/realtime-token";
const REALTIME_MODEL = "gpt-realtime-2.1";

class RequestError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

function responseHeaders(requestId, contentType = "application/json; charset=utf-8") {
  return {
    "Content-Type": contentType,
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-store",
    "X-Request-ID": requestId,
  };
}

function jsonResponse(code, message, status, requestId, extraHeaders = {}) {
  return new Response(JSON.stringify({ error: { code, message }, request_id: requestId }), {
    status,
    headers: { ...responseHeaders(requestId), ...extraHeaders },
  });
}

async function enforceRateLimit(request, limiter) {
  if (!limiter || typeof limiter.limit !== "function") {
    throw new RequestError("server_misconfigured", "Rate limiter is not configured", 503);
  }

  // App Attest가 없는 익명 클라이언트의 임시 공통 방어다. 원본 IP는 로그나 응답에 기록하지 않는다.
  const actor = request.headers.get("CF-Connecting-IP") || "unknown-client";
  const { success } = await limiter.limit({ key: actor });
  if (!success) {
    throw new RequestError("rate_limited", "Too many requests", 429);
  }
}

async function createRealtimeClientSecret(env, requestId) {
  const body = JSON.stringify({
    session: {
      type: "realtime",
      model: REALTIME_MODEL,
      output_modalities: ["audio"],
      audio: {
        input: {
          // 기본값보다 높은 임계값으로 작은 주변 소리와 스피커 에코를 거른다.
          turn_detection: {
            type: "server_vad",
            threshold: 0.7,
            prefix_padding_ms: 300,
            silence_duration_ms: 700,
            create_response: true,
            interrupt_response: false,
          },
        },
        output: { voice: "marin" },
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
    headers: responseHeaders(
      requestId,
      upstream.headers.get("Content-Type") || "application/octet-stream",
    ),
  });
}

export default {
  async fetch(request, env) {
    const requestId = request.headers.get("CF-Ray") || crypto.randomUUID();
    const { pathname } = new URL(request.url);

    if (pathname !== REALTIME_PATH) {
      return jsonResponse("not_found", "Not found", 404, requestId);
    }
    if (request.method !== "POST") {
      return jsonResponse("method_not_allowed", "POST only", 405, requestId, { Allow: "POST" });
    }
    if (!env.OPENAI_API_KEY) {
      return jsonResponse("server_misconfigured", "Server is not configured", 503, requestId);
    }

    try {
      await enforceRateLimit(request, env.REALTIME_RATE_LIMITER);
      return await createRealtimeClientSecret(env, requestId);
    } catch (error) {
      if (error instanceof RequestError) {
        const extraHeaders = error.status === 429 ? { "Retry-After": "60" } : {};
        return jsonResponse(error.code, error.message, error.status, requestId, extraHeaders);
      }
      console.error(JSON.stringify({
        message: "realtime token request failed",
        error: error instanceof Error ? error.message : String(error),
        request_id: requestId,
      }));
      return jsonResponse("upstream_failure", "Upstream request failed", 502, requestId);
    }
  },
};
