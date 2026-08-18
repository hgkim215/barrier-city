// Barrier City 전용 OpenAI 프록시.
// 앱이 실제로 사용하는 경로와 모델만 허용하고 입력·출력 비용을 서버에서 제한한다.
// 시크릿: OPENAI_API_KEY (wrangler secret put OPENAI_API_KEY) — 소스/앱에 저장하지 않는다.

const MAX_BODY_BYTES = 48 * 1024;
const MAX_CHAT_MESSAGES = 16;
const MAX_CHAT_MESSAGE_CHARS = 8_000;
const MAX_CHAT_TOTAL_CHARS = 32_000;
const MAX_EMBEDDING_INPUTS = 32;
const MAX_EMBEDDING_ITEM_CHARS = 2_000;
const MAX_EMBEDDING_TOTAL_CHARS = 24_000;
const REALTIME_MODEL = "gpt-realtime-2.1";

const ROUTES = {
  "/chat": {
    upstreamPath: "/v1/chat/completions",
    rateLimiter: "CHAT_RATE_LIMITER",
    sanitize: sanitizeChat,
  },
  "/embeddings": {
    upstreamPath: "/v1/embeddings",
    rateLimiter: "EMBEDDINGS_RATE_LIMITER",
    sanitize: sanitizeEmbeddings,
  },
  "/realtime-token": {
    rateLimiter: "REALTIME_RATE_LIMITER",
  },
};

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

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function finiteNumber(value, fallback, minimum, maximum) {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(maximum, Math.max(minimum, value))
    : fallback;
}

function sanitizeChat(payload) {
  if (!isRecord(payload) || payload.model !== "gpt-4o-mini") {
    throw new RequestError("model_not_allowed", "Model not allowed");
  }
  if (!Array.isArray(payload.messages) || payload.messages.length === 0 || payload.messages.length > MAX_CHAT_MESSAGES) {
    throw new RequestError("invalid_messages", `messages must contain 1-${MAX_CHAT_MESSAGES} items`);
  }

  let totalCharacters = 0;
  const messages = payload.messages.map((message) => {
    if (!isRecord(message) || !["system", "user", "assistant"].includes(message.role)) {
      throw new RequestError("invalid_message", "Each message must have an allowed role");
    }
    if (typeof message.content !== "string" || message.content.length === 0 || message.content.length > MAX_CHAT_MESSAGE_CHARS) {
      throw new RequestError("invalid_message", `Message content must contain 1-${MAX_CHAT_MESSAGE_CHARS} characters`);
    }
    totalCharacters += message.content.length;
    return { role: message.role, content: message.content };
  });
  if (totalCharacters > MAX_CHAT_TOTAL_CHARS) {
    throw new RequestError("chat_too_large", `Combined message content exceeds ${MAX_CHAT_TOTAL_CHARS} characters`);
  }

  const sanitized = {
    model: "gpt-4o-mini",
    messages,
    stream: payload.stream === true,
    max_tokens: Math.round(finiteNumber(payload.max_tokens, 180, 1, 180)),
    temperature: finiteNumber(payload.temperature, 0.7, 0, 1.2),
    frequency_penalty: finiteNumber(payload.frequency_penalty, 0, -2, 2),
  };
  if (isRecord(payload.response_format) && payload.response_format.type === "json_object") {
    sanitized.response_format = { type: "json_object" };
  }
  return sanitized;
}

function sanitizeEmbeddings(payload) {
  if (!isRecord(payload) || payload.model !== "text-embedding-3-small") {
    throw new RequestError("model_not_allowed", "Model not allowed");
  }
  const inputs = typeof payload.input === "string" ? [payload.input] : payload.input;
  if (!Array.isArray(inputs) || inputs.length === 0 || inputs.length > MAX_EMBEDDING_INPUTS) {
    throw new RequestError("invalid_embedding_input", `input must contain 1-${MAX_EMBEDDING_INPUTS} strings`);
  }
  let totalCharacters = 0;
  const sanitizedInputs = inputs.map((input) => {
    if (typeof input !== "string" || input.length === 0 || input.length > MAX_EMBEDDING_ITEM_CHARS) {
      throw new RequestError("invalid_embedding_input", `Each input must contain 1-${MAX_EMBEDDING_ITEM_CHARS} characters`);
    }
    totalCharacters += input.length;
    return input;
  });
  if (totalCharacters > MAX_EMBEDDING_TOTAL_CHARS) {
    throw new RequestError("embeddings_too_large", `Combined input exceeds ${MAX_EMBEDDING_TOTAL_CHARS} characters`);
  }
  return {
    model: "text-embedding-3-small",
    input: typeof payload.input === "string" ? sanitizedInputs[0] : sanitizedInputs,
  };
}

async function parseJSONBody(request) {
  const contentType = request.headers.get("Content-Type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new RequestError("unsupported_media_type", "application/json required", 415);
  }

  const declaredLength = Number(request.headers.get("Content-Length") || 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new RequestError("request_too_large", "Request too large", 413);
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BODY_BYTES) {
    throw new RequestError("request_too_large", "Request too large", 413);
  }
  try {
    return JSON.parse(new TextDecoder().decode(body));
  } catch {
    throw new RequestError("invalid_json", "Invalid JSON");
  }
}

async function enforceRateLimit(request, env, bindingName) {
  const limiter = env[bindingName];
  if (!limiter || typeof limiter.limit !== "function") {
    throw new RequestError("server_misconfigured", "Rate limiter is not configured", 503);
  }

  // App Attest가 없는 익명 클라이언트의 임시 공통 방어다. 모바일 NAT 오탐을 줄이도록
  // 경로별 한도를 분리하고, 원본 IP는 로그나 응답에 기록하지 않는다.
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
          // 기본 0.5보다 높은 임계값으로 작은 주변 소리와 스피커 에코를 거른다.
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
  return proxyUpstreamResponse(upstream, requestId);
}

function proxyUpstreamResponse(upstream, requestId) {
  return new Response(upstream.body, {
    status: upstream.status,
    headers: responseHeaders(
      requestId,
      upstream.headers.get("Content-Type") || "application/octet-stream",
    ),
  });
}

export { parseJSONBody, sanitizeChat, sanitizeEmbeddings };

export default {
  async fetch(request, env) {
    const requestId = request.headers.get("CF-Ray") || crypto.randomUUID();
    const { pathname } = new URL(request.url);
    const route = ROUTES[pathname];

    if (!route) return jsonResponse("not_found", "Not found", 404, requestId);
    if (request.method !== "POST") {
      return jsonResponse("method_not_allowed", "POST only", 405, requestId, { Allow: "POST" });
    }
    if (!env.OPENAI_API_KEY) {
      return jsonResponse("server_misconfigured", "Server is not configured", 503, requestId);
    }

    try {
      await enforceRateLimit(request, env, route.rateLimiter);

      if (pathname === "/realtime-token") {
        return createRealtimeClientSecret(env, requestId);
      }

      const payload = route.sanitize(await parseJSONBody(request));
      const upstream = await fetch("https://api.openai.com" + route.upstreamPath, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      return proxyUpstreamResponse(upstream, requestId);
    } catch (error) {
      if (error instanceof RequestError) {
        const extraHeaders = error.status === 429 ? { "Retry-After": "60" } : {};
        return jsonResponse(error.code, error.message, error.status, requestId, extraHeaders);
      }
      return jsonResponse("upstream_failure", "Upstream request failed", 502, requestId);
    }
  },
};
