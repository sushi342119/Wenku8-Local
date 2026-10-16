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
