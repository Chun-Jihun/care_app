# 로컬 추가 학습·증류 파일럿

2026-09-10 사용자 요청에 따라 시작한다. 이 문서는 실행 전에 고정하는 실험 범위와 실패 조건이다.

## 범위

- 실제 환자 자료·대화·처방전·진료 녹음은 사용하지 않는다. 앱과 승인 의료 지식베이스는 변경하지 않는다.
- 모든 산출물은 `evaluation_eligible=false`, `medical_release_gate_result=false`인 개발 실험이다.
- 챗봇: Qwen3.5-2B의 QLoRA 지도학습과 Qwen3.5-4B의 검증된 출력 기반 증류를 별도 adapter로 실행한다. 모델 입력은 질문뿐이며 날짜·시간·항목 추출과 의료 질문 보류가 과업이다. 의료 지식이나 처방 결정을 학습하지 않는다.
- OCR: PP-OCRv5 mobile 인식기의 학습용 가중치·공식 학습 경로를 확인하고, 정답이 직접 생성된 새로운 합성 행 이미지로 인식기 미세조정을 시험한다. 검출기와 실제 처방전 품질을 검증했다고 표현하지 않는다.
- ASR: Whisper small의 공개 음성 train 분할을 이용한 소규모 미세조정을 시험한다. 이전 validation 음성을 학습하지 않는다. 진료실/약명 전문 성능으로 해석하지 않는다.
- 증류 교사는 정답과 대조하여 선택한다. 큰 모델이라는 이유만으로 정답을 승인하지 않는다. 출력 기반 증류와 logit 기반 증류를 구분한다.

## 실행 전 실패 조건

| 실패 | 검사/처리 |
|---|---|
| 학습·검증·시험 자료 중복 | 질문·원본/그룹·파일 해시의 교집합을 검사하고 실행 차단. 공개 음성 원문의 언어 간 중복도 분할 수준에서 검사 |
| 평가 정답이 모델 입력 또는 loss에 섞임 | 추론에는 질문/미디어만 전달. 학습 loss는 학습 분할의 정답 token만 사용. prompt/padding은 -100 |
| 교사가 조건·숫자·부정을 바꿈 | 결정적 정답과 필드별 대조. 틀린 출력은 증류 corpus에서 제외하고 탈락률 공개 |
| 학습이 실제로 되지 않음 | 유한 loss, 유한/비영 gradient, adapter 가중치 변경과 reload 후 추론 검사 |
| OOM/NaN/중도 실패 | 완료로 기록하지 않음. 실패 로그·설정 보존, 더 작은 batch/sequence로 별도 실행 ID |
| 결과를 보고 시험 데이터에 맞춤 | validation만 설정 선택에 사용. test 개봉 후의 수정은 탐색 결과로 별도 표시 |
| 의료 답변·다른 수첩·원문 변조 | 기존 안전/계약 회귀시험 실행. 자동 결과로 의료 출시 승인하지 않음 |
| 원본 가중치/기존 평가 덮어쓰기 | 새 디렉터리·adapter/체크포인트만 저장, 입력/가중치/코드 해시 기록 |
| 외부 전송/원격 코드 | 공개 다운로드와 offline 학습 분리. 외부 교사 API·원격 로깅 비활성, Python network audit 사용 |

## 최초 비교 설계

챗봇은 새로운 다섯 언어 합성 자료를 생성하며 train/validation/test의 기록 식별자와 날짜·질문 템플릿을 분리한다. 템플릿 기반 자료라는 한계는 유지한다. 미세조정은 정답 전체 학습, 증류는 교사 출력 중 정답 계약을 통과한 부분을 학습한다. 두 arm의 데이터 양/선택 차이를 보고하며 순수한 학습 알고리즘 우열로 해석하지 않는다. 교사 출력의 원문 표기를 보존하므로 단순히 정답 파일을 복제한 것을 증류라고 부르지 않는다.

학습 전 모델, 지도학습 adapter, 증류 adapter를 같은 prompt/decoder/후처리/test로 비교한다. 조건 추출 정확도와 host가 표시한 기록 정확도를 구분한다. 기존 기준선 자료는 학습하지 않고 회귀 확인에만 사용한다. OCR/ASR도 학습 전후 같은 평가 입력/지표를 사용하고 무음·숫자·단위·부정을 별도로 보고한다.

PC 자원은 RTX 3060 Ti 8GB다. GPU 작업은 순차 실행한다. 결과가 나빠지면 원본 모델을 유지하고 실패를 그대로 보고한다. 이번 파일럿은 모바일 변환/실기기 검증을 포함하지 않는다.

## 참고한 공식 자료

- [PEFT integration](https://huggingface.co/docs/transformers/peft)
- [PEFT LoRA](https://huggingface.co/docs/peft/developer_guides/lora)
- [PaddleOCR recognition training](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/module_usage/text_recognition.md)
- [FLEURS source and train/dev/test split](https://huggingface.co/datasets/google/fleurs)

실행 설정, 설치 버전, 데이터 출처·권리, 실제 건수와 결과는 후속 manifest/report에 고정한다.

## 실행 프로필 보충 (2026-09-11)

- 사용자는 GPU를 사용하는 다른 프로그램을 계속 사용해야 한다고 응답했다. 그 프로그램을 종료하지 않으며 GPU 작업은 순차 실행한다. 재시작한 챗봇 및 ASR 프로세스의 PyTorch allocator 상한은 GPU 메모리의 50%, CPU thread는 2다. 이 상한은 드라이버 전체 GPU 점유율이나 실행 속도를 보장하지 않는다.
- 챗봇은 train 300 / validation 100 / test 200건이다. 2B NF4 기반, BF16 연산, 텍스트 층 LoRA rank 8 / alpha 16, dropout 0, batch 1, gradient accumulation 8, 2 epochs, 학습률 1e-4다. prompt를 loss에서 제외하고 모델의 실제 종료 token을 학습한다. embedding/vision은 학습하지 않는다.
- OCR은 전체 train 400 / validation 100 / test 200행 중 해당 인식기의 언어만 사용한다. 한국어 인식기는 ko/en, 다국어 인식기는 en/ja/zh-Hans/zh-Hant다. 검출기·backbone·CTC encoder를 고정하고 최종 CTC 문자 분류 head만 CPU에서 학습한다. 특징 추출은 정답을 사용하지 않으며, batch 8, 3 epochs, Adam 1e-4로 사전 고정했다. 원본/학습본 모두 같은 resize/decoder로 비교한다.
- ASR은 일반 공개 train 발화 400 + 무음 12, validation 발화 80, test 발화 120 + 무음 12다. 원래 공개 validation 전체의 문장 ID/정규화 전사와 겹치는 train 예시는 제외했다. local validation/test는 문장 ID의 해시 홀짝으로 나눴다. 기존에 평가한 음성과 같은 언어의 문장 ID는 제외했지만 다른 언어의 병렬 번역을 이전에 평가했을 가능성은 남는다. 두 평가 부분 사이의 화자 독립성은 확보된 메타데이터로 입증하지 못한다.
- Whisper small은 q_proj/v_proj LoRA rank 8 / alpha 16, dropout 0, batch 1, gradient accumulation 4, 2 epochs, AdamW 5e-5로 시작한다. 언어/작업 prefix는 decoder 입력에 유지하고 loss에서 제외하며, 원문 전사와 종료 token만 학습한다. 무음 train/test는 길이가 다른 합성 대조군으로 독립적인 음성 표본으로 집계하지 않는다.
- Whisper의 길이 채움 뒤에는 길이가 다른 완전 무음도 동일한 mel 특징이 될 수 있다. 특징 해시 중복을 검사하고 무음에서 허용한 중복은 실행 결과에 명시한다. 일반 발화의 분할 간 특징 중복은 차단한다. 무음 결과는 학습한 대조군 확인이며 미관측 환경의 일반화 시험으로 해석하지 않는다.
- 챗봇의 학습 후 비교는 원본/SFT/증류 모델에 동일한 batch 4, 왼쪽 padding, greedy decoder를 적용한다. 학습 batch는 계속 1이다. batched 측정 시간은 각 묶음 전체가 끝날 때까지의 시간이며 단일 질문 지연이나 모바일 속도로 비교하지 않는다.
- OCR/ASR은 고정한 학습률·epoch의 최종 가중치로 비교한다. test의 학습 전 결과를 보고 설정을 조정하지 않는다. 결과가 나빠지면 배포 후보로 채택하지 않는다.
- 실행 중 대화가 중단되어 Qwen 4B의 32개 부분 출력은 `interrupted`로 제외했다. ASR 준비 중 부분 디렉터리도 별도 보존했다. 최초 4B 자산 참조와 OCR bytecode cache 허용 경로 오류는 학습 전에 실패했으며 새 실행 ID로 수정했다.
- 별도 검수 없는 합성 의료 질문 보류 시험과 기존 Python 안전/계약 회귀시험만 수행할 수 있다. 임상 회귀시험을 통과했다는 의미가 아니다.

## 실행 파일과 재현

학습·평가를 완료했으며 실제 결과는 [추가 학습·증류 결과 문서](../../docs/ai_training_results_2026-09-11.md)와 [봉인한 결과](results/completed-2026-09-11/results.md)를 따른다. 아래 명령은 프로젝트 루트의 PowerShell에서 사용하는 단계다. 기존 입력·실행 ID·결과 폴더가 있으면 덮어쓰지 않고 종료한다. 재실험은 별도 작업 디렉터리나 새로운 실행 ID로 수행한다.

실험 Python은 `.tools/ai-training-venv/Scripts/python.exe`다. PEFT 0.20.0을 별도 환경에 설치하고, 기존 `.tools/ai-baseline-venv`와 `.venv-qwen35`의 패키지를 `.pth`로 읽는다. 이 PC의 환경을 수정 없이 격리해 사용하기 위한 방식이며 독립적인 배포 환경이 아니다. 다른 PC에서는 [실제 활성 패키지 버전](training-environment.json)에 맞는 새 환경과 동일 CUDA/Paddle 구성을 준비해야 한다. 초기 실행 메타데이터의 중복 numpy 배포판 표시는 결과 JSON의 설명을 함께 참조한다.

1. 공개 자산 준비: `python -m scripts.prepare_ai_training_assets --task ocr`, `--task asr`. 이 단계만 공개 다운로드를 수행한다. Qwen/Whisper와 FLEURS validation 원본은 이전 기준선의 자산 잠금을 사용한다.
2. 새 입력 봉인: `python -m scripts.prepare_ai_training_chat`, `python -m scripts.prepare_ai_training_ocr`, `python -m scripts.prepare_ai_training_asr`.
3. 음성 특징을 CPU에서 준비: `python -m scripts.ai_training_asr_features`. 학습 정답 token은 train에 대해서만 저장한다.
4. 교사 생성: `python -m scripts.run_ai_training_chat --action teacher --model qwen35_4b --split train --run-id chat-teacher4b-train300-v3`.
5. 챗봇 SFT·증류 순차 학습: `python -m scripts.queue_ai_training --phase chat-train`. 각 arm은 동일한 새 2B 기반 모델에서 시작한다.
6. OCR 학습: `python -m scripts.run_ai_training_ocr --model ko --run-id ocr-ko-head-sft-v2`, 이어서 `--model multi --run-id ocr-multi-head-sft-v1`.
7. 음성 학습·비교: `python -m scripts.queue_ai_training --phase asr`.
8. 챗봇 원본/SFT/증류 비교: `python -m scripts.queue_ai_training --phase chat-evaluate`.
9. 계약 회귀시험: `python -m unittest discover -s tests`. 결과 봉인: `python -m scripts.report_ai_training --report-id <새 ID>`.

`python`은 위 실험 환경의 실행 파일로 바꾸어 호출한다. GPU를 쓰는 4·5·7·8번은 동시에 실행하지 않는다. OCR은 CPU에서 처리할 수 있다. 기반 모델의 설정·사전·전처리·revision과 새 adapter/head가 모두 있어야 재추론할 수 있다. 가중치를 앱에 연결하거나 독립적인 모바일 모델로 내보내는 명령은 포함하지 않는다.

8번 실행 도중 대화 중단으로 SFT의 이전 heldout 평가가 88/100에서 멈췄다. 해당 실행은 `interrupted`로 보존하고 `python -m scripts.run_ai_training_chat --action evaluate --split baseline-heldout --batch-size 4 --adapter chat-2b-sft-v1 --run-id chat-sft-baseline-heldout-v2`로 전체 100건을 재실행했다. 이어서 `--adapter chat-2b-distill-v1 --run-id chat-distill-baseline-heldout-v1`로 마지막 증류 평가를 완료했다. 학습을 다시 수행하거나 부분 점수를 합산하지 않았다.

원본 데이터/새 가중치는 Git에서 제외한 `data/ai-training-v1/`에, 코드·설정·출처와 집계는 저장소의 `scripts/`와 이 디렉터리에 있다. `runs/<실행 ID>/summary.json`과 `source/`, `loss.jsonl`, `adapter/` 또는 `ctc-head.pdparams`, 원본 예측 JSONL을 함께 보관한다. 결과 생성기는 가중치·코드 해시와 학습 로그를 검사하고, 예측을 봉인된 정답에 다시 대조하여 집계를 확인한다. OCR 초기 실행에 없던 개별 예측 파일 해시는 이 결과 생성 시점에 함께 기록한다.

초기 OCR/ASR 평가 함수 호출은 정답·예측 인자가 반대로 전달되어 CER 분모와 무음 메타데이터에 오류가 있었다. 실행 이력은 보존한다. 현재 runner는 인자 이름을 명시한 `reference-first-v2`를 사용하고, 결과 생성기는 원래 점수의 계산 방식까지 검증한 후 같은 원본 출력으로 수정 점수를 계산한다. 최종 매체 지표는 `verification.recomputed_media_artifacts.metrics`와 결과 표를 따른다. 학습, 전사 출력, 고정 epoch/학습률은 이 수정으로 변경하지 않는다.
