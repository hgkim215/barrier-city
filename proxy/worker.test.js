import assert from "node:assert/strict";
import test from "node:test";

import worker, { sanitizeChat, sanitizeEmbeddings, sanitizeTTS } from "./worker.js";

function makeLimiter(success = true) {
  const keys = [];
  return {
    keys,
    async limit({ key }) {
      keys.push(key);
      return { success };
    },
  };
}

function makeEnv({ limiter = makeLimiter(), apiKey = "test-openai-key" } = {}) {
  return {
    OPENAI_API_KEY: apiKey,
    CHAT_RATE_LIMITER: limiter,
    TTS_RATE_LIMITER: limiter,
    EMBEDDINGS_RATE_LIMITER: limiter,
    REALTIME_RATE_LIMITER: limiter,
  };
}

function post(path, payload, headers = {}) {
  return new Request(`https://proxy.test${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "203.0.113.10",
      ...headers,
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  });
}

test("chat sanitizer keeps only supported fields and caps output cost", () => {
  const result = sanitizeChat({
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "안녕" }],
    stream: true,
    max_tokens: 9_999,
    temperature: 9,
    response_format: { type: "json_object", schema: "ignored" },
    tools: [{ type: "expensive-unsupported-field" }],
  });

  assert.deepEqual(result, {
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "안녕" }],
    stream: true,
    max_tokens: 180,
    temperature: 1.2,
    frequency_penalty: 0,
    response_format: { type: "json_object" },
  });
  assert.equal("tools" in result, false);
});

test("route sanitizers reject unsupported or oversized input", () => {
  assert.throws(
    () => sanitizeChat({ model: "gpt-4o", messages: [{ role: "user", content: "안녕" }] }),
    /Model not allowed/,
  );
  assert.throws(
    () => sanitizeChat({
      model: "gpt-4o-mini",
      messages: Array.from({ length: 17 }, () => ({ role: "user", content: "x" })),
    }),
    /messages must contain/,
  );
  assert.throws(
    () => sanitizeTTS({ model: "gpt-4o-mini-tts", voice: "marin", input: "안녕" }),
    /Voice not allowed/,
  );
  assert.throws(
    () => sanitizeEmbeddings({
      model: "text-embedding-3-small",
      input: Array.from({ length: 33 }, () => "chunk"),
    }),
    /input must contain/,
  );
});

test("valid TTS and embeddings payloads are normalized", () => {
  assert.deepEqual(
    sanitizeTTS({ model: "gpt-4o-mini-tts", voice: "alloy", input: "안녕하세요" }),
    { model: "gpt-4o-mini-tts", voice: "alloy", input: "안녕하세요", response_format: "wav" },
  );
  assert.deepEqual(
    sanitizeEmbeddings({ model: "text-embedding-3-small", input: "접근성" }),
    { model: "text-embedding-3-small", input: "접근성" },
  );
});

test("unknown route and wrong method are rejected before upstream", async () => {
  const notFound = await worker.fetch(post("/unknown", {}), makeEnv());
  assert.equal(notFound.status, 404);
  assert.equal((await notFound.json()).error.code, "not_found");

  const wrongMethod = await worker.fetch(new Request("https://proxy.test/chat"), makeEnv());
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get("Allow"), "POST");
});

test("rate limited request returns 429 without calling OpenAI", async () => {
  const originalFetch = globalThis.fetch;
  let upstreamCalls = 0;
  globalThis.fetch = async () => {
    upstreamCalls += 1;
    return new Response("unexpected");
  };
  try {
    const limiter = makeLimiter(false);
    const response = await worker.fetch(post("/chat", {
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "안녕" }],
    }), makeEnv({ limiter }));

    assert.equal(response.status, 429);
    assert.equal(response.headers.get("Retry-After"), "60");
    assert.equal((await response.json()).error.code, "rate_limited");
    assert.deepEqual(limiter.keys, ["203.0.113.10"]);
    assert.equal(upstreamCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("chat request forwards a sanitized body and never exposes the key", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, init) => {
    captured = { url, init };
    return new Response("data: [DONE]\n\n", {
      status: 200,
      headers: { "Content-Type": "text/event-stream" },
    });
  };
  try {
    const response = await worker.fetch(post("/chat", {
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "한 문장으로 인사해줘" }],
      stream: true,
      max_tokens: 10_000,
      tools: [{ type: "ignored" }],
    }), makeEnv());

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "text/event-stream");
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(captured.url, "https://api.openai.com/v1/chat/completions");
    assert.equal(captured.init.headers.Authorization, "Bearer test-openai-key");
    const upstreamBody = JSON.parse(captured.init.body);
    assert.equal(upstreamBody.max_tokens, 180);
    assert.equal("tools" in upstreamBody, false);
    assert.equal(await response.text(), "data: [DONE]\n\n");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("realtime token request fixes the model, modality, and voice", async () => {
  const originalFetch = globalThis.fetch;
  let capturedBody;
  globalThis.fetch = async (_url, init) => {
    capturedBody = JSON.parse(init.body);
    return Response.json({ value: "short-lived" });
  };
  try {
    const request = new Request("https://proxy.test/realtime-token", {
      method: "POST",
      headers: { "CF-Connecting-IP": "203.0.113.10" },
    });
    const response = await worker.fetch(request, makeEnv());

    assert.equal(response.status, 200);
    assert.equal(capturedBody.session.model, "gpt-realtime-2.1");
    assert.deepEqual(capturedBody.session.output_modalities, ["audio"]);
    const turnDetection = capturedBody.session.audio.input.turn_detection;
    assert.equal(turnDetection.type, "server_vad");
    assert.equal(turnDetection.threshold, 0.7);
    assert.equal(turnDetection.prefix_padding_ms, 300);
    assert.equal(turnDetection.silence_duration_ms, 700);
    assert.equal(turnDetection.create_response, true);
    assert.equal(turnDetection.interrupt_response, false);
    assert.equal(capturedBody.session.audio.output.voice, "marin");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
