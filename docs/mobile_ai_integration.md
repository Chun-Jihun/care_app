# 모바일 AI 연결 — 2026-09-11

Android arm64 앱에 학습한 모델의 로컬 실행을 연결했다. 기록 조회, 사진 글자 인식,
30초 이내 음성 입력을 지원한다. 의료 답변·처방·약물 상호작용 판단·운동 처방은
활성화하지 않았다. 모델 연결 완료와 인식 품질·의료 출시 승인은 별개다.

## 설치와 사용

1. `mobile/build/app/outputs/flutter-apk/app-release.apk`를 Android arm64 기기에 설치한다.
   기존 앱과 동일한 개발 서명이며 앱을 삭제하거나 데이터를 초기화할 필요가 없다.
2. `data/mobile-ai/care-ai-dev-2026-09-11-v2.careai`를 휴대전화로 옮긴다.
   약 1.72 GB다. 원본 파일·파일 선택기 캐시·설치 복사본을 고려해 약 6 GB의
   여유 공간을 확보한다. 모델은 앱 APK와 별도이며 환자 기록을 포함하지 않는다.
3. 앱 잠금 해제 → 설정 → 기기 AI → 모델 파일 선택에서 위 파일을 선택한다.
   앱에 포함한 manifest와 파일별 SHA-256이 일치해야 설치된다. 설치 후 오프라인으로 사용한다.
4. 간병 도우미에서 `2026-09-11 09:30에 기록한 혈압을 보여줘`처럼 날짜·시각·항목을
   지정한다. 선택한 수첩의 일치 기록을 원문으로 보여 준다. 누락·모호함·모델 오류는
   재확인 안내로 처리한다. 자유로운 일반 상담과 상대 날짜 해석은 아직 지원하지 않는다.
5. 기록 상세의 사진 옆 글자 읽기 버튼으로 OCR 초안을 연다. 원본과 대조·수정하고
   입력란에 반영한 뒤 기록 저장을 눌러야 확정된다. 기존 기록의 메모에 추가하는 방식이다.
6. 기록 편집/대화 입력의 마이크 버튼으로 녹음한다. 최초 마이크 권한을 허용한 후
   녹음을 마치면 전사 초안을 수정·반영할 수 있다. 음성 파일 가져오기는 이번 범위에 없다.

`native-ai-smoke.apk`는 공개 자료용 개발 시험 진입점이다. 사용자용 APK가 아니다.
Android 32비트·데스크톱·iOS에서는 이번 AI 실행을 활성화하지 않는다. 기본 기록 기능은 유지된다.

## 실행 구조와 경계

| 계층 | 역할 |
|---|---|
| `domain/ai.dart` | 런타임 계약, 결과·출처·실패 코드. Flutter/native 구현을 참조하지 않음 |
| `application/services/ai_service.dart` | 선택 수첩·세션·질문 보관·작업 취소·조회 범위 |
| `application/ai_query_policy.dart` | 의료/명시적 긴급 요청 선행 처리, 조회 JSON 엄격 검증 |
| `infrastructure/ai/` | 모델 설치·해시, llama.cpp, ONNX OCR, sherpa 음성, 메모리 녹음 |
| `presentation/ai_*.dart` | 모델 설정, 확인 가능한 초안, 원본 기록을 연결한 답변 |
| `packages/care_ort/` | Android 음성 런타임과 공유하는 최소 FP32 C API 어댑터 |

챗봇에는 질문만 보내며 선택 수첩의 별칭·연락처를 마스킹한다. 전체 기록 DB나 다른 수첩을
모델에 제공하지 않는다. 모델 출력은 날짜·시각·항목 필터로만 파싱한다. 호스트가 실제 저장된
기록을 조회하고 출처 ID·버전을 붙인다. 모델이 만든 설명·수치·출처를 답변으로 표시하지 않는다.
출처 기록이 수정되면 이전 답변 내용을 그대로 재표시하지 않고 수정 안내와 현재 원본 링크를 제공한다.

의료 안내는 고정된 보류 문구다. 긴급 표현 규칙은 예방적 연락 안내이며 임상 분류기의 정확도를
주장하지 않는다. 승인 KB/RAG·약물 규칙·임상 검수 게이트는 기존 차단 상태를 유지한다.

AI 요청은 UI 실행 공간 밖에서 한 번에 하나만 처리한다. 잠금·수첩 전환·취소 뒤 늦은 결과는 폐기한다.
취소/90초 제한은 UI 응답을 종료하며, 이미 실행 중인 네이티브 연산은 안전하게 반환한 뒤 자원을
해제한다. 임의로 실행 공간을 죽이지 않으므로 자원 해제 전에는 새 작업을 차단한다.
설치는 10분 제한이다. 긴 녹음은 최대 30초, OCR은 24 MB·1,600만 화소·최대 64개 검출 영역으로 제한한다.
OCR의 세로쓰기·기울어진 표·복잡한 서식은 지원 검증 대상에 포함되지 않았다.

음성 PCM은 최대 960 KB의 메모리 버퍼로 수집하며 녹음 파일을 생성하지 않는다. 권한 거절·취소·
백그라운드 전환 시 녹음을 정리한다. OCR은 기존 암호화 사진을 메모리로 읽는다. 운영 앱은 질문·
인식 원문·네이티브 진단을 파일 로그나 외부 서버에 기록하지 않는다. 원격 AI API·API 키·클라우드
동기화를 추가하지 않았다. release APK에는 INTERNET 권한이 없다.

모델은 앱 전용 폴더에 설치한다. 불완전한 설치는 활성화하지 않으며 잔여 설치 폴더를 정리한다.
손상된 설치는 검증된 파일로 재설치할 수 있다. 가져오기가 끝나면 파일 선택기의 모델 캐시를 정리한다.

## 저장·호환성

챗봇 새 진입 시 AI 이용 안내 팝업을 표시하며, 확인 후에만 대화와 입력란을 표시한다. 취소는 이전 화면으로 돌아간다. 같은 대화창의 하위 화면에서 복귀할 때는 반복하지 않는다. [안내 내용과 검증](./chat_ai_notice.md)을 참고한다.

2026-09-11 입력 검토 UI 보완:

- 잠금 화면과 설정의 언어 항목은 지원 준비 중으로 비활성화했다. 기존 선택과 다섯 번역 자산은 유지한다.
- 답변 옆 **근거 보기**에서 참고 기록의 항목·시각·답변에 사용한 버전·내용을 확인하고 원본 기록으로 이동한다. 답변과 근거 화면은 같은 `AiRecordSource`를 사용해 수정·삭제 확인이 어긋나지 않게 한다. 잠금 시 화면이 제거되고 다른 수첩에서는 내용이 숨겨진다.
- 내 기록과 의료 문서 영역을 분리한다. 현재 승인 KB가 없으므로 의료 문서는 미연결 안내만 제공한다. 의료 문서의 페이지·절·발췌문 표시와 주장별 인용은 승인 자료 및 의료 답변 연결 단계의 남은 작업이다.
- OCR 화면에서 원본 사진 확대, 수정 전 인식 결과 펼치기, 본문 수정, 선택 메모 입력을 지원한다. 본문·메모·구분 문구 합계가 20,000자를 넘거나 본문이 비면 반영을 막는다. 수정 전 OCR 결과는 비교용 메모리에만 유지하며, 확인한 본문과 메모만 기존 기록 편집기에 전달한다. **반영 → 편집기에서 저장**을 거쳐야 확정 기록이 바뀐다. 편집기에서는 기존 메모를 포함한 저장 길이 제한도 적용한다.

사전 실패 시나리오는 [AI 검토 UI 시험 계획](./ai_review_ux_safety_plan.md), 결과는 [검증 기록](./ai_review_ux_validation_2026-09-11.md)을 참고한다. 이 보완은 DB·백업·모델·프롬프트를 변경하지 않는다.

SQLite 스키마 v4는 암호화 `chat_message`에 구조화된 `reply`를 추가한다. 답변은 질문과 같은
보관기간·잠금 시 삭제·선택 삭제·전체 삭제 정책을 따른다. 현재 입력 중인 대화는 별도 초안으로 저장하지 않는다.

선택 백업은 format 3 / document_version 2다. 기존 document_version 1 및 format 2/schema 3을 읽는다.
복원 시 답변의 출처 ID를 새 수첩의 기록 ID로 바꾸며, 선택 범위에서 빠진 출처는 제거한다.
출처가 모두 빠진 답변은 원본 없는 조회 결과로 표시하지 않는다. 다른 수첩의 출처를 넣은 자료는 거부한다.
이전 앱은 새 백업을 읽지 못할 수 있으므로 최신 앱으로 복원한다.

## 고정한 모델·변환

| 작업 | 적용 모델 | 모바일 형식/런타임 |
|---|---|---|
| 조회 조건 추출 | Qwen3.5-2B + `chat-2b-sft-v1` | BF16 병합 → Q4_K_M GGUF / llama_cpp_dart 0.9.0-dev.12 |
| 한글 OCR | korean PP-OCRv5 mobile + `ocr-ko-head-sft-v2` | FP32 ONNX / 검출기 + 학습 CTC head |
| 기타 언어 OCR | PP-OCRv5 mobile + `ocr-multi-head-sft-v1` | FP32 ONNX / en·ja·zh-Hans·zh-Hant |
| 음성 전사 | Whisper small + `asr-small-lora-v1` | INT8 encoder/decoder ONNX / sherpa_onnx 1.13.8 |
| 음성 구간 | Silero v6.2 | 고정 ONNX / 전사 전에 무음 차단 |

CPU 2스레드를 사용한다. Windows의 GPU 프로그램이나 기존 학습 환경을 변경하지 않았다.
변환 환경은 별도로 구성했다. OCR 변환은 Paddle 3.1.1 + paddle2onnx 2.1.0의 호환 조합이며,
음성 변환은 공식 sherpa v1.13.8 스크립트와 독립 구현 로짓 대조를 거쳤다.
변환된 OCR도 Paddle/ONNX 출력 수치 대조를 거쳤다. 이 대조는 실제 인식 정확도 보장을 뜻하지 않는다.

GGUF 원본 변환의 MTP 메타데이터 오류를 수정했다. 실제 텐서는 24개 trunk layer인데 설정이
선택적 MTP 1개를 추가로 표시했다. block_count 25→24, nextn_predict_layers 1→0으로 정정했고
텐서 영역 SHA-256이 동일함을 확인했다. 새 export 코드도 미보존 MTP를 표시하지 않도록 수정했다.
근거: `experiments/mobile_ai_v1/chat-metadata-repair.json`.

Android OCR과 음성은 sherpa가 제공하는 단일 ONNX Runtime 1.28.2를 공유한다. 별도 Flutter ONNX
플러그인이 1.23.0을 함께 포함하면서 발생했던 `.so` 충돌은 해당 중복 의존성을 제거해 해결했다.
`care_ort`는 검증한 API 14 바인딩과 단일 입력/출력 FP32 처리만 제공한다. MIT 바인딩 원천과
해시는 `ort-bindings.lock.json`에 기록했다. 모델·런타임 라이선스는 앱 설정의 라이선스 화면에서 읽을 수 있다.

## 검증과 남은 작업

정량 결과와 실패 사례는 [Android AI 실행 검증](./mobile_ai_validation_2026-09-11.md)에 기록한다.
`experiments/mobile_ai_v1/android-native-smoke.json`은 실제 Android 엔진 출력이다.
OCR/음성의 `nonempty_native_output` 통과는 결과 반환 여부이며 정답률 통과가 아니다.

현재 실제 휴대전화는 연결돼 있지 않아 이번 AI 모델의 폰 실행·마이크·실제 사진·발열·절전·메모리
검증은 남아 있다. 이전 기본 앱 실기기 검증이 이번 AI 검증을 대신하지 않는다.

iOS는 Mac이 없어 컴파일/기기 검증을 하지 못했다. 추가로 현재 sherpa iOS arm64 framework의
심볼 표에는 `OrtGetApiBase`가 없다. 프로세스에서 이를 찾는 방식으로는 OCR을 실행할 수 없으므로
현재 iOS AI를 비활성화했다. iOS용 OCR C API 브리지 또는 별도 런타임 연결, 서명·SwiftPM 빌드,
메모리·파일 보호·마이크 시험을 완료한 후 활성화해야 한다. UI·마이크 사용 목적 문구는 5개 언어로 준비했다.

기록 조회 모델의 영어·일본어 누락, OCR의 숫자·부정어, 음성의 단어·수치 오류는 추가 품질 개선 대상이다.
의료 문서 검수·RAG·약물 규칙·의료 회귀평가를 마치기 전에는 일반 의료 챗봇으로 확대하지 않는다.

## 개발 재현

원천·변환물·모델 묶음 잠금 파일은 `experiments/mobile_ai_v1/`에 있다. 대용량 모델은 Git에 넣지 않는다.
`scripts/prepare_mobile_ai_sources.py`, `prepare_mobile_ai_native.py`는 고정 원천을 준비하며
`export_mobile_ai.py`는 `chat/asr/ocr-ko/ocr-multi/ocr-det`를 별도 실행한다. 출력 디렉터리는 덮어쓰지 않는다.
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
