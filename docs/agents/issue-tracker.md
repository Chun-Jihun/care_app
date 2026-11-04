# Issue tracker: GitHub

- 저장소: `Chun-Jihun/care_app`
- URL: https://github.com/Chun-Jihun/care_app
- 개발 이슈·버그·기능 요청·명세는 이 저장소의 GitHub Issues에서 관리한다.
- 연결된 GitHub 도구를 우선 사용한다. CLI를 사용할 때는 `gh`를 사용하고 저장소를 명시한다.
- 원격 작업 전에 대상 저장소를 확인한다. 플러그인의 원본 저장소나 다른 upstream 저장소에 이슈를 작성하지 않는다.
- 이슈와 첨부에는 합성 재현 자료만 사용한다. 실제 간병기록·사진·대화 원문·인증키는 포함하지 않는다.

## 기본 작업

GitHub 도구에는 `repository_full_name: Chun-Jihun/care_app`을 지정한다. CLI가 설치·인증된 환경에서는 다음 명령을 사용한다.

- 대상 확인: `gh repo view Chun-Jihun/care_app --json nameWithOwner,url`
- 조회: `gh issue view <number> --repo Chun-Jihun/care_app --json number,title,body,labels,comments`
- 목록: `gh issue list --repo Chun-Jihun/care_app --state open --json number,title,body,labels`
- 생성: `gh issue create --repo Chun-Jihun/care_app --title "<title>" --body-file <utf8-file>`
- 댓글: `gh issue comment <number> --repo Chun-Jihun/care_app --body-file <utf8-file>`
- 라벨: `gh issue edit <number> --repo Chun-Jihun/care_app --add-label "<label>"` 또는 `--remove-label "<label>"`
- 종료: 설명을 댓글로 남긴 뒤 `gh issue close <number> --repo Chun-Jihun/care_app`를 실행한다.

여러 줄 본문은 실제 줄바꿈을 가진 UTF-8 임시 파일이나 구조화된 도구 인자로 전달한다. 닫힌 이슈에도 설명이 필요하면 댓글을 별도로 작성한다.

스킬이 “publish to the issue tracker”를 요청하면 GitHub 이슈를 생성한다. “fetch the relevant ticket”은 해당 이슈 본문·라벨·댓글을 읽는 작업이다.

## 이슈 관계

상위·하위 작업은 GitHub의 sub-issue 관계로 연결한다. 지원되지 않으면 하위 본문에 `Part of #<parent>`, 상위 본문에 하위 작업 목록을 남긴다.

선행 작업은 GitHub의 native issue dependency로 연결한다. 지원되지 않으면 본문 첫 부분에 `Blocked by: #<number>`를 남긴다. 모든 선행 이슈가 닫혀야 시작 가능한 작업으로 취급한다.

## Pull requests as a triage surface

PRs as a request surface: no.
