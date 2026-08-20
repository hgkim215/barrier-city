import assert from "node:assert/strict";
import test from "node:test";

import worker from "./worker.js";

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
    REALTIME_RATE_LIMITER: limiter,
  };
}

function realtimeRequest(method = "POST") {
  return new Request("https://proxy.test/realtime-token", {
    method,
    headers: { "CF-Connecting-IP": "203.0.113.10" },
  });
}

test("unknown route and wrong method are rejected before upstream", async () => {
  const notFound = await worker.fetch(
    new Request("https://proxy.test/unknown", { method: "POST" }),
    makeEnv(),
  );
  assert.equal(notFound.status, 404);
  assert.equal((await notFound.json()).error.code, "not_found");

  const wrongMethod = await worker.fetch(realtimeRequest("GET"), makeEnv());
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get("Allow"), "POST");
});

test("missing API key is rejected before rate limiting", async () => {
  const limiter = makeLimiter();
  const response = await worker.fetch(
    realtimeRequest(),
    makeEnv({ limiter, apiKey: "" }),
  );

  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "server_misconfigured");
  assert.deepEqual(limiter.keys, []);
});

test("missing rate limiter is reported as server misconfiguration", async () => {
  const env = makeEnv();
  env.REALTIME_RATE_LIMITER = undefined;

  const response = await worker.fetch(realtimeRequest(), env);

  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "server_misconfigured");
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
    const response = await worker.fetch(realtimeRequest(), makeEnv({ limiter }));

    assert.equal(response.status, 429);
    assert.equal(response.headers.get("Retry-After"), "60");
    assert.equal((await response.json()).error.code, "rate_limited");
    assert.deepEqual(limiter.keys, ["203.0.113.10"]);
    assert.equal(upstreamCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("realtime token request fixes the model, modality, and voice", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, init) => {
    captured = { url, init, body: JSON.parse(init.body) };
    return Response.json({ value: "short-lived" });
  };
  try {
    const response = await worker.fetch(realtimeRequest(), makeEnv());

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(captured.url, "https://api.openai.com/v1/realtime/client_secrets");
    assert.equal(captured.init.headers.Authorization, "Bearer test-openai-key");
    assert.equal(captured.body.session.model, "gpt-realtime-2.1");
    assert.deepEqual(captured.body.session.output_modalities, ["audio"]);
    const turnDetection = captured.body.session.audio.input.turn_detection;
    assert.equal(turnDetection.type, "server_vad");
    assert.equal(turnDetection.threshold, 0.7);
    assert.equal(turnDetection.prefix_padding_ms, 300);
    assert.equal(turnDetection.silence_duration_ms, 700);
    assert.equal(turnDetection.create_response, true);
    assert.equal(turnDetection.interrupt_response, false);
    assert.equal(captured.body.session.audio.output.voice, "marin");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("unexpected upstream failures return a safe 502 response", async () => {
  const originalFetch = globalThis.fetch;
  const originalConsoleError = console.error;
  console.error = () => {};
  globalThis.fetch = async () => {
    throw new Error("network unavailable");
  };
  try {
    const response = await worker.fetch(realtimeRequest(), makeEnv());

    assert.equal(response.status, 502);
    assert.equal((await response.json()).error.code, "upstream_failure");
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalConsoleError;
  }
});
