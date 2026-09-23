# PC validation before device release testing

Public source packages and synthetic fixtures only. Technical quality measurements are not clinical review. Device, long-running, migration-on-device and iOS validation remain pending until release preparation.

`mobile/tool/evaluate_knowledge.dart` measures retrieval separately and exports the exact application evidence-selection prompt. `scripts/evaluate_evidence_selector.py` executes these prompts with the existing CPU GGUF (two threads). `scripts/audit_mobile_release.py` audits metadata and release blockers without approving sources.

2026-09-23 observations:

- Retrieval development cases improved from 5/10 to 10/10 topic matches at 3. These cases informed the aliases and are not an independent test set. Two uncovered topic probes returned no results.
- The initial `selector-invalid-log-suppressed.json` is an invalid measurement: llama's `--log-disable` also suppresses completion output. Do not use its scores.
- The corrected shared prompt disables thinking output using the same suffix as the existing local Qwen template. The CPU selection run scored 5/6. An unsupported synthetic price question still selected an ID; the host's reviewed-question authorization remains mandatory.
- The KO ONNX recognizer alone scored 100/100 normalized exact on synthetic line images (20 texts × 5 transformations). This excludes detection, actual camera images, handwriting and clinical generalization.
- Rescoring archived native outputs yielded OCR 19/20 and speech 1/4 normalized exact; one speech case changed numeric/unit content. This is not a new device run.
- Source audit: 13 documents, 30 pages, 11 medication source operations. Original hashes for all 13 documents match. Basic text integrity checks passed. Publication metadata, rights, target population, extraction semantics and clinical review remain pending.
- Real local catalog probe: seven partial-name product candidates, 631 DUR rows for two product codes, expected bidirectional pair present, and clinical lookup of unreviewed data rejected. No real product was added to an app notebook.

Further training should use newly curated, independently held-out insufficient-evidence cases and confirmed speech numeric/unit/negation errors. Do not train on the unreviewed reference package or interpret these development examples as release evidence. OCR needs camera/document detection evaluation before choosing another training change.
