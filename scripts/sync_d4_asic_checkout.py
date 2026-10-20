#!/usr/bin/env python3
"""Fast-forward an ASIC server checkout, preserving colliding imported files.

Run only with no tools reading the checkout. Dry-run is the default. This never
resets, cleans or drops tracked changes; incoming tracked overlap is an error.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=Path.cwd())
    p.add_argument('--branch', default='codex/d4-asic-smic180')
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    root = a.root.resolve()

    def git(*args):
        return subprocess.check_output(['git'] + list(args), cwd=str(root)).decode().strip()

    def paths(*args):
        out = subprocess.check_output(['git'] + list(args), cwd=str(root)).decode()
        return set(filter(None, out.split('\0')))

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    assert Path(git('rev-parse', '--show-toplevel')).resolve() == root
    assert git('symbolic-ref', '--short', 'HEAD') == a.branch
    assert not paths('diff', '--cached', '--name-only', '-z'), 'Preserve staged work separately'
    git('fetch', 'origin', a.branch)
    target = 'origin/' + a.branch
    old, new = git('rev-parse', 'HEAD'), git('rev-parse', target)
    subprocess.check_call(['git', 'merge-base', '--is-ancestor', old, new], cwd=str(root))
    if old == new:
        print('D4_SERVER_GIT_ALREADY_CURRENT head=' + new)
        return
    incoming = paths('diff', '--name-only', '-z', old, new)
    dirty = paths('diff', '--name-only', '-z')
    assert not incoming & dirty, 'Incoming tracked changes overlap dirty files'
    dirty_hashes = {name: digest(root / name) for name in dirty}
    conflicts = sorted(incoming & paths('ls-files', '--others', '--exclude-standard', '-z'))
    backup = root / 'build/reports/server_git_preservation_20261020' / new[:12]
    assert root in backup.resolve().parents
    record = {'old': old, 'new': new, 'tracked_dirty_sha256': dirty_hashes, 'backup': {}}
    for name in conflicts:
        source = (root / name).resolve()
        assert root in source.parents and source.is_file() and not (root / name).is_symlink()
        record['backup'][name] = digest(source)
    print(json.dumps({'incoming': len(incoming), 'untracked_collisions': len(conflicts),
                      'tracked_overlap': [], 'apply': a.apply}))
    if not a.apply:
        return
    backup.mkdir(parents=True, exist_ok=False)
    for name in conflicts:
        source, dest = root / name, backup / name
        assert backup in dest.resolve().parents
        dest.parent.mkdir(parents=True, exist_ok=True)
        source.rename(dest)
        assert digest(dest) == record['backup'][name]
    (backup / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    subprocess.check_call(['git', 'merge', '--ff-only', target], cwd=str(root))
    assert git('rev-parse', 'HEAD') == new
    assert paths('diff', '--name-only', '-z') == dirty
    assert {name: digest(root / name) for name in dirty} == dirty_hashes
    print('D4_SERVER_GIT_SYNC_PASS head={} backed_up={} historical_dirty={}'.format(new, len(conflicts), len(dirty)))


if __name__ == '__main__':
    main()
