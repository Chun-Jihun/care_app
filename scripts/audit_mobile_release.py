"""Reproducible local evidence audit. No secrets, API calls, or clinical promotion."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from scripts.knowledge_pack import PackReader

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def audit_package(directory):
    reader = PackReader(directory)
    try:
        sources = []
        for row in reader.db.execute('SELECT id,metadata FROM sources ORDER BY id'):
            data = json.loads(row['metadata'])
            original = (ROOT / data['path']).resolve() if data.get('path') else None
            if original is not None and not original.is_relative_to((ROOT / 'docs').resolve()):
                raise ValueError('Source original must remain within docs/')
            sources.append(dict(id=row['id'], title=data['title'], publisher=data['publisher'],
                url=data.get('url'), original_matches=sha(original) == data.get('source_sha256') if original and original.is_file() else None,
                published=data.get('publication_or_revision_date'), collected=data.get('collected_at'),
                clinical_reviewed_at=data.get('clinical_reviewed_at'),
                license_review_status=data.get('license_review_status', 'pending'),
                extraction_review_status=data.get('extraction_review_status', 'pending'),
                intended_population_review='pending', current_remote_version_verified=False))
        pages = []
        for row in reader.db.execute('SELECT * FROM document_pages ORDER BY source_id,page_no'):
            text = reader.blob(row['text_blob']).decode('utf-8')
            if hashlib.sha256(text.encode('utf-8')).hexdigest() != row['text_sha256']:
                raise ValueError('Document text mismatch')
            pages.append(dict(source_id=row['source_id'], page=row['page_no'], characters=len(text),
                empty=not bool(text.strip()), replacement_characters=text.count('\ufffd'),
                suspicious_controls=sum(ord(c) < 32 and c not in '\n\r\t' for c in text),
                # A warning for manual visual review, never a reconstructed sentence.
                spaced_letters=bool(re.search(r'(?:\b[A-Za-z] ){5}', text))))
        return dict(database_sha256=reader.manifest['database_sha256'],
            bytes=reader.manifest['database_bytes'], records=reader.manifest['stats']['records'],
            clinical_review_completed=reader.manifest['clinical_review_completed'], sources=sources, pages=pages)
    finally:
        reader.close()


def media_diagnostics():
    """Rescore archived native outputs; do not label this a new device execution."""
    from scripts.ai_baseline_metrics import strict_critical_tokens
    from scripts.summarize_mobile_ai_validation import distance, normalized
    path = ROOT / 'experiments/mobile_ai_v1/android-native-smoke.json'
    raw = json.loads(path.read_text(encoding='utf-8'))
    groups = {}
    for task in ['ocr', 'speech', 'silence']:
        rows = [row for row in raw['checks'] if row['task'] == task]
        details = []
        for row in rows:
            reference, prediction = row.get('reference', ''), row.get('output', '')
            left, right = normalized(reference), normalized(prediction)
            details.append(dict(id=row['id'], exact=left == right,
                edits=distance(left, right), characters=len(left),
                numbers_units_preserved=strict_critical_tokens(reference) == strict_critical_tokens(prediction),
                nonempty_output=bool(right)))
        groups[task] = dict(cases=len(details), exact=sum(r['exact'] for r in details),
            characters=sum(r['characters'] for r in details), edits=sum(r['edits'] for r in details),
            numbers_units_mismatches=sum(not r['numbers_units_preserved'] for r in details), cases_detail=details)
    return dict(execution='rescored archived 2026-09-11 native outputs; not a new device run',
        report_sha256=sha(path), quality_gate_passed=False, groups=groups)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, default=ROOT / 'data/knowledge-preview/mobile-core-v2-small')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Do not overwrite an audit; select a new output')
    packages = {kind: audit_package(args.package / kind) for kind in ['documents', 'dur', 'permits', 'easy-drug']}
    android = ET.parse(ROOT / 'mobile/android/app/src/main/AndroidManifest.xml').getroot()
    attr = '{http://schemas.android.com/apk/res/android}name'
    permissions = sorted(node.attrib[attr] for node in android.findall('uses-permission'))
    result = dict(schema='care-release-audit-v1', audit_generated_at=datetime.now(timezone.utc).isoformat(),
        source_policy_checked_date='2026-09-23', medical_release_gate_result=False,
        packages=packages, media=media_diagnostics(), android_main_permissions=permissions,
        blockers=[
          'clinical source/target-population/exception review incomplete',
          'publication or revision metadata incomplete; collection date is not a publication date',
          'source-specific redistribution/image rights and required notices not approved',
          'NHS offline refresh/attribution policy requires a release decision',
          'independent clinical retrieval and answer evaluation not performed',
          'real camera, medication-label, caregiver speech and critical-token quality evaluation pending',
          'release signing and store declarations require owner credentials/details',
          'Android/iOS device, long-duration, memory/battery and update testing deferred to pre-release',
          'iOS native AI runtime and privacy manifests need Mac/Xcode verification',
        ],
        source_policy_references={
          'NHS': 'https://www.nhs.uk/our-policies/terms-and-conditions/',
          'CDC': 'https://www.cdc.gov/other/agencymaterials.html',
          'AHRQ': 'https://www.ahrq.gov/policy/electronic/disclaimers/index.html',
          'NIDCR': 'https://www.nidcr.nih.gov/about-us/web-policies',
          'NIA': 'https://www.nia.nih.gov/about/policies',
          'DUR': 'https://www.data.go.kr/data/15059486/openapi.do',
          'permits': 'https://www.data.go.kr/data/15095677/openapi.do',
        })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(source_counts={k: len(v['sources']) for k, v in packages.items()},
        document_pages=len(packages['documents']['pages']), clinical_release=False,
        android_internet='android.permission.INTERNET' in permissions), ensure_ascii=False))


if __name__ == '__main__':
    main()
