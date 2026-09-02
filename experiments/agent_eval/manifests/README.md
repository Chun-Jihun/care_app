# 에이전트 실험 자산 lock

이 디렉터리는 로컬 모델과 평가·RAG 원천데이터의 출처 선언 및 실제 바이트 무결성 lock을 보관한다.

## 파일

- `asset_sources.json`: 출처, 이용조건 확인 상태, 실험 역할, 학습·모바일·RAG 사용 정책
- `models.lock.json`: 모델 revision과 `.cache`를 제외한 개별 파일 SHA-256
- `data_sources.lock.json`: 데이터별 전체 content-tree SHA-256, 파일 수, 용량과 승인 상태
- `runtime_profiles.json`: 선택한 로컬 추론 엔진·패키지·양자화·장비·fallback 금지와 승인 게이트
- `qwen35_nf4_python312.pip-freeze.txt`: 첫 Qwen3.5 NF4 development smoke에 실제 설치된 Python 패키지 snapshot
- `model_comparison_asset_sources_v1.json`: 실제 다운로드한 M1~M5의 저장소·revision·라이선스와 역할 선언
- `model_comparison_v1/models.lock.json`: 비교 모델 5개의 개별 파일 SHA-256 lock
- `model_comparison_v1/data_sources.lock.json`: 비교 실행에 연결한 데이터 원천 lock
- `model_comparison_runtime_profiles_v1.json`: M1~M5의 공통 NF4 조건과 모델별 tokenizer·chat/output adapter
- `model_comparison_inputs_v1.json`: 동일 8건 선별·역할별 protocol 대조 결과를 묶는 보고서 입력

공개 벤치마크는 모두 `do_not_train=true`, `mobile_bundle=false`, `runtime_rag_eligible=false`이다. e약은요 raw snapshot도 내부 검수·승인 전까지 같은 제한을 유지한다. `missing` 자산은 현재 파일시스템에 없다는 뜻이며 다운로드 완료로 해석하지 않는다.

## 생성과 검증

다음 명령은 네트워크에 접근하지 않고 현재 로컬 파일을 모두 읽어 lock을 갱신한다.

```powershell
python -X utf8 scripts/freeze_asset_manifests.py --hash-workers 4
```

기존 lock과 현재 파일이 같은지 확인하려면 다음을 실행한다.

```powershell
python -X utf8 scripts/freeze_asset_manifests.py --verify --hash-workers 4
```

MIRAGE 전체 검증은 약 110GiB를 읽으므로 시간이 오래 걸린다. 모델·데이터를 의도적으로 교체하거나 수정한 경우에만 출처 선언을 먼저 검토한 뒤 lock을 갱신한다. 평가 결과에는 사용한 `models.lock.json`과 `data_sources.lock.json`의 SHA-256도 함께 기록한다.

`runtime_profiles.json`은 자산 바이트를 다시 hash하는 생성 파일이 아니라 사람이 검토해 고정하는 실행 결정이다. 실제 실행 결과에는 사용한 profile ID와 해당 파일의 SHA-256, 설치된 패키지 버전, GPU·드라이버, peak VRAM을 기록한다. 프로필과 환경이 다르면 자동 fallback하지 않고 새 프로필 ID를 발급한다. 원시 trace는 Git 비추적 `data/` 경계에 두고, 실행 해시와 측정값만 담은 비식별 요약은 `experiments/agent_eval/results/<split>/`에 보관한다. 첫 선택의 근거와 모바일 배포 경계는 [`Qwen3.5-4B 로컬 추론 런타임·양자화 결정`](../../../docs/qwen35_local_runtime_decision.md)을 따른다.

모델 비교 V1의 재현 요약은 [`model_comparison_v1`](../results/model_comparison_v1/model_comparison.md)에 둔다. 이 보고서는 `evaluation_eligible=false`, `model_performance_result=false`, `medical_release_gate_result=false`를 강제하며 데스크톱 기술 후보만 정할 수 있다.

## content-tree SHA-256

데이터 디렉터리의 각 파일에 대해 아래 JSONL 레코드를 결정적 경로 순서로 연결하고 다시 SHA-256한다.

```text
[relative_posix_path, byte_length, file_sha256]
```

`.git`, `.cache`, `__pycache__`, `.env`, `.env.*`, 임시 파일과 운영체제 메타파일은 입력에서 제외한다. 절대경로와 인증정보는 lock에 기록하지 않는다.
