# 모바일 근거 자료 패키지

## 현재 기본 구성: 42.78MiB

사용자의 추가 축소 요청에 따라 기본 구성은 `data/knowledge-preview/mobile-core-v2-small/`로 변경했다. 전체 DB·개별 manifest·구성 manifest를 포함한 실측은 **44,860,139바이트(42.78MiB)**이며, 이전 네 패키지 DB 합계 대비 **96.89% 감소**했다. 앱 실행 파일·AI 모델·개인 간병기록은 이 수치에 포함하지 않는다.

| 기본 자료 | 용량 | 포함 범위 |
|---|---:|---|
| DUR | 27.99MiB | 수집한 9개 API의 857,362건, 모든 필드·조건·병용 관계와 API 원문 위치 보존 |
| 약 식별 목록 | 4.98MiB | 허가 기본정보 42,992건의 품목코드·한/영 이름·업체명·성분명·전문/일반·제품 구분·허가/취소 정보 |
| e약은요 | 2.09MiB | 4,775건의 효능·사용법·주의·상호작용·이상반응·보관 등 원문, 제품 사진 URL·사업자번호 제외 |
| 보호자용 문서 | 7.71MiB | 문서 13종: PDF 24쪽, HTML 6개, HTML 그림 6개 |

기본 구성에서 **659쪽 Nursing Assistant 교재, 전체 허가 상세 42,992건, 성분별 함량 126,871건, 식별 목록의 사업자번호·청구코드 등 행정 필드**를 제외했다. PC에 수집한 원본과 이전 보존용 패키지는 유지하며 휴대전화용 구성에는 포함하지 않는다. e약은요에 없는 약의 상세 효능·용법·허가 주의사항까지 제공하는 기본 구성은 아니다. 지원 범위는 manifest 및 개발용 조회 화면에 명시하며, 미지원/조회 없음은 답변 보류 대상이고 안전을 의미하지 않는다. 어떤 문서도 임상 승인 상태로 변경하지 않았다.

v2 약물 형식은 원본의 **필드 값 자체**를 중복 제거하고, 최대 128개 값과 최대 512개 행을 각각 묶어 압축한다. 품목별 양방향 행 목록은 정렬된 ID 차이를 가변 길이 정수로 저장해 행마다 발생하던 DB/해시 색인 비용을 줄였다. 재구성 시 원문 필드명과 값·자료형·null·빈 문자열을 그대로 복원한다. 동일 성분이라는 이유로 다른 제품이나 조건을 합치지 않는다. 모든 레코드와 출처 위치를 다시 복원한 스트림 해시를 입력 스트림과 비교한다. Dart는 조회한 묶음만 해제하며 값 캐시는 압축 해제 바이트 기준 4MiB를 목표로 제한한다(단일 블록 상한 16MiB는 별도).

`scripts/mobile_core_policy.py`가 포함 문서와 필드의 명시적 목록이다. 알려지지 않은 허가 기본정보 필드가 생기면 자동 삭제하지 않고 변환을 실패시킨다. 전체 구성은 **50MiB** 제한 및 원문 검증을 통과해야 완료 manifest를 마지막에 만든다. v1 보존용 패키지 읽기는 유지한다. v2는 `packed_layout=field_values_delta_index_v1`을 확인하며 지원하지 않는 중간 형식을 열지 않는다.

```powershell
# 루트에서 실행. 출력은 존재하지 않는 새 경로여야 한다.
python scripts/build_mobile_core_pack.py --permits data/mfds/permits/20260918T053000Z --dur data/mfds/dur/20260918T053000Z --easy-drug data/easy-drug/raw/20260901T061358Z --documents data/knowledge-preview/documents-v1 --output data/knowledge-preview/mobile-core-v2-small
python -m scripts.build_knowledge_test_fixture --packed

# mobile 디렉터리에서 PC 검증
dart run tool/knowledge_pack_probe.dart ../data/knowledge-preview/mobile-core-v2-small/dur ../data/knowledge-preview/mobile-core-v2-small/permits ../data/knowledge-preview/mobile-core-v2-small/easy-drug ../data/knowledge-preview/mobile-core-v2-small/documents
```

미리보기에서는 구성 루트 대신 `.../mobile-core-v2-small/dur` 또는 `.../documents`처럼 **개별 패키지 폴더**를 연다. 약물 905,129건의 포함 내용 전체 복원 검증을 통과했다. 선택 문서의 30개 본문/페이지와 HTML 그림 6개는 이전 보존용 패키지와 전부 바이트가 같다. 실제 네 패키지를 Dart에서 열어 조회와 근거 연결을 확인했다. 전체 설치 파일 및 모델까지 작아졌다는 의미나 임상·실기기 검증 완료를 뜻하지 않는다.

축소 작업의 최종 자동 시험: Python 74개 중 72개 통과(기존 선택 의존성 시험 2개 제외), Flutter 관련 시험 24개 통과, 정적 분석 문제 없음. 생성된 패키지 파일 9개 모두 Git 제외 규칙을 확인했다.

## 필수 구성 축소 작업의 사전 실패 시나리오

- 행정정보·대형 교재를 제외한 뒤 기존의 전체 지원 범위로 오해함: 기본 자료의 포함/제외 범위와 처방약 상세 미포함을 명시한다. 범위 밖 질문은 근거 없음으로 처리하며 안전 판정을 만들지 않는다.
- 압축률을 높이면서 DUR 병용 상대·조건·예외를 잃음: DUR 전체 레코드를 값 단위 중복 제거하고 묶음 압축하되, 원본 모든 필드와 API 페이지/행을 전체 복원해 동일 스트림 해시로 검증한다.
- 조회 인덱스에서 병용 상대 방향 또는 반복 관계가 누락됨: 좌/우 어느 품목으로도 동일한 원문 행을 찾고 자기 자신 관계는 한 번만 반환하는 시험을 추가한다.
- 교재 제외가 간병인용 자료나 그림을 일부 잘라냄: 문서 단위로 선별하고 선정한 13종의 모든 페이지·본문·그림을 바이트 일치 복사한다. 제외 교재를 참조하는 인용은 다른 문서로 대체하지 않는다.
- 묶음 압축을 위해 전부 메모리에 펼침: 조회한 묶음만 해제하고 기존 블록 상한을 유지한다. Python에서 만든 합성 v2 패키지를 Dart에서 복원하는 호환성 시험을 수행한다.
- 완료 전에 불완전한 구성 배포: 총량 제한·구성 파일 해시·전체 복원 검증 후에만 최종 구성 manifest를 만든다. PC 원본과 기존 패키지는 덮어쓰지 않는다.

## 구현 전 실패 시나리오

- 압축·중복 제거로 수치, 부정문, 조건 또는 약물 관계가 바뀜: 모든 약물 레코드를 복원해 입력 원문과 비교한다. 조회 없음은 안전으로 해석하지 않는다.
- 원문 문서를 AI 요약으로 대체하거나 도표를 잃음: 본문을 추출하고 원래 PDF의 페이지 보기를 함께 보존한다. 변환은 임상 검수를 대신하지 않는다.
- 오래된 답변의 근거가 새 문서로 바뀜: 패키지 해시·출처·위치·본문 해시로 고정한 인용만 연다.
- 잘린 패키지, 변조 DB, 압축 폭탄, 경로 탈출: 크기 상한과 해시를 검사하고, 오프라인 읽기 전용 접근 및 허용된 스키마만 사용한다.
- 미검수 자료가 앱의 의료 답변에 사용됨: 개발용 패키지와 미리보기만 지원하고 의료 생성용 접근을 차단한다. 자동 승인 옵션은 제공하지 않는다.
- 전체 자료를 메모리에 올리거나 원문을 두 번 저장함: 콘텐츠를 중복 제거한 압축 블록으로 저장하고 조회한 레코드·페이지에 필요한 블록만 해제한다.
- 변환 실패가 이전 결과를 덮어씀: 새 출력 경로에서 만든 뒤 완료 manifest를 마지막에 작성하고 이전 스냅샷은 보존한다.

실기기 실행 검증은 사용자의 기존 요청대로 배포 준비 직전으로 둔다. 이번 작업은 PC 변환 검증, Flutter 단위·위젯 시험과 개발용 오프라인 열람까지 수행한다.

## 구현과 사용

`care-knowledge-preview-v1`은 SQLite 안에 콘텐츠 해시로 중복 제거한 zlib 블록을 저장한다. 원본 JSON 필드, 빈 문자열·null, 제품별 변형, DUR 병용 방향과 조건을 보존한다. 모든 약물 레코드는 작성 직후 저장된 블록에서 복원해 입력과 대조한다. 검색·조회 인덱스는 압축을 풀지 않고 접근하며 본문은 해당 레코드나 페이지를 읽을 때만 해제한다. HTML/스크립트를 실행하거나 API·원문 URL에 접속하지 않는다.

Python 변환기와 Dart 읽기 전용 구현은 동일한 형식을 사용한다. 해시 검사·조회·압축 해제는 UI isolate 밖에서 처리한다. 블록과 복원 문자열은 16MiB 상한을 적용하며, 파일 크기·해시·DB 스키마·내부 메타데이터·블록 무결성을 검사한다. 해시는 손상과 버전 혼동을 탐지하는 값이며 **발행자 서명이나 임상 승인을 대신하지 않는다**. 배포용 승인 목록·서명 검증·업데이트 설치기는 이번 개발용 도구의 범위에 포함되지 않는다.

`KnowledgeCitation`은 패키지 SHA-256, 출처 ID, 물리적 페이지 번호, 본문 SHA-256, 인용문 및 UTF-16 시작 위치를 고정한다. 일치하지 않는 버전·구절은 표시하지 않는다. 인용 카드, 문맥을 포함한 본문, 출처 정보, 원문 링크, 앞뒤 페이지, 확대 가능한 페이지 이미지를 오프라인에서 열람한다. 발행일과 검수일이 미확인인 자료에는 임의의 날짜를 넣지 않는다.

PDF는 pypdf로 텍스트를 추출하고 Poppler로 144DPI 페이지 이미지를 렌더링한다. WebP 인코딩은 무손실이며, 렌더링 이미지와 디코딩 이미지의 모든 픽셀을 대조한다. **PDF 파일 자체의 무손실 압축은 아니다.** 벡터·미세 글씨·외부 동영상은 원본 PDF 수준으로 보존되지 않으며 텍스트 읽기 순서·표의 의미는 추가 검수가 필요하다. 원본 PDF는 PC에 그대로 보존한다. HTML은 저장된 main 본문과 로컬 그림을 추출하며 외부/누락 그림이나 경로 이탈은 실패 처리한다.

FTS5는 원문 언어의 기본 키워드 검색이다. 한국어 질문으로 영어 문서를 찾는 임상 검색기나 의미 검색 성능을 확보했다는 뜻은 아니다. `LocalAiRuntime` 및 운영 앱에는 연결하지 않으며, 별도 개발용 진입점에서만 열람한다. 미검수 자료는 `runtime_rag_eligible=false`, `mobile_bundle=false`, `do_not_train=true`를 유지한다.

## 재현 명령

프로젝트 루트에서 실행한다. 문서 변환에만 `scripts/requirements-knowledge.txt`와 Poppler가 필요하며 의약품 변환은 Python 표준 라이브러리를 사용한다. 출력 폴더는 **존재하지 않는 새 경로**여야 한다.

```powershell
python scripts/build_drug_knowledge_pack.py --snapshot data/mfds/permits/20260918T053000Z --output data/knowledge-preview/permits-v1
python scripts/build_drug_knowledge_pack.py --snapshot data/mfds/dur/20260918T053000Z --output data/knowledge-preview/dur-v1
python scripts/build_easy_drug_knowledge_pack.py --snapshot data/easy-drug/raw/20260901T061358Z --output data/knowledge-preview/easy-drug-v1
python scripts/build_document_knowledge_pack.py --output data/knowledge-preview/documents-v1 --pdftoppm <pdftoppm.exe 경로>
```

`mobile`에서 개발용 진입점을 실행한다. 지정 경로는 **실행 기기에서 접근 가능한 폴더**이며 `manifest.json`과 `knowledge.sqlite3`가 함께 있어야 한다. PC의 `E:` 경로가 휴대전화에서 그대로 동작하지 않는다. 공개 앱의 설정에는 이 도구를 노출하지 않고 release 모드 실행도 차단한다.

```powershell
flutter run -t tool/knowledge_preview.dart --dart-define=CARE_KNOWLEDGE_PREVIEW_PATH=<실행 기기의 패키지 폴더>
dart run tool/knowledge_pack_probe.dart ../data/knowledge-preview/permits-v1 ../data/knowledge-preview/dur-v1 ../data/knowledge-preview/easy-drug-v1 ../data/knowledge-preview/documents-v1
flutter test --no-pub test/knowledge_package_test.dart test/knowledge_document_ui_test.dart test/ai_evidence_ui_test.dart
```

합성 Python↔Dart 호환성 fixture는 루트에서 `python -m scripts.build_knowledge_test_fixture`로 재생성한다. 실제 자료, 생성 DB와 이미지 QA 파일은 기존 `/data/*` ignore 규칙에 따라 Git에 포함하지 않는다. 인증키와 `.env`는 읽거나 패키지에 넣지 않는다.

## 이전 v1 보존용 패키지의 변환 결과

아래 용량은 MiB(1,048,576바이트)이며 각 패키지 DB 기준이다. 원본 API 응답과 기존 PC용 인덱스를 함께 합산한 수치를 비교 기준으로 부풀리지 않았다.

| 자료 | 기존 비교 대상 | 경량 패키지 | 내용 보존 검사 |
|---|---:|---:|---|
| 의약품 허가정보 | SQLite 2,396.1MiB | 693.4MiB | 212,855건 전체 복원 일치 |
| DUR 품목정보 | SQLite 1,771.4MiB | 592.8MiB | 857,362건 전체 복원 일치 |
| e약은요 | 원본 항목 JSON 11.9MiB | 9.4MiB | 4,775건 전체 복원 일치 |
| 문서 14종 | PDF·HTML 172.6MiB | 78.8MiB | PDF 683쪽 + HTML 6개, 그림 6개 |

이전 합계는 약 **1.34GiB**이다. 이 구성은 PC 보존용으로 유지하고 휴대전화 기본 구성은 위의 42.78MiB 축소본으로 대체한다. DUR 관계를 임의로 생략하거나 조회 결과 없음으로 안전을 선언하지 않는다.

실제 생성 패키지를 Dart에서 열어 27개 출처의 대표 레코드/문서 첫·끝 페이지를 확인했고 문서 검색 결과의 원문 위치도 검증했다. PDF 페이지의 자동 픽셀 대조 외에 도표·그림·본문을 포함한 4개 페이지를 시각 확인했다. 이는 전체 의료 내용 검수 또는 휴대전화 성능 검증을 의미하지 않는다.

검증 결과: Python 관련 시험 70개 중 68개 통과, 선택 의존성 `opencc`·`lmformatenforcer` 부재로 기존 시험 2개 제외. Flutter 패키지·인용 UI·기존 AI 정책/서비스/근거 회귀시험 21개 통과, `flutter analyze --no-pub` 문제 없음. 약물 원문 1,074,992건 전체 대조는 별도의 실제 데이터 변환 과정에서 수행했다.
