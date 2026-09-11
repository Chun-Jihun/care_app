# AI baseline V1 — 사전 실험 정의

2026-09-10. [모델 조사](../../docs/ai_model_research_2026-09-10.md)의 첫 비교 실험이다. 앱의 의료 기능을 활성화하거나 모델을 학습하는 실행이 아니다.

완료 결과는 [판단 보고서](../../docs/ai_baseline_results_2026-09-10.md)와 [검증된 집계](results/completed-2026-09-10/results.md)를 참조한다. 토크나이저 연결부의 출처·라이선스는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 보존했다.

## 범위와 사전 실패 조건

- 챗봇: 기존 8건 비교의 실패를 재분류한다. 새로운 합성 기록에서 명시적 조회 조건과 원문 사실을 추출하는 제한 과업을 Qwen3.5-2B/4B, Gemma 4 E2B로 비교한다. 기존 DS-AGENT의 end-to-end 점수와 직접 합산하지 않는다.
- OCR: 개인정보 없는 합성 문서를 생성하고 한국어·영어·일본어·중국어 간체·번체를 구분한다. 한국어 전용 모델에는 한국어/영어만 평가하며 다른 문자권을 지원한다고 보고하지 않는다. 각 문서는 clean / 흐림 / 낮은 대비 / 작은 글씨 중 한 변형으로 생성한다. 개발 40개 생성 그룹, 4개 외형 조건이며 실제 독립 처방 서식 200종은 아니다.
- ASR: 공개 FLEURS validation의 한국어·영어·일본어·중국어 음성과 무음 대조군을 사용한다. 실제 환자 녹음은 사용하지 않는다. 일반 읽기 음성 결과를 약명·진료실 전사 정확도로 해석하지 않는다.
- 모든 새 합성 자료는 `compiler_generated_unreviewed`, `evaluation_eligible=false`다. 공개 ASR 정답은 원래 출처의 전사이며 이 앱의 임상 검수를 통과한 자료가 아니다.
- 잘못된 JSON, 존재하지 않는 기록 ID, 수치·단위·부정 변경은 과업 실패다. 형식 준수와 의미 정확도를 따로 보고한다. 중요한 문자 차이를 정규화로 지우지 않는다.
- OCR/ASR은 원문과 초안만 평가하며 확정 저장 호출이 없다. 이미지·음성 속 문장은 도구 실행 권한을 주지 않는다.
- 모델·입력·프롬프트·실행 코드의 hash와 실제 패키지 버전을 결과에 기록한다. 손상, 미지원 모델, 실행 오류, 불완전 실행을 0점 또는 성공으로 바꾸지 않는다.
- 모델 및 공개 자료 다운로드와 추론을 분리한다. 다운로드 시 비밀키·환자 자료를 읽지 않는다. 추론은 로컬 파일만 사용하고 프로세스의 외부 소켓 연결을 거부한다.
- 고정한 모델별 최대 토큰, 샘플 수와 입력 목록은 실행 기록에 남긴다. 결과를 본 뒤 같은 버전의 정답이나 분할을 수정하지 않는다.
- 실험 코드는 별도 모듈과 가상환경에 둔다. 기존 고정 NF4 환경·프로필·실험 원본과 앱 코드는 보존한다.

## 착수 규모

합성 챗봇 개발 200건 / 별도 held-out 100건, OCR 개발 문서 200장 / 별도 held-out 50장을 준비한다. ASR은 언어별 최대 50개, 총 200개의 공개 validation 발화를 가져오며 무음 대조군을 추가한다. 최초 연결 확인 후 개발 분할을 실행한다. held-out 분할은 최종 채택을 위한 임상 시험이 아니며 이번 개발 비교에서 열지 않는다.

반복 변형과 서식 수를 함께 보고한다. 200개의 합성 예시가 200명의 실제 사용자 또는 200개 독립 처방 서식을 뜻하지 않는다.

2026-09-10 실행 순서: 연결 확인용 소량 실행을 별도 보관하고, 챗봇 후보는 우선 언어별 첫 8건(총 40건, 모든 8개 과업 유형)을 동일하게 비교한다. 이후 실행 가능한 후보의 개발 200건을 측정한다. 소량 실행과 전체 개발 실행을 합산하지 않는다. OCR은 지원 언어별 40장, ASR은 언어별 50건과 무음 3건을 사용한다. 이번 latency는 batch 1, 별도 warmup 없이 첫 추론을 포함하며 모델 로딩 시간은 분리한다.

추가 대조군 실행 전 규모 확정: filter 방식은 작은 Qwen3.5-2B로 개발 200건을 실행하고 4B로 첫 40건을 대조한다. 모델/방식 간 비교는 같은 첫 40건끼리 하며, 2B의 나머지 160건은 해당 개발 방식의 확장 검사로 별도 보고한다. baseline 200건을 실행한 것으로 표기하지 않는다.

실행 불가 후보가 생기면 구체적인 원인과 시도한 해결을 기록하고 다른 후보를 계속 측정한다. 추가 학습은 이 비교에서 드러난 반복 오류와 배포 가능성을 확인한 뒤 결정한다.

## 재현 방법

프로젝트 루트에서 전용 환경의 Python으로 실행한다. [runtime-versions.txt](runtime-versions.txt)는 실제 사용한 주요 패키지 버전이다. 이 실험은 `.venv-qwen35`를 상속하는 별도 `.tools/ai-baseline-venv`에 추가 의존성을 설치했다. 기존 환경 패키지는 변경하지 않았다. GPU 모델은 RTX 3060 Ti 8GB, OCR은 CPU를 사용한다.

[runtime-environment.json](runtime-environment.json)에 전체 패키지 버전과 Python/OS를 보존했다. 관측 NVIDIA 드라이버는 610.88이다. latency는 입력 전처리·디코딩·채점을 포함하는 건별 wall time이며 p95는 상위 경험 분위수를 사용한다. 운영 앱의 추론 전용 지연이나 스마트폰 지연과 동일하지 않다.

```powershell
# 공개 파일 다운로드 단계: 모델/데이터의 고정 revision과 개별 SHA-256을 기록한다.
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.prepare_ai_baseline_assets --fleurs

# Paddle 3.3.1의 import 시 고정된 홈 캐시를 전용 환경에서만 환경 변수로 설정 가능하게 한다.
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.patch_ai_baseline_runtime

# 최초 한 번만 실행. 기존 동결 자료는 덮어쓰지 않는다.
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.prepare_ai_baseline_inputs --task synthetic
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.prepare_ai_baseline_inputs --task asr

# run-id는 매번 새 값이어야 한다. --limit-per-language 0은 준비한 개발 자료 전체다.
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.run_ai_baseline --task chat --model qwen35_2b --limit-per-language 8 --run-id example-chat-screen40
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.run_ai_baseline --task chat --model qwen35_2b --mode grammar --limit-per-language 8 --run-id example-chat-grammar40
.tools/ai-baseline-venv/Scripts/python.exe -m scripts.queue_ai_baseline transcription
.tools/ai-baseline-venv/Scripts/python.exe -m unittest discover -s tests
```

실행 원본은 `data/ai-baseline-v1/runs/<run-id>/`의 manifest·predictions·summary에 남는다. 집계 보고서는 `scripts.report_ai_baseline`에 실행 ID와 새 report ID를 지정해 만든다. 모델 파일과 대용량 입력은 Git에 포함하지 않는다. 입력 manifest의 글꼴 경로·face index·hash를 확인해야 픽셀 단위로 재현할 수 있으며 Windows 글꼴은 재배포하지 않는다.

추론은 `local_files_only=True`, 원격 코드 비활성, 오프라인 환경 변수, Python 소켓 audit hook을 사용한다. 이 hook은 Python 네트워크 시도를 차단하는 것이며 native 라이브러리의 패킷 캡처 검증을 대신하지 않는다. 모바일 앱의 실제 네트워크·권한 검증은 별도다.

### 비교 해석

- 챗봇은 호스트가 선택한 3개 기록 중 조회·원문 복사·보류를 수행하는 부품 시험이다. 이전 DS-AGENT의 검색·도구 호출 전체 점수와 직접 비교하지 않는다.
- `plain`과 `grammar`는 같은 프롬프트·입력·토큰 한도를 사용한다. grammar는 JSON 문법과 키/타입만 제한하며 정답 ID나 정답 문자열을 주입하지 않는다. LMFE 0.11.3의 Transformers 연결부가 5.16에서 제거된 import를 사용해 공개 core API를 호출하는 어댑터를 따로 두었다.
- 첫 plain 결과 확인 후 추가한 `filter`는 질문만 모델에 보내 kind/day/time/item을 뽑게 하고, 호스트가 세 조건을 모두 일치시키며 값을 원문에서 복사한다. 별도 소수 예시·프롬프트·계약·작업 분담을 함께 바꾼 개발 대조군이다. 개발 정답을 모델에 전달하지 않지만 기존 개발 사례를 본 뒤 설계했으므로 독립 시험 점수가 아니다. 필터가 질문 원문에 없으면 보류하며 기록 메모의 지시문은 모델 입력에서 제외한다. 이것만으로 의료 의도 분류나 자유로운 질문 전체의 안전성이 보장되지는 않는다.
- 보고서의 `fence_only_adapter`와 `fence_adapter_and_host_fact_rendering`은 같은 원본 출력을 재처리한 사후 진단이다. 모델 실행 점수를 대체하지 않는다. 후자는 모델이 고른 ID/status를 바꾸지 않으므로 틀린 날짜·항목 선택을 해결하지 못한다.
- `filter_boundary_trim`은 추출 필드의 양끝 공백만 정리한 사후 진단이다. `colon_width_normalization`은 OCR의 전각 콜론 하나만 ASCII 콜론으로 맞춘 보조 지표다. 기존 기본 점수는 변경하지 않는다. 기본 CER과 기존 `critical_tokens_exact`는 대소문자를 접으므로 의료 단위 판정에 충분하지 않다. `critical_tokens_case_sensitive`는 mL/ML 등을 구분하는 별도 숫자·라틴 단위 multiset 진단이며 행 연결이나 모든 의료 단위를 검증하는 지표는 아니다.
- CER은 NFC·소문자·공백을 정규화한다. 문장부호·소수점·단위를 보존하므로 표준 FLEURS 리더보드 수치와 같은 지표라고 주장하지 않는다. `critical_tokens_exact`는 숫자/라틴 단위의 multiset 일치이며 항목 간 연결 정확도나 모든 부정을 검증하는 지표가 아니다. 전문 일치/CER와 함께 읽는다.
- ASR은 검증 분할에서 언어별 첫 50건을 고정 선택한다. 최대 길이 29.52초, mono 16kHz이며 Whisper에 30초를 초과하는 입력이 들어오면 조용히 자르지 않고 실패 처리한다. 실제 진료 대화·소음·화자 분리·약명 성능은 미측정이다. 중국어 발화 50건은 Mandarin/간체 전사이며 번체·방언별 성능은 주장하지 않는다.
- ASR 모델 모두 출처에 명시된 언어를 힌트로 받으며 자동 언어 감지 시험이 아니다. Qwen은 native processor의 `transcription_only` 출력을 채점하고 반복 정리 전 decoder 문자열도 보존한다. 이 공개 validation 자료가 모델 사전학습에 포함됐는지는 확인하지 못했다.
- 의료 검수, 모바일 변환·추론, 학습·증류는 이 PC 기준선의 완료 조건이 아니다. 승인 근거 없는 의료 답변을 앱에 연결하지 않는다.

공개 음성 출처는 Google의 [FLEURS](https://huggingface.co/datasets/google/fleurs)이며 자료 카드의 라이선스 표기는 CC-BY-4.0이다(확인 2026-09-10). 원래 전사와 발화 ID를 유지하고, 선택한 음성을 로컬 PCM16 WAV로 저장했다. 가중치 파일의 HF 카드 라이선스는 `assets.lock.json`에 관측값으로 보존했다. 특히 Whisper의 HF 카드 `apache-2.0` 표기와 upstream Whisper 저장소의 MIT 표기는 구분하며, 배포할 실제 변환물의 권리 확인을 이 메타데이터 검사로 대체하지 않는다.

### 실행 중 확인한 환경 보완

- 초기 Qwen grammar 실행의 EOS가 모델과 달랐다. 형식 강제기도 모델의 generation EOS를 사용하도록 수정했다. 채택 비교는 `grammar-eos-fixed40` 실행을 사용하고 초기 grammar 원본은 이력으로 남긴다.
- Paddle 3.3.1은 import 시 `~/.cache/paddle/dataset` 생성을 시도해 제한된 실행 환경에서 실패했다. 전용 venv의 해당 한 줄이 `PADDLE_DATA_HOME`을 읽도록 패치했다. 커널·가중치는 변경하지 않았으며 before/after SHA-256은 [runtime-patches.json](runtime-patches.json)에 남긴다. 모델 실패 점수와 환경 실패를 구분한다.
- 중국어 ASR의 표기 차이 진단에는 [공식 OpenCC](https://github.com/BYVoid/OpenCC) 1.4.2의 `t2s` 변환을 예측 문자열에 적용한다. 간체/번체 변환과 번역은 다르다. 기본 CER·원본 출력은 보존하며 이 보조 점수를 모델의 새 전사 결과로 표시하지 않는다.
- 후기 실행은 `source/`에 실행 당시 스크립트도 복사한다. 초기 실행은 코드 해시·프롬프트·모델·입력·출력으로 추적하며, 당시 전체 코드 스냅샷의 보관 여부는 보고서에 별도로 표시한다.
- OCR의 CPU 기준선 뒤 `--ocr-mkldnn`으로 oneDNN(MKLDNN) 최적화를 별도 비교한다. 같은 한국어/영어 80장을 사용하고 원문 출력·숫자/단위·속도를 함께 대조한다. 모델을 학습하거나 가중치를 바꾸는 실행이 아니다.
