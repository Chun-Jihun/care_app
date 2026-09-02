# e약은요 `staged → approved` 검수·승격 절차

- 현재 대상 staged ID: `mfds-easy-drug-20260901T061358Z-schema-v1`
- 데이터 상태: `awaiting_selection`
- 승격 상태: 임상 검수자 부재로 `staged → approved` 차단
- 현재 검수 카탈로그: `data/easy-drug/review/20260901T061358Z-schema-v1-review-v1`

## 목차

1. [상태와 안전 경계](#1-상태와-안전-경계)
2. [1단계: 검수 대상 선정](#2-1단계-검수-대상-선정)
3. [2단계: 검수 패킷 생성](#3-2단계-검수-패킷-생성)
4. [3단계: 권리·임상 검수](#4-3단계-권리임상-검수)
5. [4단계: 승인 스냅샷 승격](#5-4단계-승인-스냅샷-승격)
6. [승인 이후 남는 게이트](#6-승인-이후-남는-게이트)

## 1. 상태와 안전 경계

이 절차에서 파일 변환과 사람의 의료 검수는 같은 작업이 아니다.

```text
staged_unreviewed
  → awaiting_selection
  → awaiting_clinical_review
  → approved_snapshot / approved_inactive
  → 인덱스 생성·citation 검사·의료 회귀시험
  → 별도의 명시적 runtime 활성화
```

- 스크립트는 의료 검수자의 결정을 대신하거나 자동으로 `approved`를 부여하지 않는다.
- `approved_snapshot`은 승인된 원문 조각을 해시와 함께 봉인했다는 뜻이다.
- `approved_snapshot`도 즉시 앱 RAG에서 사용할 수 있는 상태는 아니다.
- 승인 직후 `runtime_rag_eligible=false`, `mobile_bundle=false`를 유지한다.
- 검수자 자격의 진위는 코드가 확인할 수 없다. 조직 또는 프로젝트의 책임자가 별도로 확인하고 그 확인자를 결정 파일에 기록해야 한다.
- 원본 staged 파일, 검수 패킷 또는 manifest의 해시가 달라지면 승격을 중단한다.
- 현재 사람·임상 검수 자원이 없으므로 선정 템플릿이나 자동 모델 판정으로 검수 결정을 대신하지 않는다. staged 자료는 구조·검색 코드의 비활성 개발 입력으로도 의료 답변 생성에 사용하지 않으며 `awaiting_selection`에서 유지한다.

## 2. 1단계: 검수 대상 선정

전체 4,758개 품목을 한 번에 검수하기보다 MVP에서 실제 평가에 사용할 소규모 품목부터 선택한다. `review_catalog.jsonl`에는 의료 원문 대신 품목명, 제조사, 개정일, 섹션별 근거 조각 수만 들어 있다.

기존 템플릿을 직접 수정하지 말고 별도 파일로 복사한다.

```powershell
Copy-Item `
  -LiteralPath 'data/easy-drug/review/20260901T061358Z-schema-v1-review-v1/selection.template.json' `
  -Destination 'data/easy-drug/review/selection.pilot-001.json'
```

복사한 파일에 다음을 기록한다.

- `selection_purpose`: 검수 목적과 MVP 범위
- `selected_by`: 선정 담당자의 내부 ID
- `selected_at`: ISO 8601 날짜 또는 시각
- `item_seqs`: 검수할 식약처 품목코드 목록

품목 선정은 임상 승인이 아니다. 대표 일반의약품, 실제 평가 시나리오에서 필요한 품목, 고위험 섹션을 포함하는 품목을 목적에 맞게 표본화한다.

## 3. 2단계: 검수 패킷 생성

다음 명령은 선택한 품목의 staged 제품·근거 조각과 미결정 상태의 검수 템플릿을 봉인한다.

```powershell
python scripts/promote_mfds_easy_drug.py prepare `
  --staged-dir data/easy-drug/staged/20260901T061358Z-schema-v1 `
  --selection-file data/easy-drug/review/selection.pilot-001.json `
  --review-id MFDS-EASY-PILOT-001
```

기본 출력은 `data/easy-drug/review-packets/MFDS-EASY-PILOT-001`이다.

- `products.jsonl`: 품목 식별정보, 원문·정규화 섹션과 raw 참조
- `evidence_spans.jsonl`: 검수할 원문 근거 조각
- `manifest.json`: staged/선정 파일 해시와 패킷 해시 경계
- `review_decisions.template.json`: 모든 결정이 `pending`인 작성 양식

`review_decisions.template.json`도 그대로 수정하지 말고 `review_decisions.completed.json`으로 복사해 작성한다.

## 4. 3단계: 권리·임상 검수

### 4.1 이용권리 검수

`rights_review`에 다음을 모두 기록한다.

- `completed: true`
- `decision: "approved"`
- 검수자 내부 ID와 검수일
- 확인한 이용허락 조건
- 이용조건을 다시 확인할 수 있는 증빙 URL

API가 공개되어 있다는 사실만으로 이용권리 검수를 자동 통과시키지 않는다. 배포·가공·표시 조건과 정책 변경 여부를 실제로 확인한다.

### 4.2 임상 검수

약사 또는 의사가 원문과 각 근거 조각을 대조하고 다음을 기록한다.

- 검수자 내부 ID, 역할과 소속
- 자격 확인 여부, 확인 담당자와 확인일
- 검수일과 다음 재검수 예정일
- 품목 식별 일치 여부
- 각 근거 조각의 `approved` 또는 `rejected` 결정
- 승인 조각의 허용 용도 `allowed_uses`
- 거절 조각의 구체적인 사유
- 템플릿의 `required_attestation`과 동일한 최종 확인문

허용 용도는 섹션별로 템플릿의 `allowed_use_options` 중에서만 선택한다. `usage`와 `interactions`를 승인하더라도 LLM이 환자별 용량·복용시각·상호작용 결론을 자유 생성하도록 허용하는 것은 아니다.

## 5. 4단계: 승인 스냅샷 승격

모든 결정과 검수 정보가 완료된 뒤에만 다음 명령을 실행한다.

```powershell
python scripts/promote_mfds_easy_drug.py promote `
  --staged-dir data/easy-drug/staged/20260901T061358Z-schema-v1 `
  --packet-dir data/easy-drug/review-packets/MFDS-EASY-PILOT-001 `
  --decisions-file data/easy-drug/review-packets/MFDS-EASY-PILOT-001/review_decisions.completed.json `
  --approval-id MFDS-EASY-PILOT-001-APPROVED
```

승격 도구는 다음 조건에서 실패한다.

- `pending` 또는 누락된 품목·근거 결정이 있음
- 승인 역할에 `pharmacist` 또는 `physician`이 없음
- 검수자 자격 확인 기록 또는 이용권리 검수가 완료되지 않음
- 품목 식별이 확인되지 않았는데 그 품목의 근거를 승인함
- 승인 근거의 허용 용도가 비었거나 섹션 허용 범위를 벗어남
- 거절 근거의 사유가 없음
- staged, 검수 패킷 또는 결정 대상 ID가 달라짐
- 파일 크기 또는 SHA-256이 manifest와 달라짐
- 승인된 근거 조각이 0건임
- 기존 출력 경로를 덮어쓰려고 함

승인 결과에는 승인된 품목과 근거 조각만 들어가며, 원문 제목·발행기관·개정일·항목 위치·근거문장·원문 링크·앱 검수일·검수 역할·다음 재검수일을 함께 보존한다.

## 6. 승인 이후 남는 게이트

`approved_snapshot` 생성 뒤에도 다음 작업이 남는다.

1. 승인된 조각만 사용하는 검색 인덱스 생성
2. 인덱스의 문서·조각 ID와 원문 해시 일치 검사
3. 주장별 자료명·발행기관·개정일·위치·근거문장·링크·검수일 표시 검사
4. 근거 밖 의학적 핵심 주장 0건, 고위험 오류 0건 회귀시험
5. 근거 부족·충돌 질문의 보류 시험
6. 모바일 배포 크기와 로컬 검색 성능 검증
7. 별도 release manifest를 통한 명시적 활성화와 철회 절차

이 게이트를 통과하기 전에는 승인 스냅샷을 앱의 운영 RAG 또는 모바일 번들로 사용하지 않는다.

승인 스냅샷은 운영 활성화 전에 [`Evaluation Scenario Compiler`](./evaluation_scenario_compiler.md)의 `DS_AGENT_evidence_source`로 사용할 수 있다. 이 사용은 평가 후보 생성에 한정되며, 생성된 episode도 별도의 라벨·근거 적용 검수를 통과하기 전에는 점수 보고용 평가 데이터가 아니다.
