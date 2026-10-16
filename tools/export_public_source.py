#!/usr/bin/env python3
"""Export the Flutter project without local QA data or historical Android builds."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent
FILES = (
    "README.md", "LICENSE", "NOTICE", ".gitignore", "pubspec.yaml", "pubspec.lock",
    "analysis_options.yaml", ".github/workflows/flutter-ci.yml", ".github/workflows/android-release.yml",
    "tools/export_public_source.py", "tools/test_public_source_export.py", "tools/generate_app_icons.dart",
    "docs/RELEASING.md", "docs/THIRD_PARTY.md", "CHANGELOG.md", "tools/prepare_release.py", "tools/test_prepare_release.py",
    "tools/check_public_source.py", "tools/test_public_source_policy.py",
    "tools/verify_apk_runtime.py", "tools/test_verify_apk_runtime.py",
)
DIRECTORIES = ("lib", "assets", "shaders", "test", "integration_test", "android", "ios", "docs/images", "third_party/liquid_glass_easy")
PRIVATE_NAMES = {
    "local.properties", "key.properties", "GeneratedPluginRegistrant.java",
    "Generated.xcconfig", "flutter_export_environment.sh", ".DS_Store",
    ".last_build_id", "ephemeral", "Flutter.podspec", "flutter_export_environment.sh",
}
SKIP_DIRS = {"build", ".gradle", ".cxx", "Pods", ".symlinks", "__pycache__", ".git",
             "xcuserdata", "ephemeral", ".idea", ".dart_tool", "App.framework", "Flutter.framework"}
DEVELOPMENT_ENTRIES = {
    "lib/performance_page.dart", "lib/ui_performance.dart",
    "lib/expansion_probe.dart", "lib/render_budget_probe.dart",
    "integration_test/performance_capture_test.dart",
    "test/ui_frame_capture_test.dart",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New, empty output folder")
    parser.add_argument("--source-only", action="store_true",
                        help="Omit the embedded libcpp.so runtime (the resulting app cannot use its network API)")
    args = parser.parse_args()
    destination = args.output.resolve()
    if destination == ROOT or ROOT.is_relative_to(destination) or destination.is_relative_to(ROOT):
        parser.error("Choose a separate empty folder outside the project and its parent folders")
    if destination.exists() and any(destination.iterdir()):
        parser.error("The output folder must be empty; existing files are never removed")
    destination.mkdir(parents=True, exist_ok=True)
    copied = 0

    def copy(relative):
        nonlocal copied
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            return
        if any(part in SKIP_DIRS for part in relative.parts):
            return
        if source.name in PRIVATE_NAMES or source.suffix in {".jks", ".keystore", ".apk", ".aab", ".log", ".pyc", ".p12", ".pem", ".key", ".mobileprovision", ".xcuserstate"}:
            return
        if relative.as_posix() in DEVELOPMENT_ENTRIES:
            return
        if source.name == "libcpp.so" and args.source_only:
            return
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied += 1

    for name in FILES:
        copy(Path(name))
    for directory in DIRECTORIES:
        for source in sorted((ROOT / directory).rglob("*")):
            copy(source.relative_to(ROOT))
    print(f"Exported {copied} source files to {destination}")
    if args.source_only:
        print("Network API runtime excluded. See docs/RELEASING.md before distributing a working network build.")
    else:
        print("Embedded network runtime retained unchanged under its separate redistribution conditions. See docs/THIRD_PARTY.md.")


if __name__ == "__main__":
    main()
