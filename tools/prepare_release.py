#!/usr/bin/env python3
"""Validate a release tag against pubspec and extract its user-facing notes."""
from __future__ import annotations

import argparse
from pathlib import Path
import re


def metadata(root: Path, tag: str | None = None) -> tuple[str, int, str]:
    version = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$",
                        (root / "pubspec.yaml").read_text(), re.M)
    if version is None or not 0 < int(version[2]) < 2100000000:
        raise ValueError("pubspec.yaml needs a semantic version and a positive Android build number")
    name, build = version[1], int(version[2])
    dart = (root / "lib/updates/app_updates.dart").read_text()
    app_version = re.search(r"const currentAppVersion\s*=\s*'([^']+)'", dart)
    app_build = re.search(r"const currentAppBuild\s*=\s*(\d+)", dart)
    if app_version is None or app_build is None or app_version[1] != name or int(app_build[1]) != build:
        raise ValueError("Update the app's version constants together with pubspec.yaml")
    if tag is not None and tag not in {f"v{name}", f"v{name}+{build}"}:
        raise ValueError(f"Tag {tag!r} does not match pubspec version {name}+{build}")
    changelog = (root / "CHANGELOG.md").read_text()
    notes = re.search(rf"^## {re.escape(name)}(?:[ \t][^\n]*)?\n(.*?)(?=^## |\Z)",
                      changelog, re.M | re.S)
    if notes is None or not notes[1].strip():
        raise ValueError(f"CHANGELOG.md needs release notes for {name}")
    return name, build, notes[1].strip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()
    version, build, notes = metadata(Path(__file__).resolve().parents[1], args.tag)
    args.notes.parent.mkdir(parents=True, exist_ok=True)
    args.notes.write_text(notes)
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(f"version={version}\nbuild={build}\n")
    print(f"Release {version}+{build}; notes: {args.notes}")


if __name__ == "__main__":
    main()
