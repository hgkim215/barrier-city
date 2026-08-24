# 점원 NPC 주문 케이스 LLM 평가

> 실행일: 2026-08-24
> 실행자: Claude(에이전트) — 실제 OpenAI Realtime API를 텍스트 모드로 호출
> 목적: `RealtimeMissionCoordinator`의 결정론적 게임 상태 로직(유닛 테스트로 이미 커버)이 아니라, **실제 모델이 다양한 방문자 발화에 어떻게 반응하는지** — 언제 함수를 부르는지, 장벽 설명을 얼마나 잘 알아듣는지, 말투가 자연스러운지 — 를 검증한다.

## 왜 이 방식인가

`Barrier City`의 점원 대화는 OpenAI Realtime API(WebRTC, 음성)로 동작한다. `RealtimeMissionCoordinatorTests`(`Packages/DialogueKit/Tests/DialogueKitTests/`)는 "함수 호출이 들어왔을 때 앱이 승인/거절하는 규칙"을 완벽하게 커버하지만, **모델이 애초에 그 함수를 언제 부르는지, 어떤 말을 하는지**는 프롬프트에 대한 모델의 실제 판단이라 코드 유닛 테스트로는 검증할 수 없다.

이 문서는 실제 시스템 프롬프트(`RealtimeConversationGuide`)와 도구 스키마를 그대로 사용해 Realtime API를 직접 호출하며, 앱과 동일한 방식으로 함수 호출 결과를 검증·주입하는 평가 하네스를 실행한 기록이다.

## 방법론

### 무엇을 실제와 동일하게 유지했는가

- **시스템 프롬프트**: 앱 코드(`RealtimeConversationGuide.instructions(...)`)를 임시 Swift 도구(`PromptDumpTool`, 평가 후 제거)로 직접 호출해 텍스트를 뽑았다 — 프롬프트를 손으로 옮겨 적지 않았다.
- **도구 스키마**: `NPCDialogueController`의 `reportOrderAttemptTool`/`placeMissionOrderTool` 정의를 그대로 JSON Schema로 옮겼다.
- **게임 상태 검증 로직**: `RealtimeMissionCoordinator.register(...)`의 승인/거절 규칙(첫 시도 무조건 리다이렉트, item/quantity 스키마 검증, 중복 주문 차단 등)을 JS로 1:1 이식해, 평가 하네스도 앱과 똑같은 기준으로 함수 호출을 승인/거절하고 `# 앱이 관리하는 미션 상태` 블록을 재구성한다.
- **오프닝 인사**: `RealtimeConversationGuide.openingInstructions(...)`를 그대로 사용, `tool_choice: none`으로 첫 인사에서 함수를 못 부르게 한 것도 동일.
- **후속 응답 프로토콜**: 함수 호출 → `function_call_output` 전송 → `tool_choice: none`으로 후속 응답 요청, 이라는 실제 앱(`NPCDialogueController.finishRealtimeResponse`/`completeFunctionCalls`)의 흐름을 그대로 재현했다.

### 무엇을 단순화했는가

- **전송 방식**: 실제 앱은 WebRTC(LiveKitWebRTC, 오디오 트랙 포함)를 쓰지만, 평가는 오디오가 필요 없어 **동일한 이벤트 프로토콜을 텍스트 전용 WebSocket**(`wss://api.openai.com/v1/realtime`, 같은 ephemeral 토큰)으로 호출했다. 프로토콜 이벤트(`session.update`, `response.create`, `response.function_call_arguments.done` 등)는 전송 방식과 무관하게 동일하다.
- **SocialClimate(호감도)**: 실제 앱은 매 방문자 턴마다 정중함/적대성을 분석해 rapport를 갱신하지만, 평가에서는 시나리오별로 **페르소나 4종(태도×성격×초기 rapport 조합)을 고정**해서 돌렸다 — 대화 도중 rapport가 실시간으로 바뀌지는 않는다.
- **대화 기억(ConversationMemory)**: 매번 빈 상태로 시작(`isReturningEncounter: false`)했다 — 같은 몰입 세션 내 재방문 시나리오는 이번 평가에 포함하지 않았다.

### 시나리오 배터리

서로 다른 발화·조합으로 구성한 **98개 시나리오**, 21개 카테고리:

| 카테고리 | 개수 | 검증 목적 |
|---|---:|---|
| A. 첫 주문 시도 | 10 | 무조건 키오스크 리다이렉트, 그 자리에서 절대 성공 안 함 |
| B. 리다이렉트 후 타당한 장벽 설명 | 10 | 설명을 알아듣고 주문 성립 |
| C. 설명 없이 반복 → 2턴 뒤 관대화 | 5 | 반복만으로는 안 되고, VISITOR_TURNS_SINCE_KIOSK_REDIRECT≥2에서 약한 설명도 수용 |
| D. 잘못된 품목 | 5 | 스무디 성립 후 다른 품목 요청은 별도 주문으로 안 침 |
| E. 두 잔 요청 → 한 잔 정정 | 5 | (아래 한계 참고 — 시나리오 설계 결함 발견) |
| F. 줄여 부른 이름 | 5 | "레인보우 스무디"만으로는 진짜 주문으로 안 침 |
| G. 순수 잡담 | 5 | 함수 호출이 전혀 없어야 함 |
| H. 잡담 후 주문 | 5 | 주문 순간에만 함수가 호출돼야 함 |
| I. 같은 호흡에 주문+설명 | 5 | 리다이렉트와 같은 턴에 설명이 있어도 유효 |
| J. 주문 성공 후 중복 요청 | 5 | 두 번째 주문 거절 |
| K. 무례한 태도 | 5 | 태도와 무관하게 로직은 정확해야 함 |
| L. 다른 직원 요청 | 5 | "저뿐이다"라고만 답하고 다른 직원을 부르지 않음 |
| M. 언어 코드 스위칭 | 3 | 영어 섞인 발화에도 리다이렉트 정상 동작 |
| N. 극단적으로 짧은 발화 | 2 | 단답형 발화에도 정상 동작 |
| O. 설명 전 필러 턴 | 2 | 필러 턴 자체는 주문을 성립시키지 않음 |
| P. 리다이렉트 후 포기 | 2 | 포기 시 주문이 성립하지 않음 |
| Q. 애매한 사유(관찰용) | 3 | 엄격한 합/불 기준 없이 모델 판단 관찰 |
| R. 주문 후 준비 상태 문의 | 5 | 함수 재호출 없이 대화만 |
| S. 설명 없는 급한 재요청 | 5 | 빨리 말해도 설명 없인 여전히 거절 |
| T. 줄임말 실패 후 정식 명칭 재시도 | 4 | 정식 명칭+설명이면 이후 성립 |
| U. 톤 대비(관찰용) | 2 | 존댓말/반말 대비 관찰 |

시나리오 정의는 `scenarios.mjs`([아래 재현 방법](#재현-방법) 참고)에 카테고리별로 정리돼 있다.

### 평가 방식

각 시나리오는 대화 턴마다:
1. 방문자 발화를 텍스트로 주입.
2. 모델 응답을 요청(실제 앱과 동일한 지침·도구로).
3. 함수 호출이 있으면 이식한 `RealtimeMissionCoordinator` 로직으로 승인/거절 판정 → 결과를 함수 출력으로 반환 → 후속 응답 요청.
4. 사전에 정의한 기대치(예: "이 턴에서 함수 호출이 없어야 한다", "이 턴 이후 ORDER_PLACED가 true여야 한다")와 대조.
5. 응답 텍스트를 이번 세션에서 고친 어색한 말투 패턴(예: "그 설명이면 충분하네요", "확인할게요"+"처리/과정") 정규식으로도 검사.

## 결과 요약

**98개 시나리오 중 80개 PASS, 18개 FAIL.** FAIL 18개를 원인별로 나누면:

| 원인 | 개수 | 비고 |
|---|---:|---|
| 일시적 인프라 오류(레이트리밋/타임아웃) | 12 | 모델·앱 로직과 무관 — 아래 [막힌 지점](#어디서-막혔는가) 참고 |
| 진짜 발견(모델이 관대화 지침을 안 지킴) | 1 | `C_repeat_then_lenient_after_two_turns_3` |
| 테스트 시나리오 자체의 설계 결함 | 5 | `E_two_then_one_quantity_*` 전부 — 모델이 아니라 내 시나리오가 틀렸다 |
| 어색한 말투 회귀 | 0 | 80개 성공 케이스 전체에서 0건 — 이전 세션에서 고친 프롬프트가 유지되고 있음을 확인 |

카테고리별 세부 결과(transient=일시적 오류, genuine=진짜 실패):

```text
A_first_attempt_redirect               pass= 8  transient= 2  genuine=0
B_redirect_then_valid_barrier          pass=10  transient= 0  genuine=0
C_repeat_then_lenient_after_two_turns  pass= 3  transient= 1  genuine=1
D_wrong_item_rejected                  pass= 4  transient= 1  genuine=0
E_two_then_one_quantity                pass= 0  transient= 0  genuine=5  (시나리오 설계 결함, 아래 참고)
F_shortened_name_not_real_order        pass= 5  transient= 0  genuine=0
G_small_talk_no_function_call          pass= 5  transient= 0  genuine=0
H_offtopic_then_order                  pass= 5  transient= 0  genuine=0
I_same_breath_order_and_barrier        pass= 3  transient= 2  genuine=0
J_duplicate_order_after_success        pass= 5  transient= 0  genuine=0
K_hostile_tone                         pass= 5  transient= 0  genuine=0
L_asks_for_another_staff               pass= 5  transient= 0  genuine=0
M_mixed_language                       pass= 3  transient= 0  genuine=0
N_terse_utterances                     pass= 2  transient= 0  genuine=0
O_filler_before_explanation            pass= 1  transient= 1  genuine=0
P_gives_up_after_redirect              pass= 2  transient= 0  genuine=0
Q_vague_reason_observe                 pass= 3  transient= 0  genuine=0
R_readiness_check_after_order          pass= 5  transient= 0  genuine=0
S_rapid_repeat_without_explanation     pass= 3  transient= 2  genuine=0
T_short_name_then_full_name_succeeds   pass= 3  transient= 1  genuine=0
U_tone_variation_observe               pass= 0  transient= 2  genuine=0
```

## 진짜 발견

### 1) 관대화 지침(VISITOR_TURNS_SINCE_KIOSK_REDIRECT≥2)이 항상 지켜지진 않는다

`RealtimeConversationGuide`는 리다이렉트 후 방문자가 2턴 이상 이야기했으면 완벽한 설명이 아니어도 받아주라고 지시한다. 대부분(5개 중 4개) 시나리오는 이 지침을 따랐지만, 하나는 턴 수가 충분한데도 더 구체적인 이유를 캐물었다:

```
visitor: 제 사정이 있어서 그런데요.
clerk:   사정은 알겠는데, 그걸로는 왜 키오스크를 못 쓰는지 잘 모르겠어요.
         휠체어라서 접근이 안 된다든지, 손이 닿지 않는다든지 그런 이유인가요?
```

이건 버그라기보다 **모델 판단의 자연스러운 변동성**이다 — 5번 중 4번은 의도대로 관대하게 받아줬다. 다만 이 편차가 실제 플레이에서도 나타날 수 있다는 뜻이라, 완벽을 요구하지 않고 계속 관찰할 지표로 남겨둔다. 지침 문구를 더 강하게("망설이지 말고 즉시 받아들여라" 등) 다듬으면 편차가 줄어들 가능성이 있다.

### 2) `E_two_then_one_quantity` 시나리오는 내 설계가 틀렸다

의도는 "두 잔 달라고 하면 한 잔만 된다고 안내하고, 정정하면 성립한다"였는데, 실제로는 시나리오의 turn 순서상 **1턴(장벽 설명)에서 이미 주문이 성립**해버린 뒤에 "두 잔 주세요"가 나갔다. 그래서 모델은 이걸 "이미 넣은 주문에 추가로 두 잔을 더 달라는 요청"으로(정확하게) 해석해 거절했다:

```
clerk(function_call): place_mission_order(...) -> 성공  ← 1턴에서 이미 성립
visitor: 두 잔 주세요.
clerk:   한 번에 한 잔만 돼요. 이미 하나 들어가 있어서 더는 못 받습니다.
```

이건 오히려 **올바른 동작**이다 — 다만 내가 원래 테스트하려던 "최초 요청부터 두 잔"이라는 경로는 아니다. 이 축을 다시 검증하려면 "휠체어라서 손이 안 닿는데, 두 잔 주세요" 처럼 **장벽 설명과 두 잔 요청을 같은 턴에 합쳐서** 리다이렉트 직후 곧바로 시도하는 시나리오로 다시 짜야 한다. 이번 결과에서 이 축은 사실상 검증되지 않은 것으로 간주해야 한다.

## 확인된 정상 동작(대표 전사록)

**같은 호흡에 주문+장벽 설명 → 리다이렉트 이후 바로 성립:**
```
visitor: 저 휠체어라 키오스크가 안 닿아서 그러는데, 스무디 하나만 주문할 수 있을까요?
clerk:   하... 알겠어요. 그거 하나만요, 여기서 받아둘게요.
visitor: 네, 스무디 하나 부탁드려요.
clerk(function_call): place_mission_order(...) -> 성공
clerk:   하... 알겠어요. 하나는 받아놨고, 준비되면 불러드릴게요.
```
(참고: 리다이렉트 직후 대사에서도 "하... 알겠어요"라는 승낙조 표현이 한 번 더 나온 게 살짝 이르다는 인상은 있으나, 구조적으로는 정상 동작했고 이전에 고친 3개 어색한 문장 패턴에는 걸리지 않았다.)

**무례한 태도에서도 로직은 정확:**
```
visitor: 야, 스무디 하나 빨리 줘봐.
clerk:   지금 좀 정신없어요. 주문은 저기 키오스크에서 해주시겠어요?
visitor: 손이 키오스크까지 닿지 않아서 그런데, 대신 주문해 주실 수 있을까요?
clerk(function_call): place_mission_order(...) -> 성공
```

**다른 직원을 부르지 않음:**
```
visitor: 다른 직원분 계세요? 그분한테 부탁드리고 싶은데.
clerk:   지금은 저 혼자예요. 다른 사람한테 넘길 수는 없어요.
```

**순수 잡담엔 함수 호출 없음:**
```
visitor: 오늘 날씨 좋네요.
clerk:   그러게요, 햇살이 들어오니까 가게가 좀 덜 칙칙해 보이네요...
(함수 호출 없음)
```

## 어디서 막혔는가

1. **첫 시도(동시 요청 6개)에서 하네스 자체가 크래시했다.** `openSession()`을 `new Promise(async (resolve, reject) => ...)` 패턴으로 짰는데, 그 안에서 토큰 발급이 429로 실패하면 `reject()`가 아니라 처리되지 않은 Promise rejection으로 새어나가 Node 프로세스 전체가 죽었다. `openSession`을 평범한 `async function`으로 바꾸고 내부를 `await`가 있는 `new Promise` executor 밖으로 옮겨 고쳤다.
2. **프록시 토큰 발급이 429를 반환.** 동시 6개 세션이 프록시(Cloudflare Worker)의 `/realtime-token`에 거의 동시에 요청을 보내 레이트리밋에 걸렸다. 지수 백오프 재시도(최대 5회)를 추가했다.
3. **가장 큰 병목: OpenAI 프로젝트의 Realtime 모델 TPM(분당 토큰) 한도가 40,000으로 낮다.** 페르소나 지침 텍스트만 한 번에 약 1,500~2,000 토큰이라, 동시 실행은 물론 순차 실행에서도 몇 번의 응답 만에 한도에 도달했다. 동시성을 1(완전 순차)로 낮추고, `response.done`이 `rate_limit_exceeded`로 실패하거나 세션 레벨 `error` 이벤트로 같은 사유가 오면 **12~16초 대기 후 같은 요청을 재시도**하도록 했다. 이 재시도가 총 98개 시나리오 중 상당수에서 걸렸고(로그에 90회 이상), 전체 실행 시간이 약 30분 가까이 걸린 주된 이유다.
4. 그래도 재시도 상한(6회)을 넘기거나 완전히 끊긴 12개 시나리오는 최종적으로 오류로 종료됐다 — 전부 인프라 문제였고 모델 판단과는 무관하다(위 표 참고).

## 한계와 다음 단계

- **재현성**: LLM 호출이라 완전히 결정론적이지 않다. 이번 결과는 한 번의 스냅샷이며, 특히 "진짜 발견 1)"의 편차는 여러 번 반복해야 신뢰 구간을 알 수 있다.
- **SocialClimate 미반영**: 실시간 rapport 변화가 톤에 미치는 영향은 검증하지 못했다.
- **재방문(returning encounter) 시나리오 없음**: `isReturningEncounter: true` 경로, 즉 대화 기억을 이어받는 케이스는 이번 배터리에 없다.
- **E 카테고리 재설계 필요**: 위에서 설명한 대로 "최초 요청부터 두 잔"을 실제로 검증하려면 시나리오를 다시 짜야 한다.
- **TPM 40,000의 근본 원인**: 이 한도는 OpenAI 프로젝트 설정(조직 등급)에서 오는 것으로 보인다. 이후 이 평가를 정기적으로 돌리려면 한도 상향을 요청하거나, 페르소나 지침 텍스트를 캐싱/축약하는 방안을 고려할 수 있다.

## 재현 방법

하네스 소스는 이 문서와 함께 `clerk-order-eval/`에 보존해 뒀다.

```bash
# 1) 실제 프롬프트 텍스트를 뽑는다(임시 실행 타깃 필요 — 아래 참고)
#    Packages/DialogueKit/Package.swift의 targets 배열에 다음을 임시로 추가:
#      .executableTarget(name: "PromptDumpTool", dependencies: ["DialogueKit"]),
#    그리고 docs/trouble-shooting/clerk-order-eval/PromptDumpTool.swift를
#    Packages/DialogueKit/Sources/PromptDumpTool/main.swift로 복사한 뒤:
cd Packages/DialogueKit
swift run PromptDumpTool > ../../docs/trouble-shooting/clerk-order-eval/prompt_dump.json
#    (평가가 끝나면 Package.swift와 Sources/PromptDumpTool을 다시 제거한다 —
#    앱 빌드에는 필요 없는 일회성 도구다.)

# 2) 평가 실행(Node.js, 외부 의존성 없음 — 네이티브 fetch/WebSocket만 사용)
cd docs/trouble-shooting/clerk-order-eval
node run.mjs smoke smoke_results.json     # 3개만 빠르게 확인
node run.mjs full results.json 1          # 전체 98개, 동시성 1(TPM 한도 때문에 권장)
```

동시성을 올리면(`node run.mjs full results.json <N>`) 더 빨리 끝날 수도 있지만, 이 프로젝트의 TPM 한도(40,000)에서는 오히려 레이트리밋 재시도가 늘어나 전체 시간이 비슷하거나 더 걸릴 수 있다.
