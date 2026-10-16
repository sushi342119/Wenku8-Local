#!/usr/bin/env python3
"""Verify that an APK redistributes the original API binary without stripping."""
from __future__ import annotations
import argparse
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent


def verify(apk: Path, abi: str, root: Path = ROOT):
    original = root / 'android/app/src/main/jniLibs' / abi / 'libcpp.so'
    with ZipFile(apk) as archive:
        names = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('/libcpp.so')]
        expected = f'lib/{abi}/libcpp.so'
        if names != [expected]:
            raise ValueError(f'Expected only the {abi} API runtime in this one-ABI APK')
        if archive.read(expected) != original.read_bytes():
            raise ValueError(f'{abi}: packaged API runtime differs from the original; check native symbol stripping')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abi', required=True, choices=['armeabi-v7a','arm64-v8a','x86_64'])
    args = parser.parse_args()
    verify(args.apk, args.abi)
    print(f'{args.abi}: embedded API runtime is byte-for-byte unchanged.')


if __name__ == '__main__':
    main()
