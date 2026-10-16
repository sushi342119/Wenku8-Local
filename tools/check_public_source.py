#!/usr/bin/env python3
"""Reject private local artifacts and obvious credentials in a release checkout."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

SKIP = {'.git', '.dart_tool', '.gradle', '.cxx', 'build', 'Pods', '__pycache__', '.symlinks'}
PRIVATE_NAMES = {'local.properties', 'key.properties', '.DS_Store', 'Generated.xcconfig',
                 'flutter_export_environment.sh', '.env', '.env.local'}
PRIVATE_DIRS = {'.local-notes', '.local-samples', 'flutter_screenshots', 'xcuserdata'}
PRIVATE_SUFFIXES = {'.jks', '.keystore', '.pem', '.key', '.p12', '.mobileprovision', '.log', '.apk', '.aab'}
PATTERNS = {
    'host home path': re.compile(r'[/](?:Users|home)[/][A-Za-z0-9_.-]+[/]'),
    'GitHub credential': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'AWS access key': re.compile(r'AKIA[A-Z0-9]{16}'),
    'personal device selector': re.compile(r'adb\s+-s\s+[A-Z0-9]{12,}'),
    'private LAN address': re.compile(r'\b(?:192[.]168[.]\d+[.]\d+|10[.]\d+[.]\d+[.]\d+)\b'),
}


def inspect(root: Path) -> list[str]:
    issues = []
    for file in sorted(root.rglob('*')):
        relative = file.relative_to(root)
        if any(part in SKIP for part in relative.parts):
            continue
        if file.is_symlink():
            issues.append(f'{relative}: symbolic link is not allowed in the public export')
            continue
        if not file.is_file():
            continue
        if file.name in PRIVATE_NAMES or file.suffix.lower() in PRIVATE_SUFFIXES or any(p in PRIVATE_DIRS for p in relative.parts):
            issues.append(f'{relative}: private or generated artifact')
            continue
        try:
            text = file.read_text(encoding='utf-8')
        except (UnicodeDecodeError, ValueError):
            continue
        for name, pattern in PATTERNS.items():
            if pattern.search(text):
                # Never echo the matching credential or user data into CI logs.
                issues.append(f'{relative}: {name}')
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path, nargs='?', default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    issues = inspect(args.root.resolve())
    if issues:
        raise SystemExit('\n'.join(issues))
    print('Public source policy passed: no prohibited local artifacts or recognized secrets.')


if __name__ == '__main__':
    main()
