import tempfile
import unittest
from pathlib import Path

from prepare_release import metadata


class ReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "pubspec.yaml").write_text("version: 0.2.0+2\n")
        (self.root / "lib/updates").mkdir(parents=True)
        (self.root / "lib/updates/app_updates.dart").write_text("const currentAppVersion = '0.2.0';\nconst currentAppBuild = 2;\n")
        (self.root / "CHANGELOG.md").write_text("# 版本说明\n\n## 0.2.0 · 2026-10-15\n\n- 新功能\n\n## 0.1.0\n旧功能\n")

    def test_notes_do_not_include_previous_release(self):
        self.assertEqual(metadata(self.root, "v0.2.0"), ("0.2.0", 2, "- 新功能\n"))
        self.assertEqual(metadata(self.root, "v0.2.0+2")[1], 2)

    def test_wrong_tag_is_rejected(self):
        for tag in ("v0.3.0", "v0.2.0+1", "v0.2.0-beta", "$(echo unsafe)"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                metadata(self.root, tag)

    def test_plain_heading_keeps_the_first_note(self):
        (self.root / "CHANGELOG.md").write_text("# 版本说明\n## 0.2.0\n- 第一项\n## 0.1.0\n旧版\n")
        self.assertEqual(metadata(self.root)[2], "- 第一项\n")

    def test_missing_notes_are_rejected(self):
        (self.root / "CHANGELOG.md").write_text("# 版本说明\n## 0.1.0\n旧版\n")
        with self.assertRaises(ValueError):
            metadata(self.root)

    def test_invalid_build_is_rejected(self):
        (self.root / "pubspec.yaml").write_text("version: 0.2.0+0\n")
        with self.assertRaises(ValueError):
            metadata(self.root)

    def test_visible_app_version_must_match_the_package(self):
        (self.root / "pubspec.yaml").write_text("version: 0.2.1+3\n")
        with self.assertRaisesRegex(ValueError, "version constants"):
            metadata(self.root)

    def test_injected_versions_allow_development_defaults(self):
        dart = self.root / 'lib/updates/app_updates.dart'
        dart.write_text("""const currentAppVersion = String.fromEnvironment(
  'APP_VERSION', defaultValue: '0.1.0',
);
const currentAppBuild = int.fromEnvironment(
  'APP_BUILD', defaultValue: 1,
);
""")
        self.assertEqual(metadata(self.root, 'v0.2.0+2')[:2], ('0.2.0', 2))

    def test_wrong_injection_keys_are_rejected(self):
        dart = self.root / 'lib/updates/app_updates.dart'
        for version_key, build_key in [('VERSION', 'APP_BUILD'), ('APP_VERSION', 'BUILD')]:
            with self.subTest(version_key=version_key, build_key=build_key):
                dart.write_text(
                    f"const currentAppVersion = String.fromEnvironment('{version_key}', defaultValue: '0.2.0');\n"
                    f"const currentAppBuild = int.fromEnvironment('{build_key}', defaultValue: 2);\n")
                with self.assertRaisesRegex(ValueError, 'version constants'):
                    metadata(self.root)

    def test_repository_release_metadata_is_valid(self):
        # Exercise the real Dart declarations as well as synthetic fixtures.
        root = Path(__file__).resolve().parents[1]
        self.assertTrue(metadata(root)[2].strip())


"""Run the actual CI test pipeline with controlled test exit statuses."""
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


class TestPipelineStatus(unittest.TestCase):
    def test_test_failures_and_deadlines_reach_the_job(self):
        root = Path(__file__).resolve().parents[1]
        for name in ('android-release.yml', 'local-build.yml'):
            workflow = (root / '.github/workflows' / name).read_text()
            step = re.search(
                r'      - name: Run tests with process deadline\n(.*?)(?=      - )',
                workflow, re.S,
            ).group(1)
            self.assertIn('shell: bash', step)
            script = textwrap.dedent(step.split('        run: |\n', 1)[1])
            for status in (0, 9, 124):
                with self.subTest(workflow=name, exit_status=status), tempfile.TemporaryDirectory() as tmp:
                    # Replace only the deadline command; exercise the workflow's
                    # real shell options, pipe and tee invocation unchanged.
                    stub = f'timeout() {{ echo test-output; return {status}; }}\n'
                    result = subprocess.run(
                        ['bash', '-e', '-c', stub + script], cwd=tmp,
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertIn('test-output', (Path(tmp) / 'build/flutter-tests.log').read_text())
