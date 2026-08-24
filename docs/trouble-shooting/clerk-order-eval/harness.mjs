// 점원 NPC Realtime 대화의 "주문 케이스" LLM 평가 하네스.
// 실제 앱과 동일한 시스템 프롬프트(PromptDumpTool로 뽑음)와 도구 스키마, 그리고
// RealtimeMissionCoordinator의 게임 상태 로직을 그대로 이식해, 실제 WebSocket으로
// Realtime API를 호출하며 다양한 주문 시나리오를 검증한다. 오디오 없이 텍스트만 쓴다.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROXY_TOKEN_URL = "https://barrier-city-openai-proxy.roiyeon.workers.dev/realtime-token";
const dump = JSON.parse(readFileSync(path.join(__dirname, "prompt_dump.json"), "utf8"));

const TOOLS = [
  {
    type: "function",
    name: "report_order_attempt",
    description: "방문자가 어떤 식으로든 아무 품목이나 음료를 달라고/가져다 달라고/주문하려고 하는 그 순간 호출하라 — 미션 품목이 아닌 다른 품목이어도 상관없다. 서로 다른 주문 시도마다 한 번씩, place_mission_order보다 먼저, 말을 하기 전에 호출하라. place_mission_order와 같은 응답 안에서는 절대 호출하지 마라.",
    parameters: { type: "object", properties: {}, required: [], additionalProperties: false },
  },
  {
    type: "function",
    name: "place_mission_order",
    description: "방문자가 명확히 주문했고, 키오스크 리다이렉트 이후 본인이 직접 키오스크를 쓸 수 없는 이유(단순 반복 요청이 아니라 실제 접근성 장벽)를 설명했을 때 레인보우 마카롱 스무디를 정확히 한 잔 접수하라. 항상 호출 가능하지만, 품목·수량이 안 맞거나 이미 주문이 접수됐거나 이 만남에서 아직 첫 주문 시도의 키오스크 리다이렉트가 없었다면(그 경우엔 대신 report_order_attempt를 호출하라) 앱이 모든 호출을 검증해 거절한다. 주문이 확실하다고 판단되는 즉시 호출하라 — 추가 확인을 기다리지 마라.",
    parameters: {
      type: "object",
      properties: {
        item: { type: "string", description: "요청받은 표준 메뉴 품목.", enum: [dump.itemIdentifier] },
        quantity: { type: "integer", description: "명시적으로 요청받은 잔 수.", minimum: dump.quantity, maximum: dump.quantity },
      },
      required: ["item", "quantity"],
      additionalProperties: false,
    },
  },
];

// ---- RealtimeMissionCoordinator 로직을 그대로 이식(Swift 원본과 1:1 대응) ----
function makeCoordinator() {
  return { orderPlaced: false, hasRedirected: false, visitorTurns: 0, pending: null };
}
function promptGuide(c) {
  return `# 앱이 관리하는 미션 상태\n- ORDER_PLACED=${c.orderPlaced}\n- FIRST_ORDER_ATTEMPT_REDIRECTED_TO_KIOSK=${c.hasRedirected}\n- VISITOR_TURNS_SINCE_KIOSK_REDIRECT=${c.visitorTurns}\n이 상태는 오직 미션 주문에 대해서만 절대적 기준이다. 평범한 대화까지 제약해서는 안 된다.`;
}
function registerVisitorTurn(c) {
  if (c.hasRedirected && !c.orderPlaced) c.visitorTurns += 1;
}
function registerFunctionCall(c, name, args) {
  if (name === "report_order_attempt") {
    const isFirst = !c.hasRedirected;
    c.hasRedirected = true;
    return {
      success: true,
      accepted: isFirst,
      followUp: isFirst
        ? `방문자가 이 만남에서 처음으로 뭔가(어떤 품목이든)를 주문하려 했다. 지금은 일하느라 너무 바빠서 응대할 수 없다. 그렇게 말하며 키오스크를 가리키되, 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 — 예를 들면(그대로 반복하지 말고 표현을 바꿔서): "지금 좀 정신없어서요. 주문은 저기 키오스크에서 해주시겠어요?" 사과하거나, 다른 대안을 제시하거나, 이 규칙을 나중에 다시 언급하지 마라. 방문자가 이미 같은 호흡에 키오스크를 못 쓰는 이유를 설명했더라도, 이번 턴은 여전히 순수하게 거절/리다이렉트 대사여야 한다 — "알겠어요", "받아둘게요", "그거 하나만요" 같이 승낙하는 것처럼 들리는 표현은 이번 턴에 절대 쓰지 마라. 실제 승낙은 place_mission_order가 성공한 다음 턴에만 한다.`
        : `앱이 이 만남에서 이전에 있었던 주문 시도를 이미 기록해 두었다. 키오스크 안내를 반복하지 말고, 정확히 두 개의 짧고 자연스러운 한국어 문장으로 자연스럽게 대화를 이어가라.`,
    };
  }
  if (name === "place_mission_order") {
    if (c.orderPlaced) {
      return { success: false, accepted: false, message: "order already placed", followUp: `앱이 이 방문자의 주문을 이 만남에서 이미 조금 전에 접수했다. 함수를 다시 호출하지 마라. 주문을 반복하지 말고 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 계속 대화하라 — 예를 들면(표현을 바꿔서) "그거 이미 넣었어요."` };
    }
    if (!c.hasRedirected) {
      c.hasRedirected = true;
      return { success: false, accepted: false, message: "first attempt must be redirected to the kiosk", followUp: `방문자가 뭔가를 주문하려는 것이 이 만남에서 처음이다. 앱이 이 함수 호출을 일부러 거절했다. 지금은 바빠서 어렵다고 말하며 키오스크를 가리키되, 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 — 예를 들면(표현을 바꿔서): "저 지금 손이 모자라서요. 주문은 키오스크 이용해 주시겠어요?" 사과하거나 다른 대안을 제시하지 말고, 방문자가 다시 시도해도 이 규칙을 반복해서 말하지 마라.` };
    }
    let parsed;
    try { parsed = JSON.parse(args); } catch { parsed = null; }
    const valid = parsed && parsed.item === dump.itemIdentifier && parsed.quantity === dump.quantity;
    if (!valid) {
      return { success: false, accepted: false, message: "mission order validation failed", followUp: `품목이나 수량이 레인보우 마카롱 스무디 정확히 한 잔과 맞지 않아 앱이 주문을 접수하지 않았다. 기술적인 내용을 드러내거나 성공했다고 말하지 말고, 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 — 예를 들면(표현을 바꿔서) "어, 그건 좀 다른데요. 다시 한번 말씀해 주시겠어요?" — 계속 대화하라.` };
    }
    c.orderPlaced = true;
    return {
      success: true,
      accepted: true,
      item: dump.itemIdentifier,
      quantity: dump.quantity,
      followUp: `앱이 레인보우 마카롱 스무디 한 잔 주문을 검증하고 접수했다. 원해서가 아니라 방문자가 방금 본인이 왜 직접 키오스크를 쓸 수 없는지 설명해서 마지못해 받아주는 것이다. 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 살짝 짜증을 내거나 짧은 한숨을 섞어 마지못해 확인해 주고, 준비되면 알려주겠다고 말하라 — 예를 들면(표현을 바꿔서): "하... 알겠어요. 그거 하나만요, 되면 불러드릴게요." 다정하거나 매끄럽거나 사과하는 투로 말하지 말고, 음료가 이미 준비됐다거나 함수·JSON을 언급하지 마라.`,
    };
  }
  return { success: false, accepted: false, message: "unknown function", followUp: "" };
}

// ---- 어색한 말투 회귀 검사(이번 세션에서 고친 패턴들) ----
const AWKWARD_PATTERNS = [
  /확인할게요.{0,6}(처리|과정|절차)/,
  /(처리|과정|절차).{0,6}확인/,
  /그.{0,4}설명이면\s*충분/,
  /그거면\s*충분/,
  /판단(했|하겠|할게)/,
  /시스템/,
  /함수/,
  /JSON/i,
  /처리해(볼게요|드릴게요|드리겠)/,
  /가능한\s*선에서/,
  /요청하신\s*내용에?\s*맞춰/,
];
function findAwkwardPhrases(text) {
  return AWKWARD_PATTERNS.filter((re) => re.test(text)).map((re) => re.source);
}

// ---- WebSocket 저수준 헬퍼 ----
async function mintToken(retries = 5) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    const res = await fetch(PROXY_TOKEN_URL, { method: "POST" });
    if (res.ok) {
      const json = await res.json();
      return { value: json.value, model: json.session?.model ?? "gpt-realtime" };
    }
    if (res.status === 429 && attempt < retries) {
      const backoff = 500 * Math.pow(2, attempt) + Math.random() * 250;
      await new Promise((r) => setTimeout(r, backoff));
      continue;
    }
    throw new Error(`token fetch failed: ${res.status}`);
  }
  throw new Error("token fetch failed: exhausted retries");
}

async function openSession(personaKey) {
  const { value, model } = await mintToken();
  const url = `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`;
  const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${value}` } });

  return await new Promise((resolve, reject) => {
    const ready = { resolved: false };
    const timeout = setTimeout(() => {
      if (!ready.resolved) { ready.resolved = true; reject(new Error("session open timeout")); }
    }, 20000);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({
        type: "session.update",
        session: {
          type: "realtime",
          instructions: dump.personaInstructions[personaKey],
          tool_choice: "auto",
          tools: TOOLS,
        },
      }));
    });
    ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === "session.updated" && !ready.resolved) {
        ready.resolved = true;
        clearTimeout(timeout);
        resolve(ws);
      }
      if (msg.type === "error" && !ready.resolved) {
        ready.resolved = true;
        clearTimeout(timeout);
        reject(new Error(`session error: ${JSON.stringify(msg)}`));
      }
    });
    ws.addEventListener("error", (event) => {
      if (!ready.resolved) { ready.resolved = true; clearTimeout(timeout); reject(new Error(String(event.message ?? event))); }
    });
    ws.addEventListener("close", (event) => {
      if (!ready.resolved) { ready.resolved = true; clearTimeout(timeout); reject(new Error(`closed before ready: ${event.code} ${event.reason}`)); }
    });
  });
}

/// 하나의 response.create를 보내고, response.done까지의 텍스트+함수호출을 모은다.
function runResponseOnce(ws, { instructions, toolChoice, tools }) {
  return new Promise((resolve, reject) => {
    let text = "";
    let functionCall = null;
    const timeout = setTimeout(() => reject(new Error("response timeout")), 30000);
    const handler = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === "response.output_text.delta") text += msg.delta;
      if (msg.type === "response.function_call_arguments.done") {
        functionCall = { name: msg.name, callId: msg.call_id, arguments: msg.arguments ?? "{}" };
      }
      if (msg.type === "response.done") {
        clearTimeout(timeout);
        ws.removeEventListener("message", handler);
        if (msg.response?.status === "failed") {
          const error = new Error(`response failed: ${JSON.stringify(msg.response.status_details ?? msg.response)}`);
          error.rateLimited = JSON.stringify(msg.response).includes("rate_limit");
          reject(error);
          return;
        }
        resolve({ text, functionCall });
      }
      if (msg.type === "error") {
        clearTimeout(timeout);
        ws.removeEventListener("message", handler);
        const error = new Error(`api error: ${JSON.stringify(msg)}`);
        error.rateLimited = JSON.stringify(msg).includes("rate_limit");
        reject(error);
      }
    };
    ws.addEventListener("message", handler);
    const payload = { type: "response.create", response: { output_modalities: ["text"], tool_choice: toolChoice } };
    if (instructions) payload.response.instructions = instructions;
    if (tools) payload.response.tools = tools;
    ws.send(JSON.stringify(payload));
  });
}

/// TPM(분당 토큰) 레이트리밋에 걸리면 실제로 한도가 리셋될 시간만큼 기다렸다가 같은
/// response.create를 다시 보낸다 — "1ms 뒤 재시도" 안내를 그대로 믿으면 한도가 꽉 찬
/// 상태라 즉시 또 걸린다.
async function runResponse(ws, options, retries = 6) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await runResponseOnce(ws, options);
    } catch (error) {
      if (error.rateLimited && attempt < retries) {
        const backoff = 12000 + Math.random() * 4000;
        process.stderr.write(`  rate limited, waiting ${Math.round(backoff / 1000)}s before retry (attempt ${attempt + 1}/${retries})...\n`);
        await new Promise((r) => setTimeout(r, backoff));
        continue;
      }
      throw error;
    }
  }
}

function sendUserText(ws, text) {
  ws.send(JSON.stringify({
    type: "conversation.item.create",
    item: { type: "message", role: "user", content: [{ type: "input_text", text }] },
  }));
}

function sendFunctionOutput(ws, callId, output) {
  ws.send(JSON.stringify({
    type: "conversation.item.create",
    item: { type: "function_call_output", call_id: callId, output },
  }));
}

/// 시나리오 하나를 처음부터 끝까지 실행한다. turns: 방문자 발화 문자열 배열.
/// expectByTurn: turn index(0-based, 방문자 발화 기준) -> 기대치 체커 함수(state, callInfo) -> {pass, note}
async function runScenario(scenario) {
  const log = [];
  const coordinator = makeCoordinator();
  const findings = [];
  let ws;
  try {
    ws = await openSession(scenario.persona);

    // 오프닝 인사(실제 앱과 동일하게 tool_choice none)
    const opening = await runResponse(ws, {
      instructions: `${dump.personaInstructions[scenario.persona]}\n\n# 앱이 관리하는 이번 응답의 대화 단계\n${dump.openingInstructionsNew}`,
      toolChoice: "none",
    });
    log.push({ role: "clerk(opening)", text: opening.text });

    for (let i = 0; i < scenario.turns.length; i++) {
      const userText = scenario.turns[i];
      log.push({ role: "visitor", text: userText });
      sendUserText(ws, userText);
      registerVisitorTurn(coordinator);

      let result = await runResponse(ws, {
        instructions: `${dump.personaInstructions[scenario.persona]}\n\n${promptGuide(coordinator)}`,
        toolChoice: "auto",
        tools: TOOLS,
      });

      let callInfo = null;
      if (result.functionCall) {
        const { name, callId, arguments: args } = result.functionCall;
        const outcome = registerFunctionCall(coordinator, name, args);
        callInfo = { name, args, outcome };
        log.push({ role: "clerk(function_call)", text: `${name}(${args}) -> ${JSON.stringify({ success: outcome.success, accepted: outcome.accepted })}` });
        sendFunctionOutput(ws, callId, JSON.stringify({ success: outcome.success, ...(outcome.item ? { item: outcome.item, quantity: outcome.quantity } : {}), ...(outcome.message ? { message: outcome.message } : {}) }));
        result = await runResponse(ws, {
          instructions: `${dump.personaInstructions[scenario.persona]}\n\n${promptGuide(coordinator)}\n\n# 방금 나온 도구 호출 결과에 대한 응답\n${outcome.followUp}`,
          toolChoice: "none",
        });
      }
      log.push({ role: "clerk", text: result.text });

      const awkward = findAwkwardPhrases(result.text);
      if (awkward.length > 0) {
        findings.push({ turn: i, kind: "awkward_phrase", detail: awkward, text: result.text });
      }

      const checker = scenario.expectByTurn?.[i];
      if (checker) {
        const verdict = checker(coordinator, callInfo, result.text);
        findings.push({ turn: i, kind: "expectation", ...verdict });
      }
    }

    if (scenario.expectFinal) {
      const verdict = scenario.expectFinal(coordinator);
      findings.push({ turn: "final", kind: "expectation", ...verdict });
    }
  } catch (error) {
    findings.push({ turn: "error", kind: "error", pass: false, note: String(error?.message ?? error) });
  } finally {
    try { ws?.close(); } catch {}
  }

  const failed = findings.filter((f) => f.pass === false);
  return {
    id: scenario.id,
    category: scenario.category,
    persona: scenario.persona,
    verdict: failed.length > 0 ? "FAIL" : "PASS",
    findings,
    log,
    finalState: coordinator,
  };
}

async function runAll(scenarios, concurrency) {
  const results = new Array(scenarios.length);
  let next = 0;
  async function worker() {
    while (next < scenarios.length) {
      const idx = next++;
      const s = scenarios[idx];
      process.stderr.write(`[${idx + 1}/${scenarios.length}] running ${s.id}...\n`);
      try {
        results[idx] = await runScenario(s);
      } catch (error) {
        results[idx] = { id: s.id, category: s.category, persona: s.persona, verdict: "ERROR", findings: [{ kind: "error", pass: false, note: String(error) }], log: [] };
      }
      process.stderr.write(`[${idx + 1}/${scenarios.length}] ${s.id} -> ${results[idx].verdict}\n`);
    }
  }
  const workers = Array.from({ length: concurrency }, (_, i) =>
    new Promise((r) => setTimeout(r, i * 400)).then(worker));
  await Promise.all(workers);
  return results;
}

export { runAll, runScenario };
