# 간병수첩 모바일 기본 앱

Android·iOS 공통 Flutter 앱. 모델, API 키, 회원가입 없이 직접 작성하는 간병 기록을 관리한다. 전체 제품 요구사항은 [`../docs/caregiving_notebook_requirements.md`](../docs/caregiving_notebook_requirements.md), 구현 전 실패 시나리오는 [`../docs/non_ai_foundation_safety_plan.md`](../docs/non_ai_foundation_safety_plan.md)에 있다.

## 실행

기준 도구: Flutter 3.47.2 / Dart 3.13.2, JDK 21, Android compile SDK 37, AGP 9.3.2 / Gradle 9.5.0. 최소 OS: Android 7.0(API 24), iOS 15. 첫 의존성 설치·SQLCipher 네이티브 바이너리 다운로드·빌드에는 인터넷이 필요하다. 실행 중인 앱에는 AI 서버나 분석 SDK가 없다.

프로젝트 루트의 Windows PowerShell:

```powershell
.\scripts\mobile.ps1 -Action Dependencies
.\scripts\mobile.ps1 -Action Analyze
.\scripts\mobile.ps1 -Action Test
.\scripts\mobile.ps1 -Action BuildAndroid
.\scripts\mobile.ps1 -Action Run
```

이 스크립트는 `.tools/flutter`, `.tools/android-sdk`, 프로젝트 내부 의존성 캐시를 사용한다. 이미 설치한 Flutter를 사용하는 다른 환경에서는 `mobile/`에서 아래 명령을 실행한다.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --release
```

APK: `build/app/outputs/flutter-apk/app-release.apk`. 현재는 설치 시험용으로 개발 서명을 사용한다. 스토어 출시 전에는 정식 서명·앱 식별자·배포 설정을 확정해야 한다. release에는 인터넷 권한이 없으며 debug/profile의 인터넷 권한은 Flutter 개발 도구 연결용이다.

iOS는 Mac과 Xcode, 서명 팀 설정이 필요하다. `flutter build ios --no-codesign`으로 먼저 컴파일을 확인한 후 기기에서 실행한다. Windows에서는 iOS 빌드를 검증하지 않았다.

## 사용할 수 있는 기능

| 화면 | 첫 구현 |
|---|---|
| 시작·잠금 | 계정 없는 시작, 6자리 PIN, 실패 횟수·대기시간 유지, 선택적 기기 인증, 백그라운드 가림과 잠금 |
| 돌봄 대상 | 이름 없이 생성, 본인·가족·동거인·간병인 역할, 수첩 전환·수정·삭제, 선택적 연락처 |
| 오늘 | 입력된 기록 수·수분량·복용함 건수, 빠른 기록, 일정·할 일 CRUD와 완료 처리 |
| 일기 | 식사·수분, 실제 복약, 증상, 활동·재활, 측정, 생활, 사건, 진료·연락, 인계, 자유 메모의 10종 기록 |
| 기록 상세 | 날짜·시각, 종류·날짜·검색어 필터, 수정 이력, 삭제, 사진 촬영·선택·확대·삭제 |
| 약 | 직접 입력한 약·처방 지시·매일 확인할 시각, 변경 전 계획 보존, 복용함·누락·거부·모름 기록, 목록 보관 |
| 진료 준비 | 질문 목록, 사용자가 선택한 원본 기록, 원본 변경 시 재검토 표시, 의료진 설명을 직접 옮긴 진료 메모 |
| 간병 도우미 | 상단 말풍선으로 여는 대화창, 수첩별 질문 작성·삭제, 보관 방식 선택, 진료 준비로 옮겨 편집 |
| 설정 | 간병인 자신의 피로·수면·스트레스 기록, 로컬 알림, 암호화 백업·복원, 전체 삭제 |

약 알림이나 할 일 완료는 실제 복약 기록을 자동으로 만들지 않는다. 화면의 합계는 입력된 사실의 합계이며 임상 판단이 아니다. 진료 준비는 원본을 모아 보여 준다. 의료 질문·상호작용 판정·운동 추천·위험 규칙·OCR·음성 전사·가족 공유·서버 동기화는 이 앱에 연결하지 않았다.

## 저장 구조와 코드

- `lib/domain/`: 기록 종류, 입력 검증, 데이터 모델. 임상 임계값이나 의약학 지식 없음.
- `lib/application/`: 수첩 선택, 잠금, 저장 후 갱신, 로컬 알림·사진·백업 흐름.
- `lib/infrastructure/`: SQLCipher 저장소, 암호화 파일·백업, OS 보안 키와 플랫폼 어댑터.
- `lib/presentation/`: 한국어 화면과 편집·상세 페이지.

`care.db`와 `identity.db`를 서로 다른 임의 256비트 키로 암호화하고, OS Keychain/Keystore 보호 저장소에 키를 보관한다. 키 저장소 오류 시 자동 초기화를 금지한다. SQLCipher가 아니거나 키·DB 무결성·스키마 버전이 맞지 않으면 열기를 중단한다. 환자 식별정보와 간병기록의 변경은 연결된 DB 트랜잭션으로 처리한다.

10종 상세 테이블은 공통 `care_entry`에 환자 ID와 함께 연결된다. 수정 전 값은 같은 트랜잭션의 `care_entry_revision`에 남는다. 처방 지시는 `medication_plan`의 새 버전으로 저장하고 실제 복약에는 당시 지시와 계획 ID를 보관한다. 선택한 진료 기록은 복사본 대신 `visit_source`로 연결한다. 간병인 자신의 점검은 `caregiver_checkin`으로 환자 기록과 분리한다.

사진은 메모리에서 방향을 적용하고 새 JPG로 변환해 EXIF·위치·원본 파일명을 제외한다. 파일별 AES-256-GCM 키를 별도로 암호화하여 저장한다. 네이티브 사진 선택기가 앱 전용 임시 폴더에 만든 파일은 처리 후 삭제하고 재실행 시 잔여 사진 캐시를 정리한다. 사진 보관함의 원본은 건드리지 않는다. 현재 입력 한도는 파일 20MB·2,400만 화소이며 JPG/PNG가 기준이다.

백업은 암호화 DB·사진·키를 PBKDF2-HMAC-SHA256(210,000회)와 AES-256-GCM으로 다시 감싼 파일이다. 임시 평문 백업 파일은 만들지 않는다. 비밀번호는 12자 이상, 사진 합계 50MB·전체 내부 페이로드 100MB 한도다. 복원은 별도 디렉터리에서 암호·DB·첨부 연결·사진 인증을 검증한 뒤 커밋 표식으로 전환한다. 실패한 복원은 현재 DB를 교체하지 않는다. 삭제 대기 파일과 전체 삭제는 다음 시작 시 정리를 이어간다.

스키마 v2는 v1의 기록을 보존하며 `chat_policy`, `chat_message`를 추가한다. 질문 보관은 첫 사용에 이번 잠금 해제 동안만/7일/30일/직접 삭제할 때까지 중 선택한다. 임시 질문은 메모리에만 보관하고 잠금 시 삭제한다. 기간을 선택한 질문은 암호화 DB에 저장하며 만료 시 조회·백업에서 제외한다. 보관 방식 변경 시 기존 내용의 삭제 가능성을 확인한다. 진료 준비로 옮긴 내용과 별도로 내보낸 암호화 백업은 독립된 사본이다. 대화창은 AI 미연결 상태를 명시하며 답변·의료 판단·자동 전송을 만들지 않는다.

직접 입력·확정한 기록만 허용하며 OCR 초안이나 의료진 검수 여부를 사용자 입력에서 자동으로 만들지 않는다. 목표 설계의 전체 AI·감사·지식베이스 스키마를 구현 완료한 것은 아니다.

## 검증과 남은 기기 확인

2026-09-07 Windows 검증: Flutter 정적 분석 오류 없음, 모바일 단위·저장·위젯 시험 19개 통과. 기존 Python 시험은 기본 앱 구현 당시 94개 통과했으며 이번 변경은 모바일 코드에 한정된다. Android release APK 생성 성공(약 74MB). 별도 Android 15 에뮬레이터에서 카메라·기기 인증·알림을 실행했으며 세부 결과는 [네이티브 검증 보고서](../docs/android_native_validation_2026-09-07.md)에 있다. 실제 휴대전화와 iOS 실행 결과는 포함하지 않는다.

`flutter test`: 실제 SQLCipher 파일 재개방, 잘못된 키, 환자 범위, 수정 충돌·이력, 과거 처방, 삭제 연결, 사진 메타데이터·암호화, 백업 실패·복원·재시작, 잠금 우회·지연, 알림 실패, 시간대 별칭, 대화 보관·만료·마이그레이션과 화면 입력 흐름을 검증한다. `test/app_test.dart`는 합성 데이터의 390×844 화면을 `build/preview/today.png`, `build/preview/chat.png`에 렌더링한다. Windows에서는 설치된 맑은 고딕을 미리보기용으로만 사용한다.

네이티브 어댑터는 단위·위젯 시험에서 대역으로 교체된다. 실제 Android/iOS 기기에서 다음 확인이 남아 있다.

1. 사진·파일 선택의 취소, 저장 공간 부족, 카메라 실행 중 프로세스 종료와 재시작.
2. 생체인증·기기 잠금 변경, 앱 전환과 화면 잠금, OS 키 접근 실패.
3. 알림 권한 거부·재부팅·시간대 변경·절전 상태. 알림은 정밀 투약 타이머가 아니며 지연될 수 있다. 가까운 일정부터 최대 60개를 예약한다.
4. 비행기 모드에서 저장·검색·첨부·재실행·백업·복원. iOS 빌드·Keychain·파일 보호·전환 화면 가림.

Android는 화면 캡처 보호와 OS 자동 백업·기기 전송 제외를 구성했다. iOS는 앱 전환 가림과 파일 백업 제외를 구성했으며 사용자가 직접 찍는 모든 스크린샷을 차단한다고 보장하지 않는다. 요일·기간·필요 시 복용 같은 복잡한 반복 일정, 대용량 스트리밍 백업, 앱스토어 배포는 후속 작업이다.

참고: [Flutter 설치](https://docs.flutter.dev/install), [sqlite3 SQLCipher 빌드 훅](https://pub.dev/documentation/sqlite3/latest/topics/hook-topic.html), [flutter_secure_storage 변경사항](https://pub.dev/packages/flutter_secure_storage/changelog), [AGP 9.3 호환성](https://developer.android.com/build/releases/agp-9-3-0-release-notes).
