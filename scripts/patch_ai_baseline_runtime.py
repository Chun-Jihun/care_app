"""One pinned, local-venv compatibility patch; never edits the original environment."""
from scripts.ai_baseline_common import ROOT, EXPERIMENT, sha256, write_json

BEFORE_SHA = '758b6a54576d065444a3569c98e26bc6759d43c263df3f273eeb824ea7204b7c'
RELATIVE = '.tools/ai-baseline-venv/Lib/site-packages/paddle/dataset/common.py'
OLD = b"DATA_HOME = os.path.join(HOME, '.cache', 'paddle', 'dataset')"
NEW = b"DATA_HOME = os.environ.get('PADDLE_DATA_HOME', os.path.join(HOME, '.cache', 'paddle', 'dataset'))"


def main():
    path = ROOT/RELATIVE
    content = path.read_bytes()
    original = content.replace(NEW,OLD)
    import hashlib
    if hashlib.sha256(original).hexdigest() != BEFORE_SHA or original.count(OLD) != 1:
        raise ValueError('unexpected Paddle source version; refusing to patch')
    path.write_bytes(original.replace(OLD,NEW))
    write_json(EXPERIMENT/'runtime-patches.json',{'patches':[{
        'package':'paddlepaddle','version':'3.3.1','path':RELATIVE,
        'before_sha256':BEFORE_SHA,'after_sha256':sha256(path),
        'purpose':'Honor PADDLE_DATA_HOME in the import-time dataset cache; inference kernels unchanged.',
        'upstream_license':'Apache-2.0'}]})
    print('Applied/verified local Paddle dataset-cache configuration patch.')


if __name__ == '__main__':
    main()
