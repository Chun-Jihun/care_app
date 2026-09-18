# Git 업로드 범위와 로컬 환경 설정

## 변경 전 정의한 실패 검사

| 실패 | 확인 방법 |
|---|---|
| 모델·백업·서명 키가 다른 폴더로 복사돼 커밋 대상이 됨 | `git check-ignore --no-index`로 루트와 중첩 경로의 대표 파일을 검사 |
| 이미 추적 중인 비밀 파일이 ignore 규칙 뒤에 숨음 | `git ls-files -ci --exclude-standard`와 로컬 Git 이력의 파일명·내용 검사 |
| 번역·모델 manifest·라이선스·합성 호환성 자료가 함께 제외됨 | 필요한 소스/메타데이터/fixture가 ignore되지 않는지 역방향 검사 |
| 실제 키가 환경 예시 또는 검사 출력에 복사됨 | 예시는 빈 키만 사용하고 기존 `.env` 값은 수정·출력하지 않음 |
| 예시 변수가 실행 코드와 맞지 않음 | 현재 downloader의 dotenv parser와 설정 검증을 네트워크 없이 실행 |

## 올릴 파일과 제외할 파일

Git에는 앱 소스, 테스트, 문서, 번역 카탈로그, 패키지 잠금 파일, 모델의 해시·출처 manifest, 라이선스를 보관한다. `experiments/`의 검토된 합성/공개 자료 평가 요약과 재현용 메타데이터도 보관한다. `*.json`, `*.jsonl`, `*.lock`, `experiments/` 전체를 제외하지 않는다.

모델 본체·학습 체크포인트·변환 결과, APK/AAB/IPA 및 네이티브 빌드 결과, 실제 수첩 DB·백업, 서명 키, `.env`와 로컬 설정은 제외한다. 다운로드·기기 캡처·로컬 실행 결과는 `/data/`, 도구와 캐시는 `/.tools/`에 둔다. 환자 사진이나 녹음을 다른 소스 폴더에 보관하지 않는다. 앱 아이콘 등 필요한 자산도 있으므로 모든 이미지/음성 확장자를 통째로 무시하지는 않는다.

`docs/` 바로 아래에 다운로드한 의료 PDF·HTML과 브라우저가 함께 저장한 `*_files/`도 로컬 전용이다. 출처·해시는 `docs/medical_reference_inventory.json`에 남긴다. 원문 파일은 Git 복제만으로 복구되지 않으므로 별도로 보관하거나 해당 출처에서 다시 받아야 한다. `/data/mfds/`의 API 원문·조회 DB도 동일하게 Git에서 제외한다.

`mobile/test/fixtures/legacy_selective_v2.carebackup`은 코드에 공개된 합성 비밀번호를 사용하는 이전 백업 형식의 호환성 시험 자료다. 이 파일만 백업 제외 규칙에서 예외로 둔다. 새로운 백업은 같은 폴더에 넣어도 기본적으로 제외되며, 실제 수첩 백업을 이 파일로 덮어써서는 안 된다.

기존에 Git이 추적하는 파일에는 `.gitignore`가 소급 적용되지 않는다. 민감한 파일을 발견하면 값 노출 없이 알리고, 실제 자격 증명은 폐기·재발급하며 필요한 이력 정리는 별도로 진행해야 한다. 단순히 `.env`로 옮기는 것만으로 과거 커밋에서 사라지지 않는다.

## `.env` 사용 범위

Flutter 앱의 기록·챗봇·OCR·음성 입력은 로컬에서 동작하며 `.env`나 외부 AI API 키를 읽지 않는다. 앱 assets, `--dart-define`, 소스 코드에 API 키·PIN·DB 키·백업 비밀번호를 넣지 않는다. 앱의 잠금·암호화 키는 기존 기기 보안 저장소가 관리한다.

루트 [`.env.example`](../.env.example)은 PC에서 식약처 공개 데이터를 수집하는 스크립트용이다. e약은요는 `scripts/fetch_mfds_easy_drug.py`, 허가정보·DUR은 `scripts/fetch_mfds_local.py`를 사용한다. 실제 키는 빈 상태로 제공한다. 로컬 `.env`가 없는 경우에만 예시를 복사하고, 기존 `.env`는 덮어쓰지 않는다. `MFDS_EASY_DRUG_SERVICE_KEY`, `GETDRUG_SERVICE_KEY`, `DUR_SERVICE_KEY`는 각 서비스의 발급받은 키다. `MFDS_EASY_DRUG_API_ENDPOINT`, `GETDRUG_ENDPOINT`, `DUR_ENDPOINT`는 코드가 허용하는 공식 HTTPS 주소다. 프로세스 환경변수가 같은 이름의 `.env` 값보다 우선한다. 로컬 조회에는 `.env`와 인증키가 필요 없다.

이전 로컬 설정의 `CARE_APP_TEXT_MODEL_ID`, `CARE_APP_TEXT_MODEL_PATH`, `CARE_APP_TEXT_MODEL_REVISION`은 현재 앱/학습 스크립트가 읽지 않는다. 모델 선택은 현재 실험 설정과 manifest가 담당하므로 예시에 이 변수를 추가하지 않는다. 기존 로컬 값은 삭제하지 않는다. Hugging Face 캐시·오프라인·telemetry 설정 및 Android SDK 경로는 현재 스크립트가 관리하므로 비밀 설정 예시에 중복하지 않는다.

## 업로드 전 확인

```powershell
git status --short
git diff --cached --stat
git ls-files -ci --exclude-standard
git check-ignore -v .env
```

`git add -f`는 제외 규칙을 우회한다. 공유할 평가 결과에는 합성/공개 자료 여부와 재현 근거를 남기고 실제 간병 원문·기기 캡처·로그는 포함하지 않는다.

## 2026-09-11 확인 결과

- 작업 시작 시 추적 파일 330개와 새 파일 64개, 로컬 refs에서 도달 가능한 커밋 32개/파일 내용 객체 645개를 검사했다. 검사 결과에는 비밀 값 자체를 출력하지 않았다.
- 현재 `.env`의 서비스 키 원문·URL 디코딩 값과 주요 API 토큰/개인키 패턴을 대조한 범위에서 실제 자격 증명 노출을 찾지 못했다. 비밀번호 상수 감지는 임시 저장소를 사용하는 합성 백업 테스트에서 나온 것으로 확인했다.
- 이력에 발견된 백업 확장자는 위의 합성 호환성 fixture 한 개다. 검사한 Git 이력에 `.env`나 서명 키 파일은 없었다.
- 신규 Git 후보 중 가장 큰 파일은 약 640 KB의 `experiments/mobile_ai_v1/sources.lock.json`이다. 이력의 10 MiB 초과 파일도 없었다. 수 GB 모델·APK·SDK는 Git 대상이 아니었다.
- 추가한 세 파일은 `.env.example`, 이 안내 문서, 합성 fixture 안내다. 기존 후보 파일이 새 ignore 규칙 때문에 제외되는 경우는 없었고, `git ls-files -ci --exclude-standard`도 비어 있었다. 실제 `.env` 값은 변경하지 않았다.
- 제외 경로 60개, 유지 경로 16개, `core.ignorecase=false`에서 두 benchmark 폴더 이름을 검사했다. dotenv 예시 파싱·공식 endpoint·빈 키 거절과 downloader 테스트 14개가 통과했다. `git diff --check`도 통과했다.
- 검사 결과는 로컬 `data/repo-hygiene/audit-before.json`, `audit-after.json`, `verification.json`에 두며 Git에서는 제외한다.

이 검사는 현재 작업 폴더와 로컬에 존재하는 Git 이력을 대상으로 했다. GitHub 원격 서버의 최신 상태를 다시 가져오거나 PR·Issue·Release 첨부를 조사하지 않았으며, 패턴 검사만으로 모든 형태의 비밀정보 부재를 보장하지 않는다. 커밋·푸시·추적 해제·Git 이력 변경은 수행하지 않았다.
