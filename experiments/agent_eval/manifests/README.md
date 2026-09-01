# 에이전트 실험 자산 lock

이 디렉터리는 로컬 모델과 평가·RAG 원천데이터의 출처 선언 및 실제 바이트 무결성 lock을 보관한다.

## 파일

- `asset_sources.json`: 출처, 이용조건 확인 상태, 실험 역할, 학습·모바일·RAG 사용 정책
- `models.lock.json`: 모델 revision과 `.cache`를 제외한 개별 파일 SHA-256
- `data_sources.lock.json`: 데이터별 전체 content-tree SHA-256, 파일 수, 용량과 승인 상태

공개 벤치마크는 모두 `do_not_train=true`, `mobile_bundle=false`, `runtime_rag_eligible=false`이다. e약은요 raw snapshot도 내부 검수·승인 전까지 같은 제한을 유지한다. `missing` 자산은 현재 파일시스템에 없다는 뜻이며 다운로드 완료로 해석하지 않는다.

## 생성과 검증

다음 명령은 네트워크에 접근하지 않고 현재 로컬 파일을 모두 읽어 lock을 갱신한다.

```powershell
python -X utf8 scripts/freeze_asset_manifests.py --hash-workers 4
```

기존 lock과 현재 파일이 같은지 확인하려면 다음을 실행한다.

```powershell
python -X utf8 scripts/freeze_asset_manifests.py --verify --hash-workers 4
```

MIRAGE 전체 검증은 약 110GiB를 읽으므로 시간이 오래 걸린다. 모델·데이터를 의도적으로 교체하거나 수정한 경우에만 출처 선언을 먼저 검토한 뒤 lock을 갱신한다. 평가 결과에는 사용한 `models.lock.json`과 `data_sources.lock.json`의 SHA-256도 함께 기록한다.

## content-tree SHA-256

데이터 디렉터리의 각 파일에 대해 아래 JSONL 레코드를 결정적 경로 순서로 연결하고 다시 SHA-256한다.

```text
[relative_posix_path, byte_length, file_sha256]
```

`.git`, `.cache`, `__pycache__`, `.env`, `.env.*`, 임시 파일과 운영체제 메타파일은 입력에서 제외한다. 절대경로와 인증정보는 lock에 기록하지 않는다.
