"""Prepare the pinned CPU conversion tools and Silero ONNX."""
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import urlopen
import zipfile

from scripts.ai_baseline_common import ROOT, read_json, sha256

NATIVE_SOURCES_LOCK = 'experiments/mobile_ai_v1/native-sources.lock.json'
CPU_ARCHIVE = 'data/mobile-ai/sources/llama-b10903-bin-win-cpu-x64.zip'
VAD_SOURCE = 'data/mobile-ai/sources/silero-v6.2.onnx'


def native_source_pins(root: Path) -> dict[str, dict]:
    return {entry['path']: entry for entry in read_json(root / NATIVE_SOURCES_LOCK)}


def _matches_pin(path: Path, entry: dict) -> bool:
    return (path.is_file() and path.stat().st_size == entry['bytes']
            and sha256(path) == entry['sha256'])


def _prepare_source(path: Path, entry: dict) -> None:
    if _matches_pin(path, entry):
        return
    with TemporaryDirectory(dir=path.parent, prefix=f'.{path.name}.') as directory:
        temporary = Path(directory) / 'download.partial'
        received = 0
        with urlopen(entry['url'], timeout=90) as response, temporary.open('xb') as output:
            while block := response.read(1024 * 1024):
                received += len(block)
                if received > entry['bytes']:
                    raise ValueError(f'{path.name}: download exceeds pinned size')
                output.write(block)
        if not _matches_pin(temporary, entry):
            raise ValueError(f'{path.name}: download failed pinned size or SHA-256 check')
        temporary.replace(path)


def main():
    pins = native_source_pins(ROOT)
    archive_path = ROOT / CPU_ARCHIVE
    root = archive_path.parent
    root.mkdir(parents=True, exist_ok=True)
    for relative in (CPU_ARCHIVE, VAD_SOURCE):
        _prepare_source(ROOT / relative, pins[relative])
    target = root / 'llama-windows-b10903'
    target.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            path = (target / member.filename).resolve()
            if not path.is_relative_to(target.resolve()):
                raise ValueError('unsafe archive path')
        archive.extractall(target)
    print('Native CPU tools and VAD verified')


if __name__ == '__main__':
    main()
