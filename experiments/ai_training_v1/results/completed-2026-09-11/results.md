# 추가 학습·증류 개발 실험 결과

모든 수치는 로컬 개발 실험이다. 실패·중단 실행을 0점 또는 완료로 처리하지 않는다.

OCR/ASR 점수는 정답을 기준으로 재계산했다. 초기 실행의 전사 평가 함수 인자 순서 오류가 있는 원본 summary는 이력으로 보존하고, 아래 표와 results.json의 verification.recomputed_media_artifacts.metrics에 수정한 값을 기록한다.

| 실행 | 상태 | 학습/검증 결과 |
|---|---|---|
| asr-small-lora-v1 | completed | 시험 CER 0.141131 → 0.094874; 원문 일치 0 → 0 |
| chat-2b-distill-v1 | completed | 286건, 72 update; loss 0.4268 → 0.0001 |
| chat-2b-sft-v1 | completed | 300건, 76 update; loss 0.8955 → 0.0008 |
| chat-base-baseline-heldout-v1 | completed | 조회 일치 89/100; 별도 조건 추출 정답 없음 |
| chat-base-test-v1 | completed | 조건 일치 111/200; 조회 일치 149/200 |
| chat-base-validation-v1 | completed | 조건 일치 82/100; 조회 일치 89/100 |
| chat-distill-baseline-heldout-v1 | completed | 조회 일치 100/100; 별도 조건 추출 정답 없음 |
| chat-distill-test-v1 | completed | 조건 일치 200/200; 조회 일치 200/200 |
| chat-distill-validation-v1 | completed | 조건 일치 100/100; 조회 일치 100/100 |
| chat-sft-baseline-heldout-v1 | interrupted | Desktop turn interruption; recorded process 27760 is absent. Partial output preserved and excluded; retry uses a new run ID. |
| chat-sft-baseline-heldout-v2 | completed | 조회 일치 100/100; 별도 조건 추출 정답 없음 |
| chat-sft-test-v1 | completed | 조건 일치 172/200; 조회 일치 176/200 |
| chat-sft-validation-v1 | completed | 조건 일치 100/100; 조회 일치 100/100 |
| chat-teacher4b-train300 | failed | KeyError |
| chat-teacher4b-train300-v2 | interrupted | User turn interruption terminated executor; original process 28872 absent; 32 partial predictions excluded from comparison |
| chat-teacher4b-train300-v3 | completed | 조건 일치 286/300; 조회 일치 298/300 |
| ocr-ko-head-sft-v1 | failed | ValueError |
| ocr-ko-head-sft-v2 | completed | 시험 CER 0.000000 → 0.000000; 원문 일치 62 → 76 |
| ocr-multi-head-sft-v1 | completed | 시험 CER 0.000000 → 0.000000; 원문 일치 105 → 149 |

원본·adapter/체크포인트 해시, 언어별 지표, 학습 설정과 실행 환경은 results.json에 보관한다.
