// 점원 대화 주문 케이스 시나리오 배터리. 전부 서로 다른 발화/조합으로 ~100개를 구성한다.
const PERSONAS = ["ableist_hurried_neutral", "ableist_blunt_dismissive", "inclusive_chatty_warm", "ableist_cautious_hostile"];
function personaFor(i) { return PERSONAS[i % PERSONAS.length]; }

const scenarios = [];
function add(s) { scenarios.push(s); }

// ---- A. 첫 주문 시도 → 반드시 키오스크 리다이렉트, 성공 금지 ----
const firstAttemptOpeners = [
  "저기, 레인보우 마카롱 스무디 하나 주세요.",
  "스무디 하나 주문할 수 있을까요?",
  "저... 그 스무디라는 거, 하나 살 수 있나요?",
  "레인보우 마카롱 스무디 한 잔 주문할게요.",
  "여기 스무디 파나요? 하나 주세요.",
  "저 스무디 하나만 만들어 주실 수 있어요?",
  "혹시 지금 주문 가능한가요? 스무디로요.",
  "스무디 하나 부탁드려요.",
  "저 여기서 스무디 살 수 있어요?",
  "레인보우 스무디 하나 받을 수 있을까요?",
];
firstAttemptOpeners.forEach((opener, i) => {
  add({
    id: `A_first_attempt_redirect_${i}`,
    category: "A_first_attempt_redirect",
    persona: personaFor(i),
    turns: [opener],
    expectByTurn: {
      0: (state, call) => ({
        pass: state.hasRedirected && !state.orderPlaced,
        note: `redirected=${state.hasRedirected}, orderPlaced=${state.orderPlaced}, call=${call?.name ?? "none"}`,
      }),
    },
  });
});

// ---- B. 리다이렉트 후 장벽 설명 → 성공 ----
const barrierExplanations = [
  "제가 휠체어를 타고 있어서 키오스크 화면에 손이 안 닿아요.",
  "휠체어 이용자라 저 키오스크 높이에서는 버튼을 못 눌러요.",
  "손이 키오스크까지 닿지 않아서 그런데, 대신 주문해 주실 수 있을까요?",
  "제가 팔을 못 써서 터치스크린 조작이 어려워요.",
  "휠체어에서는 저 화면이 너무 높아서 안 보여요.",
  "제가 시각장애가 있어서 키오스크 화면을 못 봐요.",
  "손 떨림이 있어서 터치가 잘 안 눌려요, 키오스크로는.",
  "휠체어라 키오스크 앞에 아예 접근이 안 돼요.",
  "제 키가 낮은 휠체어라 화면이 안 닿아요.",
  "손가락을 잘 못 움직여서 터치스크린은 어려워요.",
];
barrierExplanations.forEach((explanation, i) => {
  add({
    id: `B_redirect_then_valid_barrier_${i}`,
    category: "B_redirect_then_valid_barrier",
    persona: personaFor(i + 1),
    turns: [firstAttemptOpeners[i % firstAttemptOpeners.length], explanation],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected && !state.orderPlaced, note: "first attempt redirected" }),
      1: (state, call) => ({
        pass: state.orderPlaced,
        note: `after explanation: orderPlaced=${state.orderPlaced}, call=${call?.name ?? "none"}`,
      }),
    },
  });
});

// ---- C. 리다이렉트 후 설명 없이 반복 → 계속 거절, 턴 누적 후(2턴) 약한 설명도 관대 ----
const weakExplanations = [
  "그냥 안 되는데요.",
  "아무튼 저는 키오스크 못 써요.",
  "그게 좀 힘들어서 그래요.",
  "제 사정이 있어서 그런데요.",
  "여러 이유로 어려워요, 키오스크는.",
];
weakExplanations.forEach((weak, i) => {
  add({
    id: `C_repeat_then_lenient_after_two_turns_${i}`,
    category: "C_repeat_then_lenient_after_two_turns",
    persona: personaFor(i + 2),
    turns: [
      firstAttemptOpeners[i],
      "그럼 스무디 하나만 주세요.",
      "다시 한번요, 스무디 하나요.",
      weak,
    ],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
      1: (state) => ({ pass: !state.orderPlaced, note: "plain repeat without explanation must still be rejected" }),
      2: (state) => ({ pass: !state.orderPlaced, note: "second repeat still rejected" }),
      3: (state) => ({
        pass: state.orderPlaced,
        note: `VISITOR_TURNS reached 2+ by now, weak explanation should be accepted leniently; orderPlaced=${state.orderPlaced}`,
      }),
    },
  });
});

// ---- D. 잘못된 품목 ----
const otherItems = ["라떼 하나 주세요.", "아메리카노 하나요.", "카푸치노 한 잔 주세요.", "그냥 커피 아무거나요.", "핫초코 하나 주세요."];
otherItems.forEach((item, i) => {
  add({
    id: `D_wrong_item_rejected_${i}`,
    category: "D_wrong_item_rejected",
    persona: personaFor(i + 3),
    turns: [firstAttemptOpeners[i], barrierExplanations[i], item],
    expectByTurn: {
      1: (state) => ({ pass: state.orderPlaced, note: "smoothie order placed first" }),
      2: (state, call) => ({
        pass: !call || call.name !== "place_mission_order" || call.outcome.accepted === false,
        note: `asking for a different item after order placed should not create a second successful order; call=${JSON.stringify(call)}`,
      }),
    },
  });
});

// ---- E. 두 잔 요청 ----
const twoQuantityFollowUps = ["그럼 한 잔만 할게요.", "네, 한 잔이면 돼요.", "알겠어요, 한 잔으로요.", "그래요, 하나만 주세요.", "네 한 잔으로 부탁해요."];
twoQuantityFollowUps.forEach((followUp, i) => {
  add({
    id: `E_two_then_one_quantity_${i}`,
    category: "E_two_then_one_quantity",
    persona: personaFor(i),
    turns: [firstAttemptOpeners[i], barrierExplanations[i], "두 잔 주세요.", followUp],
    expectByTurn: {
      2: (state) => ({ pass: !state.orderPlaced, note: "two-quantity request should not place order as-is" }),
      3: (state) => ({ pass: state.orderPlaced, note: "after clarifying to one, order should succeed" }),
    },
  });
});

// ---- F. 줄여 부른 이름은 진짜 주문으로 안 침 ----
const shortenedNames = ["레인보우 스무디 하나요.", "그 스무디 하나 주세요.", "무지개 스무디 하나요.", "스무디요, 그거 하나.", "레인보우 하나 주세요."];
shortenedNames.forEach((short, i) => {
  add({
    id: `F_shortened_name_not_real_order_${i}`,
    category: "F_shortened_name_not_real_order",
    persona: personaFor(i + 1),
    turns: [short],
    expectByTurn: {
      0: (state) => ({
        pass: !state.orderPlaced,
        note: `shortened/colloquial name alone should not place a real order; orderPlaced=${state.orderPlaced}`,
      }),
    },
  });
});

// ---- G. 단순 질문/잡담은 함수 호출 없음 ----
const smallTalkOnly = [
  ["오늘 날씨 좋네요.", "카페가 아늑하네요."],
  ["여기 원두는 어디서 가져와요?", "향이 좋네요."],
  ["오래 일하셨어요?", "바쁘시겠어요."],
  ["메뉴에 뭐가 있어요?", "스무디는 어떤 맛이에요?"],
  ["여기 자리 많네요.", "사람이 별로 없네요."],
];
smallTalkOnly.forEach((turns, i) => {
  add({
    id: `G_small_talk_no_function_call_${i}`,
    category: "G_small_talk_no_function_call",
    persona: personaFor(i + 2),
    turns,
    expectByTurn: {
      0: (state, call) => ({ pass: !call, note: `small talk should not trigger any function call; call=${call?.name ?? "none"}` }),
      1: (state, call) => ({ pass: !call, note: `small talk should not trigger any function call; call=${call?.name ?? "none"}` }),
    },
  });
});

// ---- H. 잡담 후 주문(함수 호출은 주문 순간에만) ----
const offTopicThenOrder = [
  ["여기 인테리어 예쁘네요.", "그나저나 스무디 하나 주문할 수 있을까요?"],
  ["오늘 손님 많아요?", "저 스무디 하나 사고 싶은데요."],
  ["원두 향이 좋네요.", "스무디 하나 주문해도 될까요?"],
  ["날씨가 덥네요.", "시원한 스무디 하나 주세요."],
  ["요즘 장사 잘 돼요?", "저 스무디 하나 부탁드려요."],
];
offTopicThenOrder.forEach((turns, i) => {
  add({
    id: `H_offtopic_then_order_${i}`,
    category: "H_offtopic_then_order",
    persona: personaFor(i + 3),
    turns,
    expectByTurn: {
      0: (state, call) => ({ pass: !call, note: `off-topic turn should not trigger a function call; call=${call?.name ?? "none"}` }),
      1: (state) => ({ pass: state.hasRedirected, note: "the actual order attempt (turn 2) should trigger the kiosk redirect" }),
    },
  });
});

// ---- I. 같은 호흡에 주문+장벽 설명을 같이 함 ----
const sameBreath = [
  "저 휠체어라 키오스크가 안 닿아서 그러는데, 스무디 하나만 주문할 수 있을까요?",
  "손을 잘 못 써서 키오스크 조작이 어려운데 스무디 하나 살 수 있을까요?",
  "휠체어 이용자라 저 화면에 손이 안 닿는데, 스무디 하나 부탁드려도 될까요?",
  "제가 시각장애가 있어서 키오스크를 못 보는데, 스무디 하나 주문하고 싶어요.",
  "휠체어 높이가 낮아서 키오스크가 안 보이는데, 스무디 하나 주세요.",
];
sameBreath.forEach((combined, i) => {
  add({
    id: `I_same_breath_order_and_barrier_${i}`,
    category: "I_same_breath_order_and_barrier",
    persona: personaFor(i),
    turns: [combined, "네, 스무디 하나 부탁드려요."],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected, note: "first turn (even with explanation attached) is still redirected per app rule" }),
      1: (state) => ({
        pass: state.orderPlaced,
        note: `since the barrier was already explained in the same breath, the very next attempt should succeed without demanding a fresh explanation; orderPlaced=${state.orderPlaced}`,
      }),
    },
  });
});

// ---- J. 주문 완료 후 중복 주문 시도 ----
weakExplanations.forEach((_, i) => {
  add({
    id: `J_duplicate_order_after_success_${i}`,
    category: "J_duplicate_order_after_success",
    persona: personaFor(i + 1),
    turns: [firstAttemptOpeners[i + 5], barrierExplanations[i + 5], "스무디 하나 더 주세요."],
    expectByTurn: {
      1: (state) => ({ pass: state.orderPlaced, note: "first order placed" }),
      2: (state, call) => ({
        pass: !call || call.outcome.accepted === false,
        note: `requesting a second smoothie after one was already placed should be rejected; call=${JSON.stringify(call)}`,
      }),
    },
  });
});

// ---- K. 무례한/조급한 태도에서도 로직은 정확해야 함(안전/톤은 육안 검수) ----
const hostileOpeners = [
  "야, 스무디 하나 빨리 줘봐.",
  "아 진짜 빨리 좀 줘요, 스무디.",
  "언제까지 기다려야 돼요? 스무디 달라니까요.",
  "답답하게 왜 이래요, 그냥 스무디 하나 주세요.",
  "빨리빨리 좀 해요, 스무디 하나요.",
];
hostileOpeners.forEach((opener, i) => {
  add({
    id: `K_hostile_tone_${i}`,
    category: "K_hostile_tone",
    persona: personaFor(i + 2),
    turns: [opener, barrierExplanations[i + 2] ?? barrierExplanations[i]],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected, note: "still redirected despite hostile tone" }),
      1: (state) => ({ pass: state.orderPlaced, note: "still succeeds with a valid explanation despite hostile tone" }),
    },
  });
});

// ---- L. 다른 직원을 부를 수 있는지 묻는 경우 ----
const askForSomeoneElse = [
  "다른 직원분 계세요? 그분한테 부탁드리고 싶은데.",
  "매니저님 불러주실 수 있어요?",
  "혹시 다른 분이 도와주실 수 있나요?",
  "동료분은 안 계세요?",
  "다른 분한테 여쭤봐도 될까요?",
];
askForSomeoneElse.forEach((ask, i) => {
  add({
    id: `L_asks_for_another_staff_${i}`,
    category: "L_asks_for_another_staff",
    persona: personaFor(i),
    turns: [ask],
    expectByTurn: {
      0: (state, call, text) => ({
        pass: !/매니저|동료|다른\s*직원.{0,6}(불러|부를|올게|와서)/.test(text) || /혼자|저뿐|저만|없/.test(text),
        note: "should say they're the only staff, not offer to fetch someone else",
      }),
    },
  });
});

// ---- M. 코드 스위칭/혼합 언어 ----
const mixedLanguage = [
  "저 disability 있어서 kiosk 못 써요, smoothie 하나 주문할게요.",
  "wheelchair라서 키오스크 accessible 하지 않아요. 스무디 하나요.",
  "저 handicap 있어서요, 스무디 order 하고 싶어요.",
];
mixedLanguage.forEach((text, i) => {
  add({
    id: `M_mixed_language_${i}`,
    category: "M_mixed_language",
    persona: personaFor(i),
    turns: [text, "네 맞아요, 그래서 부탁드려요."],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected, note: "redirected even with code-switched phrasing" }),
    },
  });
});

// ---- N. 짧고 단답형 발화 ----
add({
  id: "N_terse_utterances_0",
  category: "N_terse_utterances",
  persona: "ableist_hurried_neutral",
  turns: ["스무디요.", "휠체어라서요.", "네."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "terse order attempt still redirected" }),
  },
});
add({
  id: "N_terse_utterances_1",
  category: "N_terse_utterances",
  persona: "ableist_blunt_dismissive",
  turns: ["주문요.", "손이 안 닿아요.", "네 그거요."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "terse order attempt still redirected" }),
  },
});

// ---- O. 설명 전에 필러/망설임 턴이 끼어드는 경우 ----
add({
  id: "O_filler_before_explanation_0",
  category: "O_filler_before_explanation",
  persona: "inclusive_chatty_warm",
  turns: ["스무디 하나 주세요.", "음... 그러니까...", "제가 휠체어라 키오스크에 손이 안 닿아서요."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
    1: (state) => ({ pass: !state.orderPlaced, note: "filler turn alone should not place the order" }),
    2: (state) => ({ pass: state.orderPlaced, note: "real explanation on the next turn should succeed" }),
  },
});
add({
  id: "O_filler_before_explanation_1",
  category: "O_filler_before_explanation",
  persona: "ableist_cautious_hostile",
  turns: ["스무디 하나요.", "아... 어떻게 설명하지...", "휠체어 이용자라 키오스크 사용이 안 돼요."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
    1: (state) => ({ pass: !state.orderPlaced, note: "filler turn alone should not place the order" }),
    2: (state) => ({ pass: state.orderPlaced, note: "real explanation should succeed" }),
  },
});

// ---- P. 리다이렉트 후 포기 ----
add({
  id: "P_gives_up_after_redirect_0",
  category: "P_gives_up_after_redirect",
  persona: "ableist_hurried_neutral",
  turns: ["스무디 하나 주세요.", "아 됐어요, 안 할게요."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
    1: (state) => ({ pass: !state.orderPlaced, note: "giving up should not place an order" }),
  },
});
add({
  id: "P_gives_up_after_redirect_1",
  category: "P_gives_up_after_redirect",
  persona: "ableist_blunt_dismissive",
  turns: ["레인보우 마카롱 스무디 주세요.", "그냥 다음에 올게요."],
  expectByTurn: {
    0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
    1: (state) => ({ pass: !state.orderPlaced, note: "giving up should not place an order" }),
  },
});

// ---- Q. 애매/석연찮은 이유(관용 기준 관찰용, 실패로 채점하지 않고 관찰만) ----
const vagueReasons = ["그냥 하기 싫어서요.", "그냥요, 이유는 없어요.", "그건 좀 곤란해서요."];
vagueReasons.forEach((reason, i) => {
  add({
    id: `Q_vague_reason_observe_${i}`,
    category: "Q_vague_reason_observe",
    persona: personaFor(i),
    turns: [firstAttemptOpeners[i + 2], reason],
    expectByTurn: {
      1: (state) => ({ pass: true, note: `OBSERVE ONLY: vague/implausible reason -> orderPlaced=${state.orderPlaced} (no strict expectation, prompt says plausibility bar is low)` }),
    },
  });
});

// ---- R. 주문 완료 후 준비 상태를 물어봄(함수 재호출 없이 대화만) ----
const readinessChecks = ["이거 언제 나와요?", "얼마나 걸려요, 스무디?", "다 됐어요?", "곧 나오나요?", "얼마나 기다려야 돼요?"];
readinessChecks.forEach((ask, i) => {
  add({
    id: `R_readiness_check_after_order_${i}`,
    category: "R_readiness_check_after_order",
    persona: personaFor(i + 1),
    turns: [firstAttemptOpeners[i + 3], barrierExplanations[i + 3], ask],
    expectByTurn: {
      1: (state) => ({ pass: state.orderPlaced, note: "order placed" }),
      2: (state, call) => ({
        pass: !call,
        note: `asking about readiness should not trigger any function call again; call=${call?.name ?? "none"}`,
      }),
    },
  });
});

// ---- S. 연속으로 같은 주문을 바로 이어 말함(설명 없이 급하게 재요청) ----
const rapidSecondAsk = ["빨리요, 스무디요!", "그거 하나만요, 스무디!", "네 그거요, 얼른요.", "그거 하나 주세요, 스무디.", "네 스무디 하나요, 빨리."];
rapidSecondAsk.forEach((second, i) => {
  add({
    id: `S_rapid_repeat_without_explanation_${i}`,
    category: "S_rapid_repeat_without_explanation",
    persona: personaFor(i + 2),
    turns: [firstAttemptOpeners[i + 5], second],
    expectByTurn: {
      0: (state) => ({ pass: state.hasRedirected, note: "redirected" }),
      1: (state) => ({ pass: !state.orderPlaced, note: "rapid repeat without an explanation should still be rejected" }),
    },
  });
});

// ---- T. 줄여 부른 이름 실패 후, 정식 명칭 + 설명으로 재시도하면 성공 ----
shortenedNames.slice(0, 4).forEach((short, i) => {
  add({
    id: `T_short_name_then_full_name_succeeds_${i}`,
    category: "T_short_name_then_full_name_succeeds",
    persona: personaFor(i + 3),
    turns: [short, barrierExplanations[i + 6], "레인보우 마카롱 스무디 한 잔 주문할게요."],
    expectByTurn: {
      0: (state) => ({ pass: true, note: `OBSERVE: shortened name alone -> hasRedirected=${state.hasRedirected}, orderPlaced=${state.orderPlaced}` }),
      2: (state) => ({ pass: state.orderPlaced, note: "explicit full item name after explanation should eventually succeed" }),
    },
  });
});

// ---- U. 예의 바른 태도 vs 무뚝뚝한 태도(같은 요청, 톤만 다름 — 관찰용) ----
add({
  id: "U_polite_tone_observe_0",
  category: "U_tone_variation_observe",
  persona: "inclusive_chatty_warm",
  turns: ["안녕하세요, 혹시 스무디 하나 주문 가능할까요? 감사합니다.", "제가 휠체어를 이용해서 키오스크 사용이 어려운데, 부탁드려도 될까요?"],
  expectByTurn: {
    1: (state) => ({ pass: state.orderPlaced, note: "polite tone with valid explanation should succeed" }),
  },
});
add({
  id: "U_curt_tone_observe_1",
  category: "U_tone_variation_observe",
  persona: "ableist_blunt_dismissive",
  turns: ["스무디.", "휠체어라 손 안 닿음."],
  expectByTurn: {
    1: (state) => ({ pass: state.orderPlaced, note: "curt tone with a valid (if terse) explanation should still succeed on merits" }),
  },
});

writeSummaryOfCounts();
function writeSummaryOfCounts() {
  const counts = {};
  for (const s of scenarios) counts[s.category] = (counts[s.category] ?? 0) + 1;
  process.stderr.write(`scenario categories: ${JSON.stringify(counts, null, 2)}\ntotal: ${scenarios.length}\n`);
}

export { scenarios };
