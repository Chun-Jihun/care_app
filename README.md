# Care App — 로컬 근거 기반 간병수첩

가족과 비전문 간병인이 음식·복약·증상·생활·활동을 로컬에 기록하고, 승인된 의료 근거를 바탕으로 약·음식·활동 관련 정보를 이해하며 진료를 준비하도록 돕는 간병 보조 애플리케이션이다.

이 제품은 의사나 간호사를 대체하지 않으며 진단, 처방, 약물 변경 또는 치료 결정을 제공하지 않는다. 위험할 가능성이 있는 상황에서는 일반 답변을 계속하지 않고 의료기관 연락을 우선 안내한다.

## 현재 단계

- 제품 요구사항, 경쟁 전략, 유스케이스와 모바일 데이터 스키마를 정리한 상태
- 로컬 SLM·VLM·RAG와 데이터 검증 계획을 수립한 상태
- 첫 텍스트 실험의 A1~A5 역할·읽기 도구 계약 `v0.1.0`을 고정한 상태
- 7개 공개 평가 원천의 source adapter와 `DS-AGENT` 후보용 Evaluation Scenario Compiler core를 구현한 상태
- 공개 case를 A1~A5/KO 구성요소 요청으로 렌더링하고 Qwen3.5-4B NF4로 원천별 2건 연결 smoke·채점을 수행한 상태. 이는 공식 benchmark나 프로젝트 의료 출시 평가가 아님
- 합성 48개 `DS-AGENT` oracle fixture, 결정적 읽기 전용 도구 host와 SHA-256 체인 trace를 구현·smoke 실행한 상태. 이는 모델 성능이나 의료 출시 결과가 아님
- 실제 모델 출력을 A1~A5 JSON 계약, 결정적 도구 host와 A5 hard gate에 연결하는 DS-AGENT bundle runner를 구현·replay 통합시험한 상태
- 첫 데스크톱 Qwen3.5-4B 실행을 Windows·Python 3.12·Transformers 5.16.1·bitsandbytes NF4/BF16 프로필로 고정하고, T1~T3 각각 48건 자동 개발 진단과 통합 보고서까지 완료한 상태. 어떤 생성 토폴로지도 전체 계약을 통과하지 못했으며 의료 사용 모델은 선택하지 않음
- e약은요 전체 raw snapshot을 staged·review catalog로 변환했으며, 임상 검수 품목 선정 전인 `awaiting_selection` 상태
- 현재 사람·임상 검수 자원을 확보하지 못한 것으로 가정하므로 자동 결과는 개발 진단으로만 사용하고, 승인 지식·의료 답변·의료 출시 게이트는 차단한 상태
- 에이전트 역할·도구·토폴로지와 원인 분석을 앱 skeleton보다 먼저 검증하는 연구 트랙을 최우선으로 전환
- 애플리케이션 구현 전 단계이며 안전 실패 시나리오와 시험을 먼저 확정해야 함

## 요구사항 원본

개발하거나 설계를 변경하기 전에 다음 순서로 확인한다.

1. [`AGENTS.md`](./AGENTS.md) — 프로젝트 작업 원칙과 금지사항
2. [`docs/caregiving_notebook_requirements.md`](./docs/caregiving_notebook_requirements.md) — 제품 요구사항 원본

다른 문서와 요구사항 원본이 충돌하면 `caregiving_notebook_requirements.md`를 우선한다.

## 문서 읽는 순서

| 순서 | 문서 | 역할 |
|---:|---|---|
| 1 | [간병수첩 요구사항](./docs/caregiving_notebook_requirements.md) | 목적, MVP 범위, 기능·비기능 요구사항과 의료 안전 원칙 |
| 2 | [경쟁 환경 및 제품 전략](./docs/competitive_landscape_and_product_strategy.md) | 경쟁 서비스, 제품 차별점과 USP-KPI 연결 |
| 3 | [프로그램 구조 및 유스케이스](./docs/caregiving_notebook_use_case_design.md) | 사용자 흐름, 계층·모듈 경계와 도메인 객체 |
| 4 | [모바일 데이터 스키마 및 도식](./docs/mobile_app_data_schema_design.md) | 로컬 저장 경계, ERD, OCR·의료 Q&A 흐름과 구현 순서 |
| 5 | [로컬 간병 에이전트 구성 및 성능평가](./docs/agent_architecture_and_evaluation_plan.md) | 역할별 책임, 전체 도식, 모델 배치, 토폴로지 비교와 실패 원인 분석 |
| 6 | [A1~A5 역할·도구 사용 규약](./docs/agent_role_and_tool_contracts.md) | 역할별 입력·출력 JSON, 읽기 도구, 환자 경계, 인계와 실패 처리 |
| 7 | [SLM·VLM·RAG 검증 계획](./docs/slm_rag_validation_plan.md) | 비교 모델, 출시 차단 조건, 평가 데이터와 실행 절차 |
| 8 | [모델·RAG 데이터 카탈로그](./docs/model_and_rag_data_catalog.md) | 파인튜닝·RAG·평가 데이터의 실제 출처, 권리와 승인 상태 |
| 9 | [e약은요 staged → approved 절차](./docs/mfds_easy_drug_approval_workflow.md) | 임상 검수 품목 선정, 근거 span 승인과 runtime 활성화 전 게이트 |
| 10 | [Qwen3.5-4B 로컬 런타임·양자화 결정](./docs/qwen35_local_runtime_decision.md) | 첫 Windows 실험의 패키지·NF4 설정, fail-closed 경계와 모바일 분리 |
| 11 | [공개 평가 원천 Source Adapter](./docs/evaluation_source_adapters.md) | BFCL·LongHealth·MIRAGE·HealthBench·RAGTruth·한국어 QA의 정규화 형식과 사용 경계 |
| 12 | [A1~A5 역할별 구성요소 평가 하네스](./docs/role_component_evaluation_harness.md) | 공개 case의 역할별 렌더링, 로컬 backend, 결정적 채점과 공식·E2E 결과의 경계 |
| 13 | [Evaluation Scenario Compiler](./docs/evaluation_scenario_compiler.md) | 구조화·비식별 간병 event와 승인 약물 근거를 DS-AGENT 후보 episode로 변환하는 규칙 |
| 14 | [DS-AGENT 결정적 도구 호스트·trace 파일럿](./docs/ds_agent_deterministic_pilot.md) | 48개 합성 기반, 역할·범위·예산 강제 host, trace 스키마와 현재 smoke 결과의 해석 경계 |
| 15 | [DS-AGENT A1~A5 로컬 모델 runner](./docs/ds_agent_model_runner.md) | 실제 모델 JSON을 역할 계약·도구 host·hard gate에 연결하는 실행 경로와 재현 명령 |
| 16 | [사람 검수 없는 자동화 개발 트랙](./docs/no_human_review_development_plan.md) | 자동화로 계속할 수 있는 실험, 차단되는 의료 주장과 모바일 기록 중심 전환 기준 |
| 17 | [자동화 에이전트 평가 결과](./experiments/agent_eval/results/automated_agent_evaluation_v1/automated_agent_evaluation.md) | T0~T3 실제 실행, 공개 구성요소 연결 smoke와 비출시 결론 |

## 현재 최우선 작업

자동화 에이전트 선행 연구의 1차 중단 기준을 충족했으므로 이제 모바일 기록 중심 skeleton과 암호화 저장 구현이 최우선이다.

1. 모바일 기술스택과 최소 Android 목표 장비를 확정한다.
2. `domain / application / infrastructure / presentation` 경계의 skeleton을 만든다.
3. SQLite 암호화·migration 방식을 확정하고 환자 선택정보와 간병기록을 분리한 CRUD·재시작 통합시험을 구현한다.
4. 식사·복약·증상·활동·첨부파일/OCR 순으로 확장한다.
5. 승인 snapshot과 임상 검수가 없으므로 생성형 의료 Q&A와 임상 위험 규칙은 비활성 feature gate 뒤에 둔다.

자동 결과에서 T1은 기대 상태 72.9%, 기록 참조 50.0%로 가장 나은 생성형 구성이었지만 전체 계약을 통과하지 못한 개발 기준선일 뿐이다. T3는 호출과 지연이 늘고 A2·A3의 생성 실패면이 추가됐다. 공개 AgentBench·BFCL·ToolBench 점수와 이번 2건 구성요소 smoke는 후보·연결 진단 자료이며 프로젝트 의료 성능이 아니다.

## 초기 MVP 범위

- 선택적 로컬 환자 프로필과 암호화된 간병일기
- 음식 사진·섭취량·수분과 식사 전후 상태 기록
- 처방전·약 봉투 OCR 초안 확인, 약 목록과 실제 복약 기록
- 증상·생활·활동·측정값·사건·인계 기록
- 승인 문서만 사용하는 근거 기반 간병 Q&A
- 기록 변화 요약과 진료 질문 정리
- 규칙 엔진 우선의 고위험 신호 대응
- 로컬 질문·답변 기록의 보관기간, 간병일기 반영과 삭제 관리
- 복사 가능한 가족 교대·도움 요청문과 인계메모 초안

초기 MVP에는 가족 계정 간 공유, 앱 내부 교대 요청 전송, 병원·주치의 전송, 외부 클라우드 자동 백업, EMR 연동, 진단·처방 변경과 사용자 확인 없는 OCR 자동 확정을 포함하지 않는다.

## 의료·개인정보 안전 원칙

- 승인되고 의료진이 검수한 문서만 의료 RAG에 등록한다.
- 제공 근거에서 직접 확인할 수 없는 의학적 핵심 주장 생성은 출시 평가 세트에서 `0건`이어야 한다.
- 정확한 페이지·절·근거문장 연결률과 보류·확인 라우팅률은 hard gate 통과 후 별도 개선 KPI로 측정한다.
- 고위험 판단, 약물 상호작용과 위험 임계값은 LLM보다 규칙·구조화 시스템을 우선한다.
- 환자 식별정보, 대화 원문, 사진과 간병기록을 외부 LLM·광고·분석 서비스로 전송하지 않는다.
- 가족 공유와 의료기관 전송은 동의·권한·보안·규제 검토를 마친 최후 단계에서만 추가한다.

## 예정 기술 구성

아래 항목은 제품 방향 또는 비교 후보다. Qwen3.5-4B의 첫 데스크톱 평가 프로필만 별도로 고정됐으며 제품·모바일 모델 채택을 뜻하지 않는다.

| 영역 | 현재 방향 | 확정 상태 |
|---|---|---|
| 애플리케이션 | 로컬 우선, 오프라인 기록과 조회 | 플랫폼 미정 |
| 저장소 | 환자별 분리, 암호화 DB·사진 저장소·수정 이력 | 제품·암호화 방식 미정 |
| 텍스트·멀티모달 모델 | Qwen3.5-4B, MedGemma 1.5 4B와 한국어·저사양 후보 비교 | Qwen3.5-4B 데스크톱 NF4 T1~T3 자동 개발 진단 완료, 비통과 T1을 개선 기준선으로만 유지. 제품·의료 모델 미선정 |
| OCR | 범용 VLM, 한국어 VLM, 전용 OCR+필드 파서와 수동 입력 기준선 비교 | 평가 전 |
| RAG | 승인 스냅샷 기반 혼합 검색과 재순위화 | 임베딩·재순위 모델 미정 |
| 안전 | LLM보다 먼저 실행하는 구조화 규칙 엔진 | 규칙 승인자·첫 질환 범위 미정 |

## 구현 전에 남은 핵심 결정

- 첫 실행 플랫폼과 최소·권장 장비 사양
- 첫 질환·치료 단계 콘텐츠 팩과 임상 검수자
- 처방전·약 봉투·약 상자 중 OCR 지원 범위
- 로컬 백업·복원과 암호화 키 복구 방식
- 대화기록의 기본 보관값과 선택 가능한 보유기간
- 안전 규칙의 작성·승인 책임과 의료기관 연락 문구
- 지식베이스 관리 도구와 진료용 내보내기 형식

현재 임상 검수자를 확보하지 못하면 첫 질환 콘텐츠 팩, 승인 지식베이스, 의료 Q&A와 임상 위험 규칙의 제품 활성화는 결정이 아니라 **차단 항목**으로 유지한다.
