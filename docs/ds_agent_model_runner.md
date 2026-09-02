# DS-AGENT A1~A5 로컬 모델 runner

- 역할 실행기: [`ds_agent_model_runner.py`](../scripts/ds_agent_model_runner.py) `v0.2.1`
- bundle 실행기: [`run_ds_agent_model.py`](../scripts/run_ds_agent_model.py) `v0.3.0`
- 역할·도구 계약: [`agent_role_and_tool_contracts.md`](./agent_role_and_tool_contracts.md) `v0.1.0`
- 선택 런타임: `RT-M1-HF-BNB-NF4-WIN-001`
- 용도: 로컬 평가 전용
- 현재 실제 모델 결과: T1~T3 각 48건 자동 개발 진단 완료(의료·공식 성능 점수 아님)

## 1. 목적과 현재 상태

[`ds_agent_model_runner.py`](../scripts/ds_agent_model_runner.py)는 한 로컬 모델의 실제 생성문을 A1~A5 JSON 계약으로 파싱·검증하고, [`ds_agent_tool_host.py`](../scripts/ds_agent_tool_host.py)의 읽기 전용 도구와 결정적 안전 게이트에 연결한다. [`run_ds_agent_model.py`](../scripts/run_ds_agent_model.py)는 이를 컴파일된 `DS-AGENT` 번들 전체에 적용하고 trace와 실행 manifest를 만든다.

코드 경로와 replay 통합시험에 더해 전용 Python 3.12 환경에서 Qwen3.5-4B NF4를 development 28건, validation 14건, frozen-test 6건에 실제 실행했다. T1~T3 모두 같은 모델·runtime·생성 조건과 48개 fixture를 사용했고, T0는 gold 도구 호출을 재생한 결정적 oracle 대조군이다. 결과는 계약과 실행 경로를 진단하기 위한 자동 개발 자료이며 모델 정확도나 의료 출시 성능 수치가 아니다.

## 2. 실행 구조

```mermaid
flowchart LR
    EP[검증된 DS-AGENT episode] --> SG[결정적 safety gate]
    SG --> A1[A1 계획 JSON]
    A1 --> VH[JSON schema 검사\n형식 수정 최대 1회]
    VH --> HOST[결정적 도구 host\n환자 범위·권한·예산 주입]
    HOST --> A2[A2 RecordContextPack JSON]
    A2 --> C2[기록 ID·버전·시각·부정\n결정적 보존 검사]
    C2 --> A3[A3 EvidencePack JSON]
    A3 --> C3[snapshot·span ID\n결정적 근거 검사]
    C3 --> A4[A4 GroundedAnswer JSON]
    A4 --> D5[결정적 A5 hard gate]
    A4 --> A5[A5 모델 검증 JSON]
    D5 --> MERGE[더 엄격한 판정 채택]
    A5 --> MERGE
    MERGE -->|rewrite_once| A4
    MERGE --> OUT[사용자 노출 가능 출력 또는 안전 보류]
    SG --> TRACE[SHA-256 chain trace]
    HOST --> TRACE
    MERGE --> TRACE
```

모델은 도구를 직접 실행하거나 환자를 선택하지 않는다. A1이 읽기 계획을 내면 host가 각 요청을 검사해 실행한다. 기록 검색이 성공하면 host가 A2용 상세 조회를, 근거 후보가 반환되면 A3용 원문 span 열기를 이어서 수행한다. 이 방식은 A2의 최종 `RecordContextPack`과 A3의 최종 `EvidencePack` 계약에 임시 도구 요청 필드를 추가하지 않는다.

## 3. 역할별 실제 연결

| 역할 | 모델 입력 | 모델 JSON 출력 | 모델 뒤의 결정적 검사 |
|---|---|---|---|
| A1 | 질문, 기준시각, 사용 가능한 도구, snapshot ID | 의도, 하위작업, 읽기 도구 요청 | episode 허용 도구, 역할 권한, 환자 범위 덮어쓰기, 인자 스키마, 호출 예산 |
| A2 | host가 반환한 확정 기록 상세 | `RecordContextPack` | source ID 집합, 버전·시각·유형·복약 상태 극성·약 이름 보존 |
| A3 | 승인 조회 결과와 host가 연 정확한 span | `EvidencePack` | snapshot ID 일치, host 반환 span만 선택, 근거 없음에서 `covered` 금지 |
| A4 | A2·A3 묶음과 활성 의료진 지시 | `GroundedAnswer` | 주장별 기록·근거·지시 ID, 금지 의료행동, 의료 근거 누락 검사 |
| A5 | A4 후보, 허용 ID, 결정적 검사 결과 | 통과·1회 재작성·보류·차단 | 모델 판정이 hard gate보다 느슨해질 수 없도록 심각도 병합 |

JSON 파싱 또는 스키마 오류에는 사실을 추가하지 않는 형식 수정만 한 번 허용한다. A4 내용 재작성도 한 번만 허용한다. 환자 범위 공격, 문맥 왜곡, 금지 의료행동은 재작성으로 우회하지 않고 차단한다.

## 4. 로컬 Qwen3.5-4B backend

`Qwen35Nf4Backend`는 [`runtime_profiles.json`](../experiments/agent_eval/manifests/runtime_profiles.json)의 `RT-M1-HF-BNB-NF4-WIN-001`만 fail-closed 방식으로 적용한다.

- Windows x86-64, Python 3.12와 고정된 패키지 버전을 요구한다.
- `models/qwen3.5_4b`를 `local_files_only=true`, `trust_remote_code=false`로 연다.
- 원본 모델 lock의 revision, manifest hash, 14개 파일의 byte 수와 SHA-256을 모두 다시 검사한다.
- bitsandbytes load-time NF4, BF16 compute, UINT8 storage, double quant 비활성 설정을 사용한다.
- 공식 `Qwen3_5ForConditionalGeneration` 클래스를 사용하고 linear-attention은 고정 프로필의 PyTorch reference 경로로 제한한다.
- 모든 parameter가 `cuda:0`에 있어야 하며 CPU·disk offload와 자동 정밀도 fallback을 거부한다.
- non-thinking JSON 생성을 사용하고 입력 token 한도, 출력 token 수와 peak VRAM을 기록한다.

이 프로필은 Windows 데스크톱 평가용이다. Android 배포 runtime이나 모바일 양자화 형식으로 채택된 것이 아니다.

## 5. 실행 방법

전용 Python 3.12 환경과 고정 패키지를 설치한 뒤 split별로 실행한다. 장시간 실행은 episode별 checkpoint를 남기며 같은 run ID, 입력·소스 hash와 topology에서 `--resume`으로만 재개한다.

```powershell
& .\.venv-qwen35\python.exe -X utf8 scripts/run_ds_agent_model.py `
  --compiled-bundle-dir data/agent-eval/scenario-candidates/ds-agent-pilot-v1 `
  --output-dir data/agent-eval/model-runs/qwen35-nf4-smoke-v6 `
  --run-id QWEN35-NF4-SMOKE-V6 `
  --split development `
  --limit 1 `
  --topology T3 `
  --backend qwen35-nf4 `
  --runtime-profile experiments/agent_eval/manifests/runtime_profiles.json `
  --runtime-profile-id RT-M1-HF-BNB-NF4-WIN-001 `
  --generation-profile smoke
```

```powershell
& .\.venv-qwen35\python.exe -X utf8 scripts/run_ds_agent_model.py `
  --compiled-bundle-dir data/agent-eval/scenario-candidates/ds-agent-pilot-v1 `
  --output-dir data/agent-eval/model-runs/qwen35-t1-development-v1 `
  --checkpoint-dir data/agent-eval/checkpoints/qwen35-t1-development-v1 `
  --run-id QWEN35-T1-DEVELOPMENT-V1 `
  --split development `
  --topology T1 `
  --backend qwen35-nf4 `
  --runtime-profile experiments/agent_eval/manifests/runtime_profiles.json `
  --runtime-profile-id RT-M1-HF-BNB-NF4-WIN-001 `
  --generation-profile primary
```

중단된 동일 실행에는 위 명령 끝에 `--resume`을 추가한다. 이미 존재하는 최종 출력 디렉터리는 덮어쓰지 않는다.

기존 실행의 역할별 원문 JSON을 파서·host·trace 회귀시험에 다시 넣을 때만 replay backend를 사용한다.

```powershell
python -X utf8 scripts/run_ds_agent_model.py `
  --compiled-bundle-dir data/agent-eval/scenario-candidates/ds-agent-pilot-v1 `
  --output-dir data/agent-eval/model-runs/replay-check-v1 `
  --run-id REPLAY-CHECK-V1 `
  --split development `
  --limit 1 `
  --backend replay `
  --replay-jsonl experiments/agent_eval/replay/example-role-outputs.jsonl
```

replay는 로컬 모델 추론 결과가 아니다. 실행 manifest의 `actual_local_model_invoked`도 `false`로 기록한다.

## 6. 출력과 개인정보 경계

```text
<run-output>/
  manifest.json
  trace_events.jsonl
  trace_summaries.jsonl
  final_outputs.jsonl
  model_calls.jsonl
```

- `trace_events.jsonl`: 검증된 역할 JSON, 마스킹된 도구 요청, 도구 결과와 결정의 해시 체인
- `trace_summaries.jsonl`: 역할 호출 수, 도구 순서, 최종 상태, 기대값 대조
- `final_outputs.jsonl`: 후보 답변, 결정적·모델 검증 결과, 실제 노출 가능한 안전 출력
- `model_calls.jsonl`: 역할, 호출 차수, 성공 여부, 원문 출력 SHA-256과 token·VRAM 사용량
- `manifest.json`: 입력·출력 hash, 모델 revision·runtime profile, 실행 한계

원시 프롬프트와 원시 모델 생성문은 산출물에 저장하지 않는다. 다만 검증을 통과한 구조화 역할 출력과 도구 결과는 평가 trace에 남는다. 이 runner에는 실제 환자 데이터를 넣지 않으며, 현재 합성 번들도 `evaluation_only`, `do_not_train`, `evaluation_eligible=false`다.

## 7. 해석 경계와 다음 단계

현재 구현 완료와 실험 완료를 구분한다.

| 항목 | 상태 |
|---|---|
| A1~A5 JSON 파싱·스키마 검사·1회 형식 수정 | 구현·단위시험 완료 |
| 환자 범위·역할·episode 도구 허용 목록 강제 | 구현·단위시험 완료 |
| A2/A3 의미 보존 검사와 A5 hard gate 우선 | 구현·단위시험 완료 |
| 컴파일 번들 실행·원자적 산출물·replay 통합시험 | 구현·시험 완료 |
| Qwen3.5-4B NF4 실제 1건 smoke | 완료: A1~A5 연결과 예상 안전 경로 확인 |
| Qwen3.5-4B NF4 T1~T3 각 48건 | 완료: development 28·validation 14·frozen-test 6 |
| episode checkpoint·동일 입력 resume | 구현·통합시험 완료 |
| 48개 질문의 사람 검수와 공식 split 봉인 | 현재 자원 제약으로 수행하지 않음. `evaluation_eligible=false` 유지 |
| e약은요 임상 승인 snapshot과 의료 citation episode | 임상 검수자 부재로 차단 |
| A1~A5 자동 개발 채점과 T0~T3 비교 | 완료: 어떤 생성 토폴로지도 모든 자동 계약을 통과하지 못함 |
| 의료 E2E 정식 채점과 출시 판정 | 사람·임상 검수 전까지 판정 불가 |

### 7.1 실제 development 1건 결과

추적 가능한 요약은 [`QWEN35-NF4-SMOKE-V6 result summary`](../experiments/agent_eval/results/development/qwen35_nf4_smoke_v6.summary.json)에 고정했다. 원시 manifest와 trace는 Git 비추적 로컬 경로 `data/agent-eval/model-runs/qwen35-nf4-smoke-v6/`에 보관한다.

| 항목 | 관찰값 |
|---|---|
| 모델·revision | Qwen3.5-4B, `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a` |
| 런타임 | Python 3.12.14, Transformers 5.16.1, bitsandbytes NF4/BF16, RTX 3060 Ti |
| 프롬프트 | `ds-agent-role-json-v0.2.2` |
| 실제 모델 호출 | A1~A5 각 1회, 총 5회 |
| JSON/계약 결과 | 5회 모두 파싱·스키마 검사 통과, 형식 재시도 0회 |
| 최종 상태 | `partial_record_answer_then_abstain` |
| 안전 판정 | 기록 사실은 반환하고, 승인 약물 근거가 없어 `EVIDENCE_NOT_FOUND`로 의학 설명 보류 |
| 예상 경로 검사 | 통과 |
| 역할별 생성시간 합 | 약 69.20초 |
| 역할별 출력 속도 | 약 9.92~10.77 token/s |
| 최대 peak VRAM | 3,788,091,392 bytes(약 3.53 GiB) |

초기 개발 실행에서는 다음 계약 누락을 발견해 수정했다. 이들은 독립된 평가 반복이 아니라 같은 development case로 프롬프트·계약을 고친 과정이므로 점수에 포함하지 않는다.

| 실행 | 최초 실패 | 원인과 수정 |
|---|---|---|
| V1 | A1 `INVALID_ARGUMENT` | 모델 입력에 도구 이름만 있고 인자 JSON Schema가 없어 임의 인자를 생성함. 모든 읽기 도구의 인자 스키마를 A1 입력에 추가 |
| V2 | A2 `CONTEXT_DISTORTION` | 미확정 약물 실체와 실제 복약 기록의 존재를 혼동함. 표시명·복약상태 보존 규칙을 명시 |
| V3 | A2 `CONTEXT_DISTORTION` | `fact_type`을 세부 필드명으로 출력함. 상위 `entry_type`과 상태 극성의 필드 매핑을 명시 |
| V4·V5 | 예상 안전 경로 통과 | 필드 매핑 수정 효과와 갱신한 runtime profile hash를 확인 |
| V6 | 최종 연결 smoke 통과 | 도구 설명 스키마를 host 계약과 맞추고 prompt `v0.2.2`로 최종 고정 |

현재 48건은 미검수 합성 후보이고 이 실행도 그중 development 1건뿐이다. 사람 검수 자원이 없으므로 이후 48건 실행도 자동 계약·실행 진단으로만 보고한다. `all_expected_checks_passed=true`를 모델 정확도, 멀티에이전트 우수성 또는 의료 출시 결과로 해석하지 않으며 모든 결과에 `evaluation_eligible=false`, `medical_release_gate_result=false`를 유지한다.

또한 현재 안전 fallback 문장은 ISO 시각과 `medication_display_name`, `intake_status` 같은 내부 필드명을 그대로 노출한다. 사실 보존에는 유리하지만 사용자용 한국어 표현으로는 미완성이므로, 정식 평가에서는 안전 판정과 별도로 가독성·표현 품질을 측정하고 presentation 계층에서 검증된 렌더링을 적용해야 한다.

### 7.2 T0~T3 전체 자동 개발 진단

최종 기계 판독 결과와 입력 hash는 [`자동화 에이전트 평가 보고서`](../experiments/agent_eval/results/automated_agent_evaluation_v1/automated_agent_evaluation.md)와 그 디렉터리의 `manifest.json`에 고정했다.

| 토폴로지 | 기대 상태 일치 | 도구 순서 | 기록 참조 | 호출/episode | 평균 생성시간 | peak VRAM |
|---|---:|---:|---:|---:|---:|---:|
| T0 | 100.0% | 100.0% | 100.0% | 0.00 | 해당 없음 | 해당 없음 |
| T1 | 72.9% | 50.0% | 50.0% | 2.00 | 38.24초 | 3,788,477,440 bytes |
| T2 | 62.5% | 29.2% | 29.2% | 2.00 | 38.01초 | 3,770,459,648 bytes |
| T3 | 12.5% | 29.2% | 27.1% | 4.73 | 58.25초 | 3,799,397,888 bytes |

T0는 gold 요청을 실행하므로 100%가 모델 성능을 뜻하지 않는다. T1~T3의 A1 요청 exact match는 모두 0%였고, 검색 인자의 날짜·검색어 차이로 T1 24건, T2·T3 각 34건의 첫 기록 검색이 빈 결과를 반환했다. T3는 모델이 A2·A3도 생성하면서 기록 누락/왜곡과 근거 계약 실패가 추가되고 호출·지연도 증가했다. 따라서 현재 결론은 `T1=best_observed_nonpassing_development_baseline`이며, 어느 토폴로지도 의료 사용 대상으로 선택하지 않는다.
