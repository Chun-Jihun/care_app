# 앱 언어 관리

지원 코드: `ko`, `en`, `ja`, `zh_Hans`, `zh_Hant`. `AppLanguage`에 표시 언어와 Flutter `Locale`을 정의한다. 중국어 스크립트를 명시하므로 간체와 번체를 각각 선택할 수 있다.

`catalogs/*.json`이 번역 원본이다. 한국어 원문을 키로 사용하며 다섯 파일에서 키와 `{0}`, `{1}` 등 자리표시자를 일치시킨다. `catalogs.g.dart`는 직접 편집하지 않는다. `mobile/`에서 실행:

```sh
dart run tool/generate_translations.dart
dart run tool/generate_translations.dart --check
flutter analyze
flutter test
```

화면에서는 `context.tr('저장')`, 변수가 있으면 `context.tr('버전 {0}', [version])`을 사용한다. 개발 중 등록되지 않은 키는 assertion으로 검출한다. 키를 수정하면 모든 번역 파일도 함께 수정한다. 중복되는 공통 문구는 같은 키를 공유한다.

사용자 데이터 자체를 번역 키로 전달하지 않는다. 환자 이름은 `context.strings.patient(patient)`, 기록 요약은 `context.strings.summary(entry)`로 표시하여 별칭과 자유 입력은 그대로 유지한다. 선택지·필드명 등 개발자가 정의한 메타데이터만 번역한다. 자리표시자는 한 번만 치환하므로 사용자 원문 안의 `{0}` 등을 다시 해석하지 않는다. `CareError.labels`에는 사용자 입력이 아닌 필드명만 넣는다.

오류는 `CareError(CareErrorCode.requiredField, labels: ['단위'])`처럼 고정 코드로 생성한다. 표시 문구는 `error_messages.dart`에서 번역 키에 연결한다. 코드의 의미를 문구 변경에 맞춰 바꾸지 않으며, 새 코드는 다섯 번역 카탈로그에도 등록한다. `DraftStatus`도 enum으로 유지하고 `AppStrings.draftStatus`에서만 표시 문구로 변환한다.

언어는 `CareController.setLanguage`에서 보안 저장소 `app.language`에 저장한 뒤 적용한다. 기기의 다른 민감정보를 읽거나 앱 잠금을 해제하지 않는다. 언어 설정은 환자 기록과 독립적이며 백업에 포함하지 않는다. 수첩 전체 삭제 이후에도 표시 언어는 유지한다. 기존 설정이 없거나 알 수 없는 값이면 한국어를 사용한다.

향후 예약 알림은 같은 ID와 시각으로 문구를 갱신하며 의료정보를 담지 않는다. 잠긴 상태에서 선택한 언어는 다음 잠금 해제 후 예약에 반영한다. 이미 게시된 알림과 예정 시각이 지났지만 아직 배달되지 않은 알림은 소급 변경하지 않는다. Android 알림 채널의 이름도 갱신한다.

OS 앱 이름은 Android `res/values*/strings.xml`과 iOS `*.lproj/InfoPlist.strings`에서 관리한다. OS 권한창 등은 기기의 시스템 언어를 따르며 앱 내 선택 언어와 다를 수 있다. 인증 플러그인에 전달하는 제목·취소·사유는 앱 언어를 따른다. 새 언어를 추가할 때는 `AppLanguage`, 생성 도구의 코드 목록, JSON 및 네이티브 리소스를 함께 추가한다.

언어를 국가 설정으로 사용하지 않는다. 긴급 연락처는 대한민국 119임을 명시한다. 기존 기록·질문·약 이름·복원 수첩 이름과 진료 준비 원문을 언어 변경으로 다시 작성하지 않는다.
