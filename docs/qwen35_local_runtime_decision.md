# Qwen3.5-4B 로컬 추론 런타임·양자화 결정

## 목차

1. [결정 요약](#1-결정-요약)
2. [적용 범위](#2-적용-범위)
3. [고정 실행 프로필](#3-고정-실행-프로필)
4. [선정 이유](#4-선정-이유)
5. [채택하지 않은 대안](#5-채택하지-않은-대안)
6. [설치와 실행 확인](#6-설치와-실행-확인)
7. [양자화 승인 게이트](#7-양자화-승인-게이트)
8. [모바일 배포와의 경계](#8-모바일-배포와의-경계)
9. [근거 자료](#9-근거-자료)

## 1. 결정 요약

2026-09-02 기준 첫 Qwen3.5-4B 에이전트 실험의 로컬 실행 조합을 다음과 같이 확정한다.

| 항목 | 확정값 |
|---|---|
| 범위 | Windows 개발 PC에서 수행하는 A1~A5 구성요소 smoke와 `DS-AGENT` T1~T3 텍스트 구조 비교 |
| 프로필 ID | `RT-M1-HF-BNB-NF4-WIN-001` |
| 모델 | 로컬 `models/qwen3.5_4b`, revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a` |
| OS·Python | Windows x86-64 네이티브, Python 3.12 전용 가상환경 |
| 추론 엔진 | Hugging Face Transformers 인프로세스 backend |
| GPU | NVIDIA GeForce RTX 3060 Ti 8GB, `cuda:0` |
| 양자화 | bitsandbytes load-time 4-bit NF4 |
| 연산·저장 dtype | BF16 compute, UINT8 quant storage |
| double quant | 사용하지 않음 |
| attention | PyTorch SDPA |
| linear-attention kernel | Transformers PyTorch reference; `fla`·`causal_conv1d` 미사용 |
| 실행 경계 | batch 1, CPU·disk offload와 정밀도 자동 fallback 금지, 로컬 파일만 사용 |
| 기본 생성 모드 | non-thinking. 공통 결정적 1차 점수 뒤 고정 seed 5개의 공식 non-thinking sampling 2차 점수 수행 |

기계 판독 가능한 원본은 [`runtime_profiles.json`](../experiments/agent_eval/manifests/runtime_profiles.json)의 `RT-M1-HF-BNB-NF4-WIN-001`이다. 문서와 JSON이 다르면 JSON을 실행 입력으로 사용하되 차이를 결함으로 처리한다.

이것은 **첫 데스크톱 실험 런타임의 확정**이다. Qwen3.5-4B를 최종 제품 모델로 채택하거나 NF4의 의료 품질을 승인했다는 뜻은 아니다.

이 프로필을 읽어 model lock·패키지·GPU 조건을 검사하고 A1~A5 JSON 계약에 연결하는 backend는 [`DS-AGENT A1~A5 로컬 모델 runner`](./ds_agent_model_runner.md)에 구현했다. 전용 Python 3.12 환경의 실제 development 1건 smoke까지 통과했으며, 기계 판독 상태는 `execution_status=development_smoke_passed_not_performance_scored`다.

## 2. 적용 범위

이 프로필은 다음에 사용한다.

- 공개 평가 case의 A1~A5 로컬 smoke
- 같은 Qwen3.5-4B를 사용하는 T1 단일 제한형과 T2·T3 역할 분리 구조 비교
- 양자화·런타임으로 인한 JSON, 부정, 시각, 숫자·단위와 근거 충실도 오류 측정
- 실제 로컬 모델 backend를 연결한 `DS-AGENT` trace 생성

다음에는 사용하지 않는다.

- 실제 환자 기록 입력
- 승인 전 e약은요 자료를 의료 RAG 근거로 사용하는 실행
- Android 제품 번들 또는 모바일 성능 주장
- A6 처방자료·음식 사진 평가
- 파인튜닝 또는 QLoRA 학습

## 3. 고정 실행 프로필

### 3.1 패키지

| 패키지 | 버전 |
|---|---:|
| Python | `3.12` |
| PyTorch | `2.12.1+cu126` |
| torchvision | `0.27.1+cu126` |
| Transformers | `5.16.1` |
| Accelerate | `1.14.0` |
| bitsandbytes | `0.50.2` |
| Pillow | `12.3.0` |

기본 Python 3.14 환경이나 MedAgentBench 환경을 재사용하지 않는다. 실제 실행에는 저장소 안의 전용 Conda prefix `.venv-qwen35`와 Python 3.12.14를 사용했다. 실행 manifest에는 고정 핵심 패키지, Python·CUDA·드라이버·GPU, 모델·runtime profile hash를 남기고, 전체 설치 패키지는 [`pip-freeze snapshot`](../experiments/agent_eval/manifests/qwen35_nf4_python312.pip-freeze.txt)으로 고정했다. 설치 wheel 자체의 해시는 후속 재현성 보강 항목이다.

### 3.2 양자화 설정

동등한 Transformers 설정은 다음과 같다.

```python
BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_quant_storage=torch.uint8,
    bnb_4bit_use_double_quant=False,
)
```

양자화는 고정한 BF16 원본을 읽을 때 메모리에서 수행한다. 별도 양자화 weight 파일이 생기지 않으므로 실행의 모델 정체성은 `models.lock.json SHA-256 + runtime profile SHA-256`으로 구성한다. 커뮤니티가 변환한 양자화 파일을 같은 프로필에 대신 넣지 않는다.

double quant는 약간의 메모리를 더 줄일 수 있지만 4B·8GB·batch 1 조건에서 우선 필요하다고 입증되지 않았다. 의료 정확성을 우선해 양자화 단계를 하나 더 추가하지 않는 값을 기본으로 정했다. OOM이면 `double_quant=true`로 조용히 바꾸지 않고 해당 실행을 실패 처리한 뒤 새로운 프로필 ID로 비교한다.

### 3.3 로딩·보안 설정

- `local_files_only=true`
- `trust_remote_code=false`
- `device_map={"": "cuda:0"}`
- Qwen3.5 모델 클래스는 `Qwen3_5ForConditionalGeneration`으로 고정
- 선택 프로필에 없는 `fla`·`causal_conv1d`가 설치되어 있으면 kernel 조건이 달라지므로 중단
- CPU·disk offload 금지
- BF16 미지원, 패키지 버전 불일치 또는 CUDA OOM이면 중단
- 실행 중 외부 네트워크 접근 금지
- 모델 parameter가 CPU나 disk로 이동했으면 실행 결과 폐기
- 평가 전용 비식별·합성 입력만 사용

### 3.4 문맥과 생성 설정

첫 smoke는 입력 4,096 token, 출력 512 token, batch 1과 non-thinking greedy로 실행한다. 그 뒤 T0~T3의 공통 조건을 맞추는 1차 점수도 같은 결정적 생성 설정으로 계산한다.

2차 공급자 권장 설정은 non-thinking, `temperature=0.7`, `top_p=0.8`, `top_k=20`, `min_p=0`, `repetition_penalty=1.0`과 seed 5개다. Transformers 인프로세스 backend가 동일 의미로 지원하지 않는 `presence_penalty`는 넣지 않는다. 이 결과로 `pass^1`, `pass^k`, 평균과 실패 분산을 보고한다. 결정적 1차와 권장 sampling 2차를 합쳐 하나의 점수로 만들지 않는다.

LongHealth는 4,096 token으로 잘라 점수를 내지 않는다. VRAM peak와 사실 보존율을 8K→16K→32K 순으로 측정해 사용할 수 있는 최대 문맥을 별도 고정한 뒤 A2 점수를 계산한다.

## 4. 선정 이유

1. 고정 모델은 BF16 파일만 약 9.3GB라 8GB VRAM에 원본 그대로 전부 올리는 구성이 맞지 않는다.
2. bitsandbytes는 Windows x86-64 NVIDIA CUDA에서 4-bit를 공식 지원하므로 WSL이나 별도 서버 없이 현재 장비에서 첫 실험을 시작할 수 있다.
3. NF4는 단순 INT4보다 분포 기반 weight 표현을 사용하고 Transformers에서 원본 checkpoint를 직접 읽어 적용할 수 있어 원본 revision과 추적관계를 유지하기 쉽다.
4. 첫 실험은 동시 사용자 serving이 아니라 batch 1 역할 비교이므로 vLLM의 continuous batching 이점보다 설치·trace 단순성이 중요하다.
5. Qwen3.5의 하이브리드·멀티모달 구조를 공식 Transformers 구현으로 먼저 실행하면 GGUF 변환기 차이와 에이전트 토폴로지 차이를 첫 실험에서 섞지 않을 수 있다.

## 5. 채택하지 않은 대안

| 대안 | 첫 실험에서 제외한 이유 | 후속 사용 조건 |
|---|---|---|
| BF16 원본 전체 GPU 적재 | 원본 파일 규모가 8GB VRAM을 넘고 실행 여유가 없음 | 더 큰 GPU에서 NF4 품질 상한 비교 |
| bitsandbytes INT8 | NF4보다 메모리 여유가 작아 긴 문맥·반복 실행에 불리함 | NF4 hard gate 실패 시 품질 대조군 |
| NF4 + double quant | 현재 조건에서 추가 압축 필요성이 아직 없으며 양자화 단계를 늘림 | OOM 재현 후 별도 프로필로만 비교 |
| vLLM | 네이티브 Windows 경로가 없고 첫 batch-1 실험에는 서버 복잡도가 큼 | Linux/WSL에서 처리량 비교가 필요할 때 |
| llama.cpp + GGUF | 모바일 후보에는 유력하지만 변환·커널 차이가 첫 토폴로지 실험에 추가 변수가 됨 | 목표 Android 장비를 정한 뒤 Q5_K_M→Q4_K_M 순으로 별도 검증 |
| 임의 커뮤니티 4-bit 파일 | 원본 revision, 변환 도구·설정과 해시 추적이 불충분할 수 있음 | 전체 provenance와 해시가 확인될 때 새 프로필로 등록 |

## 6. 설치와 실행 확인

이 PC에는 `py -3.12`로 등록된 Python이 없어 다음 Conda prefix 방식으로 전용 환경을 생성하고 고정 패키지를 설치했다.

```powershell
conda create --prefix .\.venv-qwen35 python=3.12 pip -y
& .\.venv-qwen35\python.exe -m pip install torch==2.12.1 torchvision==0.27.1 --index-url https://download.pytorch.org/whl/cu126
& .\.venv-qwen35\python.exe -m pip install transformers==5.16.1 accelerate==1.14.0 bitsandbytes==0.50.2 pillow==12.3.0
```

`QWEN35-NF4-SMOKE-V6`에서 다음을 확인해 development smoke 상태를 통과로 변경했다.

1. Python·패키지 버전이 프로필과 정확히 일치한다.
2. `models.lock.json` 검증이 통과한다.
3. `torch.cuda.is_available()`와 `torch.cuda.is_bf16_supported()`가 참이다.
4. 모델이 NF4로 로드되고 모든 parameter가 `cuda:0`에 있다.
5. 네트워크를 차단한 상태에서 1개 request를 끝까지 생성한다.
6. peak VRAM, 입력·출력 token, 초당 token, wall time을 trace에 남긴다.
7. 출력 JSON schema 위반과 비정상 종료가 없고, 원문 prompt·환자정보가 외부 로그에 남지 않는다.

실행 결과는 [`development result summary`](../experiments/agent_eval/results/development/qwen35_nf4_smoke_v6.summary.json)에 고정하고, 원시 산출물은 Git 비추적 로컬 경로에 분리했다. A1~A5 총 5회 생성이 모두 계약을 통과했고, 최대 peak VRAM은 약 3.53 GiB였다. 승인 약물 근거가 없는 합성 case였기 때문에 기록만 반환하고 의학 설명은 `EVIDENCE_NOT_FOUND`로 보류했다. 이는 연결 smoke 결과이며 양자화 품질 또는 의료 성능 승인이 아니다.

## 7. 양자화 승인 게이트

NF4는 메모리상 실행 기준일 뿐 품질 승인 기준이 아니다. 제품 후보로 승격하려면 같은 모델 revision의 BF16 품질 상한 또는 INT8 대조군과 ABL-05를 수행한다.

- 근거에서 확인할 수 없는 의학적 핵심 주장: `0건`
- 환자 범위 누출과 승인되지 않은 외부 전송: `0건`
- 고위험 누락과 A5 잘못된 승인: `0건`
- 도구 이름·인자, 시간·부정, 숫자·단위, record/evidence ID의 NF4 회귀를 역할별로 보고
- hard gate 하나라도 나빠지면 평균 점수가 좋아도 NF4 제품 채택 금지
- 정확한 citation locator 연결률, latency와 VRAM은 hard gate 통과 후 개선 KPI로 비교

## 8. 모바일 배포와의 경계

현재 프로필은 모바일 런타임이 아니다. Android 후보는 `llama.cpp + 자체 변환 GGUF`를 우선 검토하되 아직 양자화 방식을 확정하지 않는다.

모바일 결정 순서는 다음과 같다.

1. 최소·권장 Android 실기기와 허용 RAM·저장공간·배터리·응답시간 확정
2. 같은 M1 revision에서 GGUF를 직접 변환하고 변환기 commit·명령·파일 SHA-256 기록
3. 정확도 우선 `Q5_K_M`을 먼저 시험하고, 메모리·지연이 기준을 넘을 때만 `Q4_K_M` 비교
4. A1~A5 계약, 의료 hard gate, 오프라인·발열·중단 복구 시험
5. 통과한 경우에만 별도 `RT-M1-LLAMACPP-GGUF-ANDROID-*` 프로필 생성

따라서 “데스크톱 NF4 통과”를 “모바일 GGUF 통과”로 대체 해석하지 않는다.

## 9. 근거 자료

- [Qwen/Qwen3.5-4B 공식 모델 카드](https://huggingface.co/Qwen/Qwen3.5-4B) — 공식 Transformers 로딩 클래스, 기본 thinking 동작과 non-thinking sampling 권장값
- [Hugging Face Transformers Qwen3.5 문서](https://huggingface.co/docs/transformers/model_doc/qwen3_5) — Qwen3.5 구조와 공식 모델 클래스
- [Transformers 5.16.1 릴리스](https://github.com/huggingface/transformers/releases/tag/v5.16.1) — 고정한 runtime 버전
- [Transformers bitsandbytes 양자화 문서](https://huggingface.co/docs/transformers/quantization/bitsandbytes) — `BitsAndBytesConfig`, NF4와 compute dtype 설정
- [bitsandbytes 0.50.2 배포 정보](https://pypi.org/project/bitsandbytes/0.50.2/) — Windows x86-64 CUDA와 4-bit 지원, 배포 버전
- [PyTorch 2.12.1 이전 버전 설치표](https://pytorch.org/get-started/previous-versions/) — Windows CUDA 12.6용 PyTorch·torchvision 조합
- [vLLM GPU 설치 문서](https://docs.vllm.ai/en/stable/getting_started/installation/gpu.html) — Linux 중심 지원과 WSL 경계
- [llama.cpp 빌드 문서](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md) — 후속 Windows·Android GGUF runtime 후보
