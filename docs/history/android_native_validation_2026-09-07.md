# Android 네이티브 검증 — 2026-09-07

## 환경과 범위

Windows에서 Android 15(API 35) Google APIs x86_64, Pixel 5 프로필의 전용 `care_validation` AVD(포트 5560)를 사용했다. Flutter release APK를 설치해 실제 네이티브 플러그인과 OS 화면을 조작했다. 실물 휴대전화 또는 iOS 실행 결과가 아니다. 에뮬레이터 카메라는 합성 장면을 사용했고 호스트 웹캠·실제 환자 자료는 사용하지 않았다.

시험용 수첩에는 `NATIVE_CAMERA_TEST`, `NATIVE_CHAT_TEST`, `NATIVE_REMINDER_TEST`, `NATIVE_CANCEL_TEST` 같은 합성 문구만 직접 입력했다. 기기 PIN·지문 등록은 이 AVD에만 수행했다. 아래 결과는 대역을 쓰는 `flutter test` 결과와 구분한다.

최종 APK SHA-256: `BE4A272F993AF8195CFC4830B6EEDD89801C0A05F0F43363906F7D37232756ED`. 패키지 권한 검사에서 `INTERNET` 없음. Flutter 정적 분석 오류 없음, 단위·저장·위젯 시험 19개 통과.

## 확인한 결과

| 항목 | 실제 실행 결과 |
|---|---|
| 촬영과 첨부 | 앱의 촬영 버튼 → Android 카메라 → Shutter → Done → 114 KB 첨부 1개 생성. 첨부 열기 성공 |
| 촬영 취소 | 카메라에서 뒤로가기 후 기록 화면 복귀. 기존 사진 1개 유지 |
| 암호화 파일·캐시 | 앱 전용 저장소에 `.enc` 첨부 확인. 정상 촬영 처리 후 앱 전용 cache에 JPG/PNG 원본 없음 |
| 앱 업데이트 | 대화 스키마가 없는 기존 APK에서 v2 APK로 `install -r`. 기존 메모와 첨부 유지·재열람 |
| 화면 보호 | Android `screencap` 결과에서 사진 화면이 검게 가려짐. 보호 플래그를 해제하지 않고 UI 트리로 동작 확인 |
| 시스템 뒤로가기 | 사진 확대 → 기록 상세 → 일기 화면으로 복귀. 수정 전에는 앱이 종료되어 회귀 수정 |
| 인증 미등록 | OS PIN·지문이 없는 상태에서 기기 인증 활성화 실패, 스위치 꺼짐 유지 |
| OS PIN | OS 인증창의 잘못된 시험 PIN은 `Wrong PIN`, 올바른 시험 PIN은 수첩 열기 성공 |
| 가상 지문 | 등록하지 않은 ID 2는 `Not recognized`, 등록한 ID 1은 잠금 해제 성공 |
| 인증 취소 | OS 인증 취소 후 앱 PIN 화면 유지. 취소를 저장 공간 오류로 안내하던 오류 처리 수정 |
| 알림 권한 | 실제 POST_NOTIFICATIONS 권한 거부 → 앱 스위치 꺼짐과 설정 안내. 재요청 허용 → 스위치 켜짐 |
| 대화 보관 | Android 대화창에서 7일 선택, `NATIVE_CHAT_TEST` 작성. APK 업데이트와 잠금 후 재열기 시 같은 질문과 `답변 없음` 표시 |
| 알림 예약 | 앱에서 합성 할 일을 11:12로 저장. `dumpsys alarm`의 해당 앱 `RTC_WAKEUP`과 `ScheduledNotificationReceiver`, 예약 시각 확인 |
| 업데이트 후 예약 유지 | 최종 release APK를 `install -r`로 설치한 뒤 같은 11:12 알람이 OS에 다시 등록됨 |
| 알림 실제 게시 | 11:12 예약이 11:12:54.448에 게시됨(약 54초 지연). OS NotificationRecord와 펼친 알림창에서 확인 |
| 알림 내용과 열기 | 제목 `간병수첩`, 본문 `확인할 일정이 있어요. 수첩을 열어 확인해 주세요.`, `vis=SECRET`. 환자명·질문·할 일 원문 없음. 알림 선택 시 앱 PIN 화면으로 이동 |
| 알림 해제 | 별도 미래 일정 `NATIVE_CANCEL_TEST`의 12:16:55 RTC_WAKEUP 등록 확인 후 설정에서 알림 끔. 스위치 false, 실제 활성 예약 0개 확인 |

일반 일정 알림의 실제 지연을 관측한 결과이며 정시 도착을 보장하는 시험이 아니다. 원본 게시 상태는 로컬 `.tools/native-validation/notification-delivery.txt`, 예약 해제 전후는 `alarm-before-disable.txt`, `alarm-after-disable.txt`에 있다. 시험 완료 후 전용 에뮬레이터를 종료했다.

## 발견하고 수정한 문제

1. Android 시스템 뒤로가기가 인증된 중첩 Navigator를 통과하지 못했다. `NavigatorPopHandler`로 실제 열린 상세 페이지를 닫도록 연결하고 `handlePopRoute` 위젯 시험을 추가했다.
2. release 리소스 축소가 Dart 문자열로만 참조한 알림 아이콘을 제거했다. `res/raw/keep.xml`에서 보존하고 APK 리소스 테이블에서 `drawable/ic_notification` 포함을 확인했다.
3. Android 기본 시간대 `GMT`가 축약 IANA 데이터에 없어 알림 초기화가 실패했다. 전체 별칭을 포함한 `latest_all.dart`로 변경했다. 임의의 다른 시간대로 대체하지 않으며 GMT·Asia/Seoul 회귀시험을 추가했다.
4. OS 인증 취소 예외가 일반 저장 실패 안내로 표시됐다. OS 인증 실패를 인증 실패로 반환해 앱 PIN 대안을 유지한다.
5. 잠금 전에 띄운 삭제 확인창·날짜 선택창도 인증된 Navigator에 연결했다. 삭제 확인창이 잠금 시 함께 제거되는 위젯 회귀시험을 추가했다.

## 다시 실행하기

`scripts/android_validation.py`는 작업 전에 `adb emu avd name`을 확인하여 `care_validation` / `emulator-5560`에만 동작한다. 전용 AVD와 SDK가 준비된 상태에서:

```powershell
.\scripts\mobile.ps1 -Action BuildAndroid
.\.tools\android-sdk\platform-tools\adb.exe -s emulator-5560 install -r mobile/build/app/outputs/flutter-apk/app-release.apk
.\.venv-qwen35\python.exe scripts/android_validation.py tree
.\.venv-qwen35\python.exe scripts/android_validation.py tap '촬영'
.\.venv-qwen35\python.exe scripts/android_validation.py key 4
```

기기별 텍스트·언어·화면 전환 시간은 달라질 수 있으므로 각 단계의 UI 트리를 확인한다. UI 조작 명령을 여러 프로세스에서 동시에 실행하지 않는다. `tap`은 정확히 일치하는 텍스트·접근성 이름·리소스 ID를 우선 사용한다. 앱 캡처는 보호되므로 `mobile/build/preview/chat.png`는 위젯 시험이 합성 데이터로 렌더링한 미리보기다.

## 남은 범위

- 실물 Android 카메라·제조사별 절전/알림 정책·하드웨어 생체인증과 OS 키 무효화.
- 카메라 실행 중 프로세스 종료, 저장 공간 부족, OS 권한의 설정 앱 외부 변경.
- OS 재부팅·시간대 변경·장기 절전 후의 예약 동작. 이번에는 실제 APK 교체 후 예약 재등록을 확인했으며 이를 재부팅 시험과 동일하게 취급하지 않는다.
- iOS 빌드, 카메라 권한, Face ID/Touch ID, Keychain 및 로컬 알림. Mac/Xcode와 iOS 장치가 필요하다.

에뮬레이터의 가상 지문 통과는 실물 센서의 보안·인식률 검증을 의미하지 않는다. 알림은 기기 상태에 따라 지연되는 일반 일정 알림이며 정확한 투약 시각을 보장하지 않는다.
