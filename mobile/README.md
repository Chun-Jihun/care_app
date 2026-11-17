# 모바일 개발 안내

[문서 홈](../docs/README.md) · [앱 사용 안내](../docs/mobile_current_guide.md) · [제품 요구사항](../docs/caregiving_notebook_requirements.md)

Flutter 앱의 실행, 검증, 빌드와 저장소 변경에 필요한 정보입니다. 첫 출시 대상은 Android입니다.

[실행](#실행) · [검사](#검사) · [Android 빌드와 배포](#android-빌드와-배포) · [저장소와 백업 형식](#저장소와-백업-형식)

## 실행

| 도구 | 저장소 기준 |
| --- | --- |
| Flutter / Dart | 3.47.2 / 3.13.2 |
| JDK | 21 |
| Android SDK | compile SDK 37, 최소 Android 7.0(API 24) |
| Android 빌드 | AGP 9.3.2 / Gradle 9.5.0 |

Flutter와 Android SDK를 준비하고 Android 기기 또는 에뮬레이터를 연결합니다. 첫 의존성 설치·SQLCipher 네이티브 바이너리 다운로드에는 인터넷이 필요합니다.

```sh
cd mobile
flutter pub get
flutter run
```

Windows에서 저장소의 `.tools/flutter`와 `.tools/android-sdk`를 사용하는 경우 루트에서 다음 명령을 실행합니다.

```powershell
.\scripts\mobile.ps1 -Action Dependencies
.\scripts\mobile.ps1 -Action Run
```

SDK Manager의 compile SDK 패키지는 `platforms;android-37.0`입니다. Windows에서는 플러그인 소스와 Android 빌드가 같은 드라이브에 있도록 저장소의 `.tools/pub-cache`를 사용합니다. 설치와 캐시 위치는 [저장소·환경 설정](../docs/repository_hygiene.md)을 함께 확인하세요.

## 검사

저장소 루트의 Windows PowerShell에서 실행합니다.

```powershell
python -m pip install -r scripts/requirements-quality.txt
.\scripts\mobile.ps1 -Action Dependencies
.\scripts\quality.ps1
```

| 확인하고 싶은 내용 | 실행 방법 |
| --- | --- |
| Flutter 앱만 검사 | 루트에서 `mobile.ps1 -Action Validate`를 실행하거나 `mobile/`에서 `flutter analyze`와 `flutter test --concurrency=1`을 실행합니다. |
| Python과 Flutter를 함께 검사 | `quality.ps1`이 Python 구문·미정의 이름 lint, 단위 시험, 번역 계약, Flutter 분석·시험, 저장소 강제 종료 복구와 `care_ort` 분석을 실행합니다. |
| Android 빌드와 배포 구성 검사 | SDK가 준비된 환경에서 `quality.ps1 -BuildAndroidDebug`. 기본·광고 시험 APK와 배포 매니페스트·백업 규칙·런타임 의존성을 검사합니다. |
| 원격 실행 결과 확인 | [GitHub Actions 워크플로](../.github/workflows/quality.yml)의 해당 커밋 실행을 확인합니다. |

기본 시험은 합성 기록을 사용하며 모델·의료 자료·`.env`·API 키·GPU 없이 실행합니다. Flutter 시험은 순차 실행을 기본으로 합니다. 언어 카탈로그 변경은 [번역 관리 안내](lib/l10n/README.md), 기능별 기대 결과는 [안전 검증 시나리오](../docs/safety_validation.md)를 참고합니다.

### 기기 검증과 출시 확인

자동 시험에는 SQLCipher 재개방·복구, 수첩 분리, 백업 호환과 복원, 권한 오류, 대화 보관, 큰 글자 UI를 포함합니다. 기기 검증은 카메라·파일 선택, 생체인증, 백그라운드·재부팅 뒤 알림과 위젯, 업데이트·서명 전환을 별도로 다룹니다. 저사양 기기에서는 큰 백업의 최고 메모리, 저장 공간 부족, 배터리와 네이티브 AI 자원 반환을 측정합니다. [Android 검증 기록](../docs/history/README.md#android와-앱-검증)

2026-11-15 Android 시험에서는 Drive 첫 백업 업로드와 다운로드·비밀번호 확인을 거쳐 복원 미리보기까지 확인했습니다. 별도 기기에서 복원 수첩을 추가하는 시험은 남아 있습니다. Play 배포본은 실제 Play 앱 서명과 개인정보 처리방침, 데이터 보안 응답을 함께 검증합니다.

## Android 빌드와 배포

아래 명령은 `mobile/`에서 실행합니다.

```sh
flutter build apk --debug --target-platform=android-arm64
flutter build appbundle --release
```

개발 APK는 `build/app/outputs/flutter-apk/app-debug.apk`에 생성됩니다. 배포에 필요한 APK는 `flutter build apk --release --target-platform=android-arm64`로 생성합니다. 배포 빌드는 `android/key.properties`와 정식 키가 필요합니다. 속성은 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`이며 상대 `storeFile` 경로의 기준은 `mobile/android`입니다. 키와 설정 파일은 로컬에서만 관리합니다. 서명이 다른 APK로 바꿀 때는 백업·복원으로 데이터를 옮길 수 있는지 확인합니다.

배포 자동 감사에서는 병합 매니페스트와 백업 제외 규칙, Gradle의 전이·로컬 의존성을 검사합니다. 권한 허용 목록 밖 항목, 광고 SDK, 시험 컴포넌트, 승인되지 않은 로컬 라이브러리와 운영체제 백업·기기 전송 경계의 변경을 차단합니다. `:app:prepareReleaseAudit`의 보고 경로는 `mobile/build/app/reports/release-audit`입니다.

### Google Drive 백업 설정

1. Google Cloud 프로젝트에서 Drive API를 켭니다.
2. 같은 프로젝트에 Android OAuth 클라이언트와 웹 OAuth 클라이언트를 등록합니다. Android 클라이언트는 실제 앱 ID와 서명 SHA-1을 사용합니다. Google Play 배포본은 Play 앱 서명 인증서 SHA-1을 등록합니다.
3. 웹 클라이언트 ID를 빌드에 전달합니다. ID가 설정된 Android 빌드에서 Drive 메뉴가 표시됩니다.

```sh
flutter build appbundle --release --dart-define=CARE_GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID
```

OAuth 테스트 모드에서는 등록한 테스트 계정으로 검증합니다. 배포 전에는 공개 OAuth 설정·브랜딩·처리방침과 Play Console 신고를 확인합니다. 앱은 선택한 계정에서 앱 전용 Drive 공간에 접근하는 `drive.appdata` 권한을 요청합니다. [Google OAuth 대상 설정](https://support.google.com/cloud/answer/15549945?hl=ko) · [Drive 앱 전용 공간](https://developers.google.com/workspace/drive/api/guides/appdata)

<details>
<summary>광고와 오프라인 시험 APK</summary>

아래 명령은 Windows에서 `mobile/android`를 기준으로 실행합니다.

```powershell
.\gradlew.bat :ad-test:assembleDebug -PcareDeviceTest=ads
.\gradlew.bat :app:assembleDebug -Ptarget-platform=android-arm64 -PcareDeviceTest=offline
```

광고 시험 APK는 `mobile/build/ad-test/outputs/apk/debug/ad-test-debug.apk`에 생성됩니다. 시험 배너는 공개 사용 안내에서 **시험 배너 불러오기**를 누른 때 요청합니다. 광고 시험의 `org.carenotebook.care_notebook.adtest`는 오프라인 수첩 시험의 `.devtest`와 앱 ID·UID가 분리됩니다. 수첩 시험에는 합성 자료를 사용합니다. 정식 수첩 빌드의 인터넷 권한은 선택형 Google 연결과 Drive 백업에 사용하며 평문 HTTP는 차단합니다.

</details>

<details>
<summary>iOS 후속 지원</summary>

공통 Flutter 코드와 iOS 프로젝트를 관리합니다. 지원을 재개할 때 Mac/Xcode에서 `flutter build ios --no-codesign`으로 컴파일하고 서명·실행·앱 전환 가림·Keychain·파일 보호를 기기에서 검증합니다. WidgetKit은 Runner와 확장에 같은 Team, `group.org.carenotebook.careNotebook.widget` App Group 및 위젯 공용 Keychain 그룹이 필요합니다. 기존 Runner 기본 Keychain 그룹은 첫 항목에 둡니다. iOS 빌드와 기기 검증은 후속 지원 범위입니다.

</details>

## 코드 구조

| 경로 | 맡는 일 |
| --- | --- |
| [`lib/domain/`](lib/domain/) | 기록 모델, 유효성, 의료 및 AI 결과 계약 |
| [`lib/application/`](lib/application/) | 수첩과 잠금 세션, 기능별 서비스, 저장소·플랫폼 계약 |
| [`lib/infrastructure/`](lib/infrastructure/) | SQLCipher, 마이그레이션, 첨부·백업 암호화, 네이티브·Drive 어댑터 |
| [`lib/presentation/`](lib/presentation/) | 오늘·일기·약·진료·설정과 사용자 입력 흐름 |
| [`test/`](test/) | 합성 기록, 저장소 통합, 위젯과 회귀 시험 |

기능은 서비스에서 수첩과 세션을 확인한 뒤 저장소를 사용합니다. 화면에는 기능 단위 명령과 결과를 전달합니다. [도메인 용어](../GLOSSARY.md) · [목표 데이터 스키마](../docs/mobile_app_data_schema_design.md)

## 저장소와 백업 형식

| 구성 | 현재 계약 |
| --- | --- |
| 로컬 DB | **schema 7**. `care.db`와 `identity.db`를 별도 256비트 키로 암호화합니다. 키·스키마·무결성이 맞지 않으면 열기를 중단합니다. |
| 선택 백업 | **format 3 / document_version 6**. PBKDF2-HMAC-SHA256 210,000회와 AES-256-GCM으로 보호합니다. 사진 합계 50MiB·내부 데이터 100MiB 한도가 적용됩니다. |
| 읽기 호환 | 선택 백업 문서 v1~v5와 format 2/schema 3, 이전 전체 교체 format 1을 읽습니다. format 1은 현재 기기나 백업에 녹음 원본이 있을 때 차단합니다. |
| 선택 복원 | 새 수첩과 새 ID로 원본 참조를 연결합니다. 실제 남은 복원 항목을 기준으로 중복을 차단합니다. 복원한 항목을 모두 삭제한 뒤 다시 복원할 수 있습니다. |

DB와 백업 문서 버전은 각각 관리합니다. [백업 계약 설계 결정](../docs/adr/0001-frozen-backup-contract.md) · [사용자 백업·복원 흐름](../docs/mobile_current_guide.md#백업과-업데이트)

- 식별정보와 간병기록의 연결 변경은 DB 트랜잭션으로 처리합니다. 처방 이력과 기록 수정 전 버전을 보존하고, 진료 준비는 `visit_source`의 원본 참조를 사용합니다.
- 사진은 메모리에서 사진 방향을 적용하고 다시 인코딩해 EXIF·위치·원본 파일명을 제거합니다. 사진별 키와 AES-256-GCM으로 암호화합니다. 일반 첨부 한도는 20MiB·2,400만 화소입니다. OCR 입력 한도는 [AI 안내](../docs/mobile_ai_integration.md)를 따릅니다.
- 초안은 입력 후 약 400ms 뒤 암호화해 저장합니다. 확정 기록 저장과 초안 삭제는 한 트랜잭션에서 수행합니다. 저장된 원본이나 처방 버전이 바뀌면 자동 덮어쓰기를 막습니다.
- 백업에는 선택 행과 사진별 키·암호화 사진을 담습니다. 기기의 저장소 마스터 키는 보안 저장소에 남고, 백업 생성은 메모리에서 암호화한 뒤 저장합니다. 복원은 새 암호화 세대에서 참조와 무결성을 확인한 뒤 전환합니다.

<details>
<summary>네이티브 AI 패키지와 과거 실험 재현</summary>

AI·근거 패키지는 최종 경로 옆 `.partial`에서 크기와 해시를 확인한 뒤 pack, 신뢰 명세 순으로 게시합니다. I/O 오류는 이 실행의 산출물만 되돌립니다. 중단으로 남은 임시 파일은 실행 중인 작업과 최종 명세·pack 무결성을 확인한 뒤 처리합니다. 새 버전은 파일명과 manifest 버전을 바꾸고 기존 버전을 보존합니다. [모바일 AI 빌드](../docs/mobile_ai_integration.md#개발-재현) · [근거 자료 패키지](../docs/mobile_knowledge_package.md)

`python -m unittest discover -s integration_tests -v`는 고정한 `ds-agent-pilot-v1`, `qwen35-nf4-smoke-v6` 및 통합 결과가 있는 환경에서 실행합니다. 과거 입력이 빠지면 해시 대조 시험에서 실패합니다. 자동 시험과 연구 결과의 해석 범위는 [AI 연구와 검증](../docs/README.md#ai-연구와-검증)에 있습니다.

</details>
