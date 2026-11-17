# 간병수첩 문서

[프로젝트 소개](../README.md)

| 찾는 내용 | 시작할 문서 |
| --- | --- |
| 수첩 만들기, 복약, 진료 녹음, 백업 | [앱 사용 안내](mobile_current_guide.md) |
| 소스로 실행하고 검사하거나 Android로 배포하기 | [모바일 개발 안내](../mobile/README.md) |
| 지원 범위와 의료·개인정보 기준 확인하기 | [제품 요구사항](caregiving_notebook_requirements.md) |
| 기기 AI 설치와 개발 | [모바일 AI와 모델 설치](mobile_ai_integration.md) |

## 제품과 설계

- [화면 흐름과 유스케이스](caregiving_notebook_use_case_design.md)는 사용자 작업을 기능 요구사항에 연결합니다.
- [목표 데이터 스키마](mobile_app_data_schema_design.md)는 저장 경계와 ERD를 설명합니다. 실제 저장소 버전은 [개발 안내](../mobile/README.md#저장소와-백업-형식)에서 확인합니다.
- [안전 검증 시나리오](safety_validation.md)는 기록·백업·화면·AI 변경 시 재현할 실패 사례를 모아 둡니다.
- [제품 전략과 사용자 조사](competitive_landscape_and_product_strategy.md)는 제품을 설계한 이유와 효과 측정 방법을 설명합니다.
- [용어집](../GLOSSARY.md) · [설계 결정 기록](adr/)

## AI 연구와 검증

| 분야 | 참고 문서 |
| --- | --- |
| 연구 목적과 결과 해석 | [에이전트 연구 계획](agent_architecture_and_evaluation_plan.md) · [개발 평가 결과와 한계](no_human_review_development_plan.md) |
| 자료 수집과 임상 승인 | [자료·이용 권한 목록](model_and_rag_data_catalog.md) · [식약처 자료 수집](mfds_local_snapshots.md) · [e약은요 승인 절차](mfds_easy_drug_approval_workflow.md) |
| 검증과 배포 형식 | [모델·검색 평가 계획](slm_rag_validation_plan.md) · [근거 자료 패키지](mobile_knowledge_package.md) |

<details>
<summary>평가 구현과 실험 재현 문서</summary>

- [역할·도구 계약](agent_role_and_tool_contracts.md)
- [공개 평가 어댑터](evaluation_source_adapters.md) · [시나리오 컴파일러](evaluation_scenario_compiler.md) · [구성요소 평가 하네스](role_component_evaluation_harness.md)
- [결정적 도구 파일럿](ds_agent_deterministic_pilot.md) · [로컬 모델 실행기](ds_agent_model_runner.md) · [데스크톱 런타임 결정](qwen35_local_runtime_decision.md)
- [고정 자산](../experiments/agent_eval/manifests/README.md) · [기준선](../experiments/ai_baseline_v1/README.md) · [학습·증류](../experiments/ai_training_v1/README.md) · [추가 검증](../experiments/ai_validation_v1/README.md)

</details>

## 개발 참고와 변경 이력

- [저장소와 환경 설정](repository_hygiene.md) · [번역 변경](../mobile/lib/l10n/README.md) · [백업 호환성 시험 자료](../mobile/test/fixtures/README.md)
- [프로젝트 작업 원칙](../AGENTS.md) · [이슈 관리 방식](agents/issue-tracker.md)
- [실기기 검증·품질 감사·연구 이력](history/README.md). 각 기록의 날짜와 기기·실험 조건을 기준으로 읽습니다.
