# 합성 백업 호환성 자료

`legacy_selective_v2.carebackup`은 `mobile/test/draft_backup_test.dart`의
`ARCH-06` 시험에서 사용하는 고정 format 2 백업이다. 실제 수첩이나 환자 자료가
아니며 시험용 비밀번호도 해당 테스트 코드에 공개되어 있다.

루트 `.gitignore`는 이 파일만 `*.carebackup` 제외 규칙의 예외로 둔다.
개인 수첩 백업은 `/data/`에 보관하고, 이 파일을 실제 백업으로 덮어쓰거나
실제 간병 자료에 맞춰 수정하지 않는다.
