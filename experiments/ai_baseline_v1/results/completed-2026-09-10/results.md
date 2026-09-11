# AI baseline V1 — 자동 개발 진단

의료 정확도 또는 모바일 성능 검증이 아니다. 실행 오류와 모델의 오답을 분리한다.

| Run | 상태 | N | 과업 정확/문자 오류율 | 평균 초 | GPU peak GiB |
|---|---|---:|---:|---:|---:|
| chat-qwen35-2b-screen40 | completed | 40 | 7/40 | 3.773 | 1.935 |
| chat-qwen35-4b-screen40 | completed | 40 | 22/40 | 2.565 | 3.452 |
| chat-gemma4-e2b-screen40 | completed | 40 | 1/40 | 6.965 | 6.480 |
| chat-qwen35-2b-grammar40 | completed | 40 | 10/40 (진단/이력 — 채택 비교 제외) | 12.628 | 1.935 |
| chat-gemma4-e2b-grammar40 | completed | 40 | 1/40 (진단/이력 — 채택 비교 제외) | 5.531 | 6.480 |
| chat-qwen35-2b-grammar-eos-fixed40 | completed | 40 | 10/40 | 4.645 | 1.935 |
| chat-gemma4-e2b-grammar-eos-fixed40 | completed | 40 | 1/40 | 5.663 | 6.480 |
| chat-qwen35-2b-filter200 | completed | 200 | 195/200 | 2.713 | 1.949 |
| chat-qwen35-4b-filter40 | completed | 40 | 40/40 | 3.884 | 3.483 |
| ocr-ppocr5-ko-dev80 | failed | 0 | 미완료 — 성능 비교 제외 | — | — |
| ocr-ppocr5-multi-dev160 | failed | 0 | 미완료 — 성능 비교 제외 | — | — |
| ocr-ppocr5-ko-cache-fixed80 | completed | 80 | CER 0.0000 | 2.351 | — |
| ocr-ppocr5-multi-cache-fixed160 | completed | 160 | CER 0.0284 | 2.474 | — |
| ocr-ppocr5-ko-mkldnn80 | failed | 3 | 미완료 — 성능 비교 제외 | — | — |
| asr-whisper-base-validation203 | completed | 203 | CER 0.2208 | 0.390 | 0.169 |
| asr-whisper-small-validation203 | completed | 203 | CER 0.1203 | 0.685 | 0.521 |
| asr-qwen3-06b-validation203 | completed | 203 | CER 0.0950 | 2.888 | 1.686 |
| asr-qwen3-latency-recheck3 | completed | 3 | CER 0.0174 (진단/이력 — 채택 비교 제외) | 3.905 | 1.584 |

CER은 NFC·소문자·공백만 정규화하며 문장부호/소수점은 보존한다. 공백 단위 WER은 CJK 언어 간 순위에 사용하지 않는다. 무음의 삽입 문자는 CER 분모에 섞지 않고 별도 집계한다.

언어별 결과·실행 설정·입력/모델/코드 해시는 results.json과 해당 실행 manifest.json을 참조한다.
