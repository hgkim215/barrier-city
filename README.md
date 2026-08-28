# Barrier City

![\[2026 AIXR 서비스 개발자 경진대회\] Barrier City (3DTV).gif](<assets/\[2026 AIXR 서비스 개발자 경진대회] Barrier City (3DTV).gif>)

> Apple Vision Pro의 공간컴퓨팅과 생성형 AI로, 휠체어 이용자가 일상 공간에서 마주하는
> 물리적·디지털·대인 서비스 장벽을 직접 경험하고 이해하도록 돕는 몰입형 접근성 체험 서비스

<div align="center">

![visionOS](https://img.shields.io/badge/visionOS-000000?style=for-the-badge\&logo=apple\&logoColor=white "visionOS")   ![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge\&logo=swift\&logoColor=white "Swift")   ![JavaScript](https://img.shields.io/badge/JavaScript-F7DF1E?style=for-the-badge\&logo=javascript\&logoColor=white "JavaScript")

</div>

<br />

**시연 영상:** <https://youtu.be/2DpsA2DMuZQ>

***

## 프로젝트 소개

같은 도시, 같은 시설이라도 그 경험은 모두에게 같지 않습니다. 비장애인에게는 자연스러운
카페 출입과 주문 과정도 휠체어 이용자에게는 이동 경로, 출입구, 키오스크 높이, 직원 응대,
테이블 배치까지 함께 고려해야 하는 과정입니다.

이동이 어려운 공간은 **물리적 장벽**, 손이 닿지 않는 키오스크는 **디지털 장벽**, 상황을
고려하지 않는 응대는 **대인 서비스 장벽**이 됩니다. 영상·강의 중심의 기존 인식 개선 교육은
이런 장벽을 직접 체감하기 어렵다는 한계가 있었습니다.

Barrier City는 사용자가 접근성 문제를 관찰하는 데 그치지 않고, 휠체어를 직접 조작해
이동하고 AI 직원과 대화하며 장벽이 발생하는 원인을 스스로 이해하도록 만드는 사회문제
해결형 XR 서비스입니다. 첫 번째 시나리오로 **휠체어 이용자의 카페 이용 과정**을 구현했으며,
사용자는 카페로 이동해 높은 키오스크에서 주문에 실패한 뒤 AI 직원에게 도움을 요청하고,
음료를 수령해 좌석까지 이동하는 여정을 경험합니다.

### 체험 흐름 (6단계)

1. **손 추적 기반 휠체어 이동** — 컨트롤러 없이 양손으로 좌우 바퀴를 밀어 전진·회전
2. **실외-실내 연결 공간 체험** — 도로에서 카페 입구까지, 장면 전환 없이 이어지는 여정
3. **높은 키오스크 접근성 장벽** — 앉은 자세에서 닿지 않는 조작 영역과 실패 원인 안내
4. **AI 직원과의 실시간 음성 대화** — 성격이 다른 직원 NPC에게 상황을 직접 설명하고 도움 요청
5. **주문 검증과 음료 수령** — 안내·설명·주문 조건을 앱이 재검증한 뒤에만 진행
6. **동적 손님 NPC와 카페 환경** — 배회·대기줄·착석 NPC가 만드는 사회적 압박의 공간적 재현

***

## 팀 구성 및 역할

| 이름           | 역할                                                                                                                           |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **김선환** (팀장, 디자인) | Reality Composer Pro로 실내·실외 공간, 키오스크, NPC, WayPoint 에셋 구성 및 충돌체·조명·애니메이션 배치, 초기 휠체어 이동·물리 통합                                 |
| **김현기** (개발)    | 전체 시나리오·미션 흐름 설계, 휠체어 이동·키오스크 장벽·온보딩 HUD·장면 전환·미션 연출 통합, 기능 상태 관리 및 최종 UX 안정화                                                |
| **이윤서** (개발) | OpenAI Realtime 기반 AI 점원 대화, Cloudflare 프록시 및 Function Calling 주문 검증 구조 구현, 손님 NPC 배회·대기줄·착석·경로 탐색·충돌 회피, 공간 음향 및 실시간 성능 최적화 |

***

## 기술 스택

* 플랫폼 : ![visionOS](https://img.shields.io/badge/visionOS-000000?style=for-the-badge\&logo=apple\&logoColor=white "visionOS")

* 개발 언어 : ![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge\&logo=swift\&logoColor=white) ![JavaScript](https://img.shields.io/badge/JavaScript-F7DF1E?style=for-the-badge\&logo=javascript\&logoColor=white)

  <br />

| 구분         | 내용                                                            |
| ---------- | ------------------------------------------------------------- |
| UI / 상태 관리 | SwiftUI, Observation                                          |
| 공간 콘텐츠     | RealityKit, Reality Composer Pro, USD·USDZ                    |
| 공간 인식      | ARKit Hand Tracking, World Tracking                           |
| 생성형 AI     | OpenAI Realtime API (`gpt-realtime-2.1`), `gpt-4o-transcribe` |
| 실시간 통신     | WebRTC, LiveKitWebRTC                                         |
| 백엔드        | Cloudflare Workers (OpenAI Realtime 토큰 프록시)                   |
| 개발 도구      | Xcode 26.3, Reality Composer Pro, macOS                       |
| 테스트        | XCTest 기반 유닛·회귀 테스트                                           |

***

## 프로젝트 구조

```
barrier-city/
├── Barrier City/                 # visionOS 앱 메인 소스
│   ├── Dialogue/                  # AI 직원 음성 대화 (WebRTC ↔ OpenAI Realtime)
│   ├── Interaction/                # 키오스크, 장면 전환, WayPoint, 서빙 등 상호작용 로직
│   ├── NPC/                        # 점원·손님 NPC 행동, 경로 탐색, 충돌 회피
│   ├── Quest/                      # 미션 흐름, 온보딩/튜토리얼 HUD
│   ├── Resources/                  # 오디오, 스플래시 영상 등 리소스
│   └── (Wheelchair*, AppModel 등)  # 손 추적 → 휠체어 이동 변환, 전역 상태 관리
├── Packages/
│   ├── DialogueKit/                 # OpenAI Realtime 대화 SDK (Swift Package)
│   │   ├── Sources/DialogueKit/       # NPC 페르소나, 대화 메모리, 미션 이벤트
│   │   └── Sources/DialogueKitOpenAI/ # Realtime WebRTC 클라이언트, 프록시 연동
│   └── RealityKitContent/           # Reality Composer Pro 3D 공간·에셋 패키지
├── Tests/                         # 이동/대화/NPC/미션 로직 유닛·회귀 테스트
├── proxy/                         # Cloudflare Worker: OpenAI 키를 감춘 Realtime 토큰 프록시
├── docs/                          # 설계 문서, 트러블슈팅 기록, 디자인 에셋
└── Barrier City.xcodeproj/        # Xcode 프로젝트
```

### 아키텍처 개요

시스템은 크게 **사용자 입력 → 공간 인식/UI → 공간 상호작용 → AI 대화 → 미션·상태 관리**의
다섯 계층으로 구성됩니다.

* **ARKit + SwiftUI**: 손 위치 추적과 온보딩·HUD·자막 등 인터페이스 처리

* **RealityKit**: 휠체어 이동, 충돌, 장면 전환, 공간 상호작용 처리

* **DialogueKit + WebRTC**: AI 직원의 음성·자막·Function Calling 처리

* **AppModel / QuestModel / CafeOrderSession**: 전체 미션과 공간·UI·NPC 상태 관리

한국어 음성은 DialogueKit과 WebRTC를 통해 OpenAI Realtime API로 전달되고, AI는 현재 미션
단계·이전 대화·직원 성격·관계 상태를 종합해 음성과 자막을 생성합니다. **대화는 생성형 AI가
유연하게 처리하지만, 실제 미션 진행 여부는 앱의 규칙 기반 로직이 다시 검증**하도록 설계해
자연스러움과 안정성을 함께 확보했습니다.

공통 기능(입력, 이동, 상태 관리, AI 대화)과 시나리오 콘텐츠(공간, 장벽, NPC, 미션 조건)를
분리해, 새로운 공간과 상호작용 규칙을 추가하는 방식으로 다른 시나리오까지 확장할 수 있는
구조로 설계했습니다.

***

## AI 활용

* **서비스 기능 내 활용**: OpenAI Realtime API로 카페 직원 NPC와 실시간 한국어 음성 대화를
  구현. 사용자 발화·이전 대화·키오스크 장벽 체험 여부·미션 단계·직원 성격·관계 상태를
  종합해 응답을 생성하고, 주문 의도는 Function Calling으로 앱에 전달

* **주문 검증 이원화**: AI의 판단을 그대로 신뢰하지 않고, 키오스크 안내 여부·접근성 장벽
  설명 여부·상품명과 수량을 앱이 규칙 기반으로 재검증한 뒤에만 미션을 진행시켜, AI의 언어
  이해력은 활용하되 체험의 핵심 흐름은 안정적으로 통제

* **개발 과정 활용**: AI Agent 도구로 Swift·RealityKit 코드 초안 작성/리팩터링, 테스트
  케이스 구성, 오류 원인 분석, 기술 문서 정리를 보조. 문제 정의·시나리오 설계·기술 선택·
  최종 코드 검토와 수정은 팀원이 직접 수행

* **디자인 활용**: ChatGPT·나노바나나로 에셋 텍스처 및 모델링 이미지 제작, TripoAI로 3D
  객체 폴리곤 생성, Mixamo로 점원·손님 NPC 애니메이션 제작

***

## 시작하기

### 요구 사항

* macOS + Xcode 26.3 이상

* Apple Vision Pro 또는 visionOS 26.2+ 시뮬레이터

* OpenAI API 키 (Realtime 대화 기능 사용 시)

* Cloudflare 계정 (Realtime 토큰 프록시 배포 시, 선택)

### 실행

```bash
git clone https://github.com/hgkim215/barrier-city.git
cd barrier-city
open "Barrier City.xcodeproj"
```

Xcode에서 `Barrier City` 스킴을 선택해 Vision Pro 시뮬레이터 또는 실기기로 빌드·실행합니다.

AI 직원 음성 대화를 사용하려면 OpenAI 키를 앱에 직접 넣지 않고 Cloudflare Worker 프록시를
통해 단기 토큰을 발급받도록 구성되어 있습니다. 배포 방법은 [`proxy/README.md`](proxy/README.md)를 참고하세요.

### 테스트

```bash
xcodebuild test -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
```

***

## 기대 효과 및 활용 분야

* **접근성 인식 개선 교육**: 학교·복지기관·공공 체험관에서 장애 인식 개선 교육으로,
  카페·음식점·금융기관 등에서는 이동약자 고객 응대 훈련으로 활용

* **공간 접근성 검토**: 실제 매장·공공시설의 디지털 트윈과 연계해 키오스크 높이, 이동 통로,
  서비스 동선을 설계 단계에서 검토하는 접근성 시뮬레이션으로 확장

* **확장 로드맵**: 체험 대상을 시각·청각장애인, 고령자, 디지털 취약 사용자로, 공간을
  대중교통·병원·관공서·교육문화시설·관광지로 확대해 도시 전반의 접근성 체험 플랫폼으로 발전

