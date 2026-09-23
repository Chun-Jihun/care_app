"""Package an existing, verified preview set for bounded offline installation.

The descriptor is pinned in the DEBUG app; this is not clinical approval.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import struct


def build(source: Path, output: Path, descriptor: Path, version: str) -> dict:
    if output.exists() or descriptor.exists():
        raise FileExistsError('use new version paths; retain prior pinned descriptors')
    root = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))
    if root.get('schema') != 'care-mobile-core-set-v1' or any(
        root.get(k) != v for k, v in {
            'purpose': 'development_preview', 'approval_state': 'staged_unreviewed',
            'clinical_review_completed': False, 'runtime_rag_eligible': False,
            'mobile_bundle': False, 'do_not_train': True,
        }.items()
    ):
        raise ValueError('only unreviewed development sets supported')
    if set(root['packages']) != {'dur', 'permits', 'easy-drug', 'documents'}:
        raise ValueError('unexpected package set')
    files = []
    names = ['manifest.json'] + [
        f'{kind}/{name}' for kind in sorted(root['packages'])
        for name in ['manifest.json', 'knowledge.sqlite3']
    ]
    for name in names:
        file = source / name
        if file.is_symlink() or not file.is_file():
            raise ValueError('invalid file')
        with file.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if '/' in name:
            kind, leaf = name.split('/')
            package = root['packages'][kind]
            key = 'manifest_sha256' if leaf == 'manifest.json' else 'database_sha256'
            if package['directory'] != kind or digest != package[key]:
                raise ValueError('set checksum mismatch')
        files.append({'path': name, 'bytes': file.stat().st_size, 'sha256': digest})
    if sum(f['bytes'] for f in files) > 50 * 1024 * 1024:
        raise ValueError('set exceeds budget')
    now = dt.datetime.now(dt.timezone.utc)
    value = {'schema': 'care-knowledge-delivery-v1', 'version': version,
             'preview': True, 'checked_at': now.isoformat(),
             # Technical recheck interval, NOT a clinical review date.
             'recheck_after': (now + dt.timedelta(days=90)).isoformat(), 'files': files}
    raw = json.dumps(value, ensure_ascii=False, indent=2).encode('utf-8')
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = output.with_suffix(output.suffix + '.partial')
    if stage.exists():
        raise FileExistsError(stage)
    try:
        with stage.open('xb') as target:
            target.write(b'CAREKB01' + struct.pack('<I', len(raw)) + raw)
            for name, expected in zip(names, files):
                copied = 0
                digest = hashlib.sha256()
                with (source / name).open('rb') as data:
                    while block := data.read(1024 * 1024):
                        target.write(block)
                        digest.update(block)
                        copied += len(block)
                if copied != expected['bytes'] or digest.hexdigest() != expected['sha256']:
                    raise ValueError('source changed during packaging')
        stage.rename(output)
    finally:
        stage.unlink(missing_ok=True)
    descriptor.parent.mkdir(parents=True, exist_ok=True)
    descriptor.write_bytes(raw)
    return {'bytes': output.stat().st_size, 'version': version,
            'id': hashlib.sha256(raw).hexdigest(), 'preview': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--descriptor', type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output, args.descriptor, args.version)))
