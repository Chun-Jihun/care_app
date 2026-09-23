# Care App — 로컬 근거 기반 간병수첩

가족과 비전문 간병인이 음식·복약·증상·생활·활동을 로컬에 기록하고, 승인된 의료 근거를 바탕으로 약·음식·활동 관련 정보를 이해하며 진료를 준비하도록 돕는 간병 보조 애플리케이션이다.

이 제품은 의사나 간호사를 대체하지 않으며 진단, 처방, 약물 변경 또는 치료 결정을 제공하지 않는다. 위험할 가능성이 있는 상황에서는 일반 답변을 계속하지 않고 의료기관 연락을 우선 안내한다.

## 현재 단계

- **Android 로컬 AI 연결:** [구현 범위와 검증](./docs/mobile_ai_integration.md). 학습한 모델을 기록 조회·OCR·음성 입력에 연결했다. 의료 답변은 보류하며 iOS AI 실행은 후속 작업이다.
- **Flutter 모바일 기본 앱 구현:** [실행 방법과 구현 범위](./mobile/README.md). Android·iOS 공통 화면, 직접 입력하는 간병일기, 약·실제 복약, 일정, 진료 준비, 사진, 암호화 저장·백업·잠금이 AI 없이 동작하도록 구현했다. iOS 빌드와 휴대전화의 네이티브 기능 검증은 별도 단계다.
- 제품 요구사항, 경쟁 전략, 유스케이스와 모바일 데이터 스키마를 정리한 상태
- 로컬 SLM·VLM·RAG와 데이터 검증 계획을 수립한 상태
- 첫 텍스트 실험의 A1~A5 역할·읽기 도구 계약 `v0.1.0`을 고정한 상태
- 7개 공개 평가 원천의 source adapter와 `DS-AGENT` 후보용 Evaluation Scenario Compiler core를 구현한 상태
- 공개 case를 A1~A5/KO 구성요소 요청으로 렌더링하고 Qwen3.5-4B NF4로 원천별 2건 연결 smoke·채점을 수행한 상태. 이는 공식 benchmark나 프로젝트 의료 출시 평가가 아님
- 합성 48개 `DS-AGENT` oracle fixture, 결정적 읽기 전용 도구 host와 SHA-256 체인 trace를 구현·smoke 실행한 상태. 이는 모델 성능이나 의료 출시 결과가 아님
- 실제 모델 출력을 A1~A5 JSON 계약, 결정적 도구 host와 A5 hard gate에 연결하는 DS-AGENT bundle runner를 구현·replay 통합시험한 상태
- 첫 데스크톱 Qwen3.5-4B 실행을 Windows·Python 3.12·Transformers 5.16.1·bitsandbytes NF4/BF16 프로필로 고정하고, T1~T3 각각 48건 자동 개발 진단과 통합 보고서까지 완료한 상태. 어떤 생성 토폴로지도 전체 계약을 통과하지 못했으며 의료 사용 모델은 선택하지 않음
- 다운로드한 Qwen3.5-4B·Qwen3-4B·MedGemma 1.5 4B·Nanbeige4-3B-Thinking·EXAONE 1.2B의 revision·파일 hash와 공통 NF4 프로필을 고정하고 실제 로컬 비교를 완료한 상태. 동일 T1 8건에서 Qwen3.5가 전체 계약·기록 참조 62.5%로 가장 높아 데스크톱 기술 후보로만 유지. 이 연구 결과와 별도로 모바일의 제한된 기록 조회·OCR·음성 입력용 개발 모델을 연결했으며 의료용 모델 채택을 뜻하지 않음
- e약은요 전체 raw snapshot을 staged·review catalog로 변환했으며, 임상 검수 품목 선정 전인 `awaiting_selection` 상태
- [의약품 허가정보·DUR 로컬 수집](./docs/mfds_local_snapshots.md): 공개 API 원문을 재개 가능한 스냅샷과 오프라인 조회 DB로 저장한다. 추가 의료 문서와 함께 미검수 상태로 관리한다.
- 현재 사람·임상 검수 자원을 확보하지 못한 것으로 가정하므로 자동 결과는 개발 진단으로만 사용하고, 승인 지식·의료 답변·의료 출시 게이트는 차단한 상태
- 에이전트 역할·도구·토폴로지 연구 결과는 모바일 제품 구현과 분리해 보관하며, 현재 제품 작업은 기록 기능·사용성·데이터 무결성 보완에 집중
- AI 기능 변경 전 안전 실패 시나리오와 회귀시험을 먼저 확정함

## 요구사항 원본

개발하거나 설계를 변경하기 전에 다음 순서로 확인한다.

1. [`AGENTS.md`](./AGENTS.md) — 프로젝트 작업 원칙과 금지사항
2. [`docs/caregiving_notebook_requirements.md`](./docs/caregiving_notebook_requirements.md) — 제품 요구사항 원본

다른 문서와 요구사항 원본이 충돌하면 `caregiving_notebook_requirements.md`를 우선한다.

Git 업로드 제외 범위, PC용 `.env.example` 사용법, 비밀 설정 확인 방법은 [저장소·환경 설정 안내](./docs/repository_hygiene.md)를 따른다. Flutter의 로컬 AI는 외부 API 키를 요구하지 않는다.

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
| 18 | [로컬 모델 비교 실험 V1](./experiments/agent_eval/results/model_comparison_v1/model_comparison.md) | 다섯 모델의 동일 T1 선별·역할별 protocol probe, 자원 측정과 관찰된 실패 원인 |

## 현재 최우선 작업

Flutter 앱은 `mobile/`에 있다. [안전 실패 시나리오](./docs/non_ai_foundation_safety_plan.md)와 [실행·검증 안내](./mobile/README.md)를 함께 확인한다.

1. 기본 기능·접근성·장기 데이터 처리와 업데이트·백업의 자동 검증을 유지한다.
2. OCR·음성 입력의 오류 수정과 원본 확인 흐름을 유지하고, 의료 정확도와 구분해 개발 품질을 평가한다.
3. 근거 자료의 임상 검수·권리·대상 환자·개정일을 확인한다. 승인 전에는 의료 답변을 보류한다.
4. 배포 준비 직전에 Android 실제 기기의 사진·파일·인증·알림·재부팅·업데이트·메모리와 배터리를 검증한다.
5. iOS 빌드·Keychain·사진·알림·전환 가림과 네이티브 AI는 Mac/Xcode 확보 후 검증한다. Windows 시험으로 완료 처리하지 않는다.

자동 결과에서 Qwen3.5 T1은 기존 48건에서 기대 상태 72.9%, 기록 참조 50.0%였고, 새 동일 8건 모델 비교에서는 전체 계약·기록 참조가 각각 62.5%였다. Qwen3는 기록 참조 12.5%, EXAONE은 A1 스키마 실패로 전체 계약 0%였고, MedGemma와 Nanbeige는 목표 역할 1건의 긴 protocol probe에서도 현재 JSON 계약을 충족하지 못했다. 따라서 Qwen3.5를 데스크톱 개발 기준선으로 유지하지만 전체 계약을 통과하지 못했고 표본도 미검수이므로 의료 성능이나 제품 채택 근거가 아니다.

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

## 현재 기술 구성과 남은 결정

| 영역 | 구현과 검증 상태 |
|---|---|
| 애플리케이션 | Flutter Android·iOS 공통 UI. Android 개발 실행 검증 이력 있음, iOS 빌드 미검증 |
| 저장소 | SQLCipher 간병·식별정보 DB 분리, AES-256-GCM 사진·선택 백업, OS 보안 키 저장소, 선택적 앱 잠금 |
| 로컬 AI | Android 개발용 Qwen3.5-2B SFT/Q4_K_M 기록 조회, PP-OCRv5 학습 CTC 인식, Whisper small LoRA/INT8 음성 입력. 사용자 확인형 입력이며 의료 출시 승인이 아님 |
| 근거 자료 | 문서·의약품 API의 로컬 스냅샷, 압축 패키지·해시 검증·버전별 인용. 운영 의료 답변의 검수 허용 목록은 비어 있음 |
| 안전 | 환자 경계·규칙 우선·근거 부족 시 보류·임의 용량 생성 금지. 임상 규칙 승인과 의료 성능 검증은 미완료 |
| 언어 | 한국어·영어·일본어·중국어 간체/번체 카탈로그 보유. 사용자의 요청에 따라 설정의 언어 변경은 현재 비활성화 |

첫 질환·치료 단계 콘텐츠와 임상 검수자, OCR 지원 자료의 실제 품질 기준, 기기별 최소·권장 사양, 배포 서명과 스토어 선언이 남아 있다. 백업·복원 방식과 대화 보관 선택은 구현돼 있으며 세부 동작은 [모바일 안내](./mobile/README.md)를 따른다.

임상 검수자를 확보하지 못하면 승인 지식베이스, 의료 Q&A와 임상 위험 규칙의 제품 활성화는 계속 차단한다.
