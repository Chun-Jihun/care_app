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
ANDROID = '{http://schemas.android.com/apk/res/android}'
APPLICATION_ID = 'org.carenotebook.care_notebook'
RELEASE_PERMISSIONS = {
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.RECEIVE_BOOT_COMPLETED',
    'android.permission.RECORD_AUDIO',
    'android.permission.USE_BIOMETRIC',
    'android.permission.USE_FINGERPRINT',
    'android.permission.VIBRATE',
    f'{APPLICATION_ID}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
}
AD_NAMESPACES = (
    'com.google.ads',
    'com.google.android.ads',
    'com.google.android.gms.ads',
    'com.google.android.libraries.ads',
)


def audit_android_release(directory):
    manifest_path = directory / 'AndroidManifest.xml'
    manifest = ET.parse(manifest_path).getroot()
    application = manifest.find('application')
    if (manifest.tag != 'manifest' or manifest.get('package') != APPLICATION_ID
            or application is None or application.get(f'{ANDROID}debuggable') == 'true'):
        raise ValueError('Expected the packaged release manifest for the notebook app')

    permissions = {
        node.attrib[f'{ANDROID}name'] for node in manifest
        if node.tag == 'uses-permission' or node.tag.startswith('uses-permission-sdk-')
    }
    unexpected = permissions - RELEASE_PERMISSIONS
    if unexpected:
        raise ValueError(f"Unapproved Android release permissions: {', '.join(sorted(unexpected))}")

    ad_manifest_prefixes = tuple(namespace + '.' for namespace in AD_NAMESPACES)
    ad_components = {
        value for node in manifest.iter() for value in node.attrib.values()
        if value.startswith(ad_manifest_prefixes)
        or value.endswith('.PublicHelpTestActivity')
        or value == 'android.adservices.AD_SERVICES_CONFIG'
    }
    dependency_lines = (directory / 'runtime-dependencies.txt').read_text(encoding='utf-8').splitlines()
    dependencies = sorted(line.strip() for line in dependency_lines if line.strip())
    if not dependencies:
        raise ValueError('Missing resolved Android release dependencies')
    local_inventory = directory / 'runtime-local-files.txt'
    if not local_inventory.is_file():
        raise ValueError('Missing Android release local file inventory')
    local_files = local_inventory.read_text(encoding='utf-8').splitlines()
    if local_files:
        raise ValueError(f"Unapproved Android release local file dependencies: {', '.join(local_files)}")
    ad_dependency_prefixes = (
        'com.google.android.gms:play-services-ads',
        *ad_manifest_prefixes,
        *(namespace + ':' for namespace in AD_NAMESPACES),
    )
    ad_dependencies = {
        dependency for dependency in dependencies
        if dependency.startswith(ad_dependency_prefixes)
        or dependency in {'project :ad-test', 'project :google_mobile_ads'}
    }
    if ad_components or ad_dependencies:
        raise ValueError(f"Ads found in Android release: {', '.join(sorted(ad_components | ad_dependencies))}")
    return dict(status='passed', permissions=sorted(permissions),
        runtime_dependencies=dependencies, manifest_sha256=sha(manifest_path))


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
    parser.add_argument('--output', type=Path, help='JSON path for the full evidence audit')
    parser.add_argument('--android-release-dir', type=Path, help='Directory generated by :app:prepareReleaseAudit')
    parser.add_argument('--android-only', action='store_true', help='Check Android release configuration for CI')
    args = parser.parse_args()
    if args.android_only:
        if args.android_release_dir is None:
            parser.error('--android-only requires --android-release-dir')
        android = audit_android_release(args.android_release_dir)
        print(json.dumps(dict(android_release_status=android['status'],
            permissions=android['permissions'], dependencies=len(android['runtime_dependencies']))))
        return
    if args.output is None:
        parser.error('--output is required for the full evidence audit')
    if args.output.exists():
        raise ValueError('Do not overwrite an audit; select a new output')
    android = audit_android_release(args.android_release_dir) if args.android_release_dir else dict(status='not_checked')
    packages = {kind: audit_package(args.package / kind) for kind in ['documents', 'dur', 'permits', 'easy-drug']}
    result = dict(schema='care-release-audit-v2', audit_generated_at=datetime.now(timezone.utc).isoformat(),
        source_policy_checked_date='2026-09-23', medical_release_gate_result=False,
        release_platforms=['android'], deferred_platforms=['ios'],
        packages=packages, media=media_diagnostics(), android_release=android,
        blockers=[
          'clinical source/target-population/exception review incomplete',
          'publication or revision metadata incomplete; collection date is not a publication date',
          'source-specific redistribution/image rights and required notices not approved',
          'NHS offline refresh/attribution policy requires a release decision',
          'independent clinical retrieval and answer evaluation not performed',
          'real camera, medication-label, caregiver speech and critical-token quality evaluation pending',
          'release signing and store declarations require owner credentials/details',
          'Android device, long-duration, memory/battery and update testing deferred to pre-release',
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
        android_release_status=android['status']), ensure_ascii=False))


if __name__ == '__main__':
    main()
