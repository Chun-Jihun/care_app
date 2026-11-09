# 합성 백업 호환성 자료

`legacy_selective_v2.carebackup`은 `mobile/test/draft_backup_test.dart`의
`ARCH-06` 시험에서 사용하는 고정 format 2 백업이다. 실제 수첩이나 환자 자료가
아니며 시험용 비밀번호도 해당 테스트 코드에 공개되어 있다.

`legacy_full_v1.carebackup`은 커밋 `7512148`의 내보내기로 만든 고정 format 1
백업이다. DB는 schema 6이며, 새 합성 수첩에 메모·생성한 이미지·내 상태·대화
각 한 건을 담았다. 시험용 비밀번호는 `test/support.dart`에 있다.

루트 `.gitignore`는 이 두 합성 파일에만 `*.carebackup` 제외 규칙의 예외를 둔다.
개인 수첩 백업은 `/data/`에 보관한다. 합성 파일을 실제 백업으로 덮어쓰거나
실제 간병 자료에 맞춰 수정하지 않는다.
