#!/usr/bin/env python3
"""Check the public index, or a committed tree, for known private artifacts."""
import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def violations(paths):
    private_parts = {
        '商业拓展', 'jotbloom-extensions', 'commercial', 'private',
        'licensingservice', '小芽动态预览', 'companion-preview', '历史开发存档',
    }
    private_names = {'交互逻辑验证.cjs', '.gitmodules'}
    sensitive_suffixes = {'.pem', '.key', '.p12', '.pfx', '.keystore', '.sqlite', '.db'}
    for path in paths:
        p = PurePosixPath(path)
        parts = {part.lower() for part in p.parts}
        name = p.name.lower()
        if (parts & private_parts or name in private_names
                or p.suffix.lower() in sensitive_suffixes
                or name.startswith('._')
                or (name.startswith('.env') and name not in {'.env.example', '.env.sample'})
                or '.sqlite-' in name):
            yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', help='Check the entire committed tree instead of the index')
    args = parser.parse_args()
    if args.tree:
        # Resolve first; no untrusted revision is interpreted as a Git option.
        tree = subprocess.check_output(
            ['git', 'rev-parse', '--verify', '--end-of-options', args.tree + '^{tree}'], cwd=ROOT, text=True
        ).strip()
        command = ['git', 'ls-tree', '-r', '--name-only', '-z', tree]
    else:
        command = ['git', 'ls-files', '--cached', '-z']
    paths = subprocess.check_output(command, cwd=ROOT).decode('utf-8').rstrip('\0').split('\0')
    problems = sorted(set(violations(p for p in paths if p)))
    if problems:
        print('Public repository boundary check failed; review these paths:', file=sys.stderr)
        for path in problems:
            print('  ' + path, file=sys.stderr)
        return 1
    print('Public repository boundary check passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
