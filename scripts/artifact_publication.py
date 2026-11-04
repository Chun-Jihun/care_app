"""Stage a release before publication and roll back handled I/O failures.

The last path is the consumer's descriptor/commit point. All streams must be
closed before leaving the context. Existing immutable releases are never replaced.
This is exception rollback, not a cross-directory power-loss transaction: an
interrupted process leaves .partial/.previous files for explicit inspection.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
from typing import Iterator, Sequence


@contextmanager
def staged_release(paths: Sequence[Path], *, replace: Sequence[Path] = ()) -> Iterator[dict[Path, Path]]:
    if len(set(path.resolve() for path in paths)) != len(paths):
        raise ValueError('release paths must be distinct')
    stages: dict[Path, Path] = {}
    backups: dict[Path, Path] = {}
    published: list[Path] = []
    recovery_needed = False
    try:
        for path in paths:
            if path.is_symlink() or (path.exists() and path not in replace):
                raise FileExistsError(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            stage = path.with_suffix(path.suffix + '.partial')
            with stage.open('xb'):
                pass
            stages[path] = stage
            if path in replace and path.exists():
                backup = path.with_suffix(path.suffix + '.previous')
                with backup.open('xb') as target:
                    backups[path] = backup
                    with path.open('rb') as source:
                        shutil.copyfileobj(source, target)
        yield stages
        for path in paths:
            with stages[path].open('r+b') as stream:
                os.fsync(stream.fileno())
        try:
            for path in paths:
                if path in replace:
                    os.replace(stages[path], path)
                else:
                    # Exclusive publication also on POSIX, where rename overwrites.
                    os.link(stages[path], path)
                published.append(path)
        except BaseException as failure:
            errors = []
            for path in reversed(published):
                try:
                    if path in backups:
                        os.replace(backups[path], path)
                    else:
                        path.unlink()
                except OSError as error:
                    errors.append(error)
            if errors:
                recovery_needed = True
                raise BaseExceptionGroup('publication rollback needs inspection', [failure, *errors])
            raise
    finally:
        if not recovery_needed:
            for temporary in [*stages.values(), *backups.values()]:
                temporary.unlink(missing_ok=True)
