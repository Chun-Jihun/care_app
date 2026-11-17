# 모바일 AI와 모델 설치

[문서 홈](README.md) · [앱에서 기록 조회와 AI 사용](mobile_current_guide.md#기록-조회와-ai) · [모바일 개발 안내](../mobile/README.md)

기기 모델은 Android arm64에서 기록 조회, 사진의 글자 읽기, 음성 입력과 진료 전사를 돕습니다. 기본 기록·조회와 진료 녹음은 모델 설치 없이 사용할 수 있습니다. 의료 질문 답변과 임상 규칙은 제품의 승인 기준을 따릅니다. [의료 안전 요구사항](caregiving_notebook_requirements.md#ai와-의료-안전)

## 설치와 사용

1. [Android 앱을 빌드해 실행](../mobile/README.md#실행)합니다.
2. 개발용 `data/mobile-ai/care-ai-dev-2026-09-11-v2.careai`를 준비해 기기로 옮깁니다. 모델 파일은 약 1.72GB이며 저장소의 앱 빌드와 별도로 준비합니다. 설치 전 원본 파일, 가져오기와 설치 복사본을 위한 여유 공간을 확보합니다. [모델 준비와 패키징](#개발-재현)
3. 앱의 **설정 → 기기 AI → 모델 파일 선택**에서 모델 파일을 고릅니다. 지정한 manifest와 파일별 SHA-256 검증을 마친 모델만 활성화합니다.
4. 설치 후 **간병 도우미**, **글자 읽기**, 음성 입력과 진료의 **전사하고 검토하기**를 사용합니다. [화면별 사용 순서](mobile_current_guide.md#기록-조회와-ai)

> [!NOTE]
> 사진과 음성 인식은 오류가 생길 수 있습니다. **원본 대조 → 수정 → 입력에 반영 → 저장**을 거쳐 확정 기록으로 남깁니다.

## 실행 구조와 경계

| 구성 | 맡는 일 |
| --- | --- |
| `domain/ai.dart` | 런타임 계약과 결과·출처·실패 코드 |
| `application/services/ai_service.dart` | 선택 수첩, 세션, 보관 정책, 조회 범위와 취소 |
| `application/ai_query_policy.dart` | 긴급·의료 요청을 먼저 처리하고 조회 JSON을 검증 |
| `infrastructure/ai/` | 모델 설치·검증, llama.cpp, ONNX OCR와 sherpa 음성 런타임 |
| `presentation/` | 모델 설정, 원본 연결 및 사용자가 확인하는 인식 초안 |
| [`packages/care_ort/`](../mobile/packages/care_ort/) | 단일 Android ONNX Runtime을 공유하는 제한된 C API 어댑터 |

모델에는 불필요한 별칭·연락처를 마스킹한 질문을 보냅니다. 호스트는 모델이 추출한 조회 조건을 검증하고, 선택한 수첩에서 실제 기록을 찾아 ID와 버전을 연결합니다. 원본으로 돌아갈 수 있는 답변을 만들고, 기록 변경·삭제 후에는 당시 버전을 확인할 수 없는 발췌를 보류합니다.

AI는 UI 밖에서 한 번에 한 작업을 처리합니다. 잠금·수첩 전환·취소 뒤 도착한 결과는 폐기합니다. 90초 제한은 UI 응답을 끝내고 네이티브 자원은 실행이 안전하게 반환한 뒤 해제합니다. 자원 반환까지 새 작업을 기다립니다.

| 입력 또는 작업 | 제한과 검토 |
| --- | --- |
| 모델 설치 | 10분 제한. 취소하거나 검증에 실패한 임시 파일을 정리하고 이전 모델과 기본 기능을 유지합니다. |
| OCR | 최대 24MiB·1,600만 화소와 64개 검출 영역. 일반 사진 첨부에는 별도 한도가 적용됩니다. 인식 결과·메모 합계가 한도를 넘으면 반영을 중단합니다. |
| 일반 음성 입력 | 최대 30초·PCM 960KB를 메모리에서 처리합니다. 권한 거절·취소·앱 전환 시 정리합니다. |
| 진료 전사 | 암호화 녹음 원본을 최대 30초 구간으로 읽습니다. 한 기록에 들어가지 않는 결과는 시각별 초안으로 나눕니다. |

AI 본문과 녹음·사진 원문은 외부 AI 서버나 파일 로그에 보내지 않습니다. 배포 인터넷 권한의 사용 범위는 [개발 안내](../mobile/README.md#google-drive-백업-설정)에 있습니다. [안전 검증 시나리오](safety_validation.md#기기-ai와-근거)

## 저장·호환성

- 챗봇 진입 안내를 확인한 뒤 대화와 입력을 엽니다. 질문·조회 답변에는 선택한 보관 방식을 적용합니다.
- 선택 복원에서는 답변 출처를 새 수첩의 ID로 다시 연결합니다. 선택 범위에서 빠진 출처는 제외하고, 모두 빠진 답변은 원본 없는 결과로 표시하지 않습니다. 다른 수첩의 출처를 포함한 자료는 거부합니다.
- [현재 DB와 백업 형식](../mobile/README.md#저장소와-백업-형식)은 모바일 개발 안내에서 확인합니다.

## 고정한 모델과 변환

| 작업 | 적용 모델 | 모바일 형식/런타임 |
|---|---|---|
| 조회 조건 추출 | Qwen3.5-2B + `chat-2b-sft-v1` | BF16 병합 → Q4_K_M GGUF / llama_cpp_dart 0.9.0-dev.12 |
| 한글 OCR | korean PP-OCRv5 mobile + `ocr-ko-head-sft-v2` | FP32 ONNX / 검출기 + 학습 CTC head |
| 기타 언어 OCR | PP-OCRv5 mobile + `ocr-multi-head-sft-v1` | FP32 ONNX / en·ja·zh-Hans·zh-Hant |
| 음성 전사 | Whisper small + `asr-small-lora-v1` | INT8 encoder/decoder ONNX / sherpa_onnx 1.13.8 |
| 음성 구간 | Silero v6.2 | 고정 ONNX / 전사 전에 무음 차단 |

CPU 2스레드를 사용한다. OCR 변환은 Paddle 3.1.1 + paddle2onnx 2.1.0의 호환 조합이며,
음성 변환은 공식 sherpa v1.13.8 스크립트와 독립 구현 로짓 대조를 거쳤다.
변환된 OCR도 Paddle/ONNX 출력 수치 대조를 거쳤다. 이 대조는 실제 인식 정확도 보장을 뜻하지 않는다.

GGUF 원본 변환의 MTP 메타데이터 오류를 수정했다. 실제 텐서는 24개 trunk layer인데 설정이
선택적 MTP 1개를 추가로 표시했다. block_count 25→24, nextn_predict_layers 1→0으로 정정했고
텐서 영역 SHA-256이 동일함을 확인했다. 새 export 코드도 미보존 MTP를 표시하지 않도록 수정했다.
[변환 메타데이터 수정 기록](../experiments/mobile_ai_v1/chat-metadata-repair.json)

Android OCR과 음성은 sherpa가 제공하는 단일 ONNX Runtime 1.28.2를 공유한다. 별도 Flutter ONNX
플러그인이 1.23.0을 함께 포함하면서 발생했던 `.so` 충돌은 해당 중복 의존성을 제거해 해결했다.
`care_ort`는 검증한 API 14 바인딩과 단일 입력/출력 FP32 처리만 제공한다. MIT 바인딩 원천과
해시는 `ort-bindings.lock.json`에 기록했다. 모델·런타임 라이선스는 앱 설정의 라이선스 화면에서 읽을 수 있다.

## 검증과 남은 작업

| 범위 | 찾아볼 기록 |
| --- | --- |
| Android 엔진 실행과 OCR·전사 오류 | [AI 실행 검증](history/mobile_ai_validation_2026-09-11.md) · [추가 검증](history/ai_additional_validation_2026-09-11.md) |
| Android 실기기 모델 설치·음성·OCR 흐름 | [실기기 검증 기록](history/android_device_validation_2026-11-06.md) |
| 파일·원본 확인 UI의 회귀 검증 | [입력 검토 검증](history/ai_review_ux_validation_2026-09-11.md) · [실패 시나리오](safety_validation.md#기기-ai와-근거) |

자동·합성 시험은 실행 경로와 개발 품질의 자료로 사용합니다. 실기기 발열·절전·메모리, 다양한 촬영·녹음 조건과 의료 정확성은 별도 평가 대상입니다. iOS 실행은 후속 지원 범위입니다. 현재 iOS arm64 OCR에는 ONNX C API 브리지 또는 별도 런타임 연결이 필요합니다.

## 개발 재현

원천·변환물·모델 묶음 잠금 파일은 `experiments/mobile_ai_v1/`에 있다. 대용량 모델은 Git에 넣지 않는다.
`scripts/prepare_mobile_ai_sources.py`, `prepare_mobile_ai_native.py`는 고정 원천을 준비하며
`export_mobile_ai.py`는 `chat/asr/ocr-ko/ocr-multi/ocr-det`를 별도 실행한다. 출력 디렉터리는 덮어쓰지 않는다.
네이티브 준비 도구는 `native-sources.lock.json`의 크기와 SHA-256으로 기존 파일과 다운로드를 검증한다.
유효한 캐시는 재사용하고, 손상된 파일은 검증이 끝난 다운로드로 교체한다. 모델 묶음을 만들 때도 Silero 원천을 같은 기준으로 검사한다.
학습 checkpoint와 exporter 환경이 필요하다. `package_mobile_ai.py`가 고정 manifest와 `.careai`를 생성한다.
현재 선택 export 폴더는 chat, asr, ocr-ko-v9, ocr-multi-v1, ocr-det다.

일반 Android 빌드는 `flutter build apk --release --target-platform=android-arm64 --no-pub`다.
공식 AAR의 arm64 라이브러리를 사용하며 개발용 x86 AAR 경로를 pubspec에 고정하지 않는다.

에뮬레이터 시험만 할 때는 llama.cpp 고정 revision
`afeebe103bd99cda8f5dfaefcabadf890db7fda7`을 NDK 28.2.13676358 / CMake 3.22.1로 빌드한다.
`ANDROID_ABI=x86_64`, `ANDROID_PLATFORM=android-24`, `GGML_NATIVE=OFF`, `GGML_OPENMP=OFF`,
`GGML_BACKEND_DL=OFF`, `GGML_SSE42/AVX/AVX2/FMA/F16C=ON`, `Release`, target `llama`, parallel 2를 썼다.
시험 AVD의 CPU가 위 명령을 지원하는지 먼저 확인해야 한다. 배포 arm64 라이브러리는 수정하지 않는다.
`package_mobile_ai_native.py`로 AAR을 만든 후 시험 빌드에만 아래 훅을 임시 추가한다.

```yaml
hooks:
  user_defines:
    llama_cpp_dart:
      android_aar: ../data/mobile-ai/llama-cpp-dart-with-emulator.aar
    sqlite3:
      source: sqlcipher
```

`flutter build apk --debug --target=tool/native_ai_smoke.dart --target-platform=android-x64 --no-pub`
후 `scripts.run_mobile_ai_smoke install/start/report`를 모듈로 실행한다. 도구는
`emulator-5560`의 `care_ai_validation` AVD만 허용한다. 일반 앱 빌드 전 임시 AAR 훅을 제거한다.
시험 데이터는 별도 고정 fixture이며 개인정보를 읽거나 실제 수첩을 초기화하지 않는다.
