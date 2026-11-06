import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/android-release.yml"


def script(name):
    workflow = WORKFLOW.read_text()
    match = re.search(
        rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)",
        workflow,
        re.M | re.S,
    )
    if match is None:
        raise AssertionError(f"Missing workflow step: {name}")
    return textwrap.dedent(match[1].split("        run: |\n", 1)[1])


class ApkAssetNamingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tag = "v1.8.2+49"  # Test data, not a release request.
        self.names = [
            f"build/shuyu-{self.tag}-arm64-v8a.apk",
            f"build/wenku8-local-{self.tag}-arm64-v8a.apk",
            "build/shuyu-source.zip",
        ]
        apk = self.root / "build/app/outputs/flutter-apk/app-release.apk"
        apk.parent.mkdir(parents=True)
        self.payload = bytes(range(256)) * 16
        apk.write_bytes(self.payload)
        (self.root / self.names[2]).write_bytes(b"source fixture")
        self.env = {
            **os.environ,
            "RELEASE_TAG": self.tag,
            "GITHUB_REF_TYPE": "tag",
            "GITHUB_REF": f"refs/tags/{self.tag}",
            "GITHUB_SHA": "fixture-sha",
            "PUBLISH_FROM_MAIN": "false",
        }
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "with pathlib.Path('gh-calls.jsonl').open('a') as out:\n"
            "    out.write(json.dumps(args) + '\\n')\n"
            "if args[:2] == ['release', 'view']:\n"
            "    if os.environ.get('EXISTING') != 'true':\n"
            "        sys.exit(1)\n"
            "    if '--json' in args:\n"
            "        print(os.environ.get('IS_DRAFT', 'false'))\n"
            "elif args[:2] in [['release', 'create'], ['release', 'upload']]:\n"
            "    for arg in args:\n"
            "        if arg.startswith('build/') and arg.endswith(('.apk', '.zip')):\n"
            "            assert pathlib.Path(arg).is_file(), arg\n"
            "else:\n"
            "    sys.exit(2)\n"
        )
        gh.chmod(0o755)
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"

    def run_step(self, name):
        return subprocess.run(
            ["bash", "-e", "-c", script(name)],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def name_assets(self):
        result = self.run_step("Name branded and legacy update assets")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_both_names_are_byte_identical_to_signed_input(self):
        self.name_assets()
        expected = hashlib.sha256(self.payload).digest()
        for name in self.names[:2]:
            data = (self.root / name).read_bytes()
            self.assertEqual(data, self.payload)
            self.assertEqual(hashlib.sha256(data).digest(), expected)

    def test_missing_build_fails_before_publishing(self):
        (self.root / "build/app/outputs/flutter-apk/app-release.apk").unlink()
        self.assertNotEqual(
            self.run_step("Name branded and legacy update assets").returncode, 0
        )

    def test_every_publish_path_carries_both_names_and_matching_source(self):
        self.name_assets()
        cases = [
            ("tag", "false", "false", "false", "create", False),
            ("branch", "true", "false", "false", "create", False),
            ("branch", "false", "false", "false", "create", True),
            ("tag", "false", "true", "true", "upload", False),
        ]
        log = self.root / "gh-calls.jsonl"
        for ref_type, publish, exists, draft, action, creates_draft in cases:
            with self.subTest(ref_type=ref_type, publish=publish, exists=exists):
                log.unlink(missing_ok=True)
                self.env.update({
                    "GITHUB_REF_TYPE": ref_type,
                    "GITHUB_REF": (
                        f"refs/tags/{self.tag}" if ref_type == "tag"
                        else "refs/heads/main"
                    ),
                    "PUBLISH_FROM_MAIN": publish,
                    "EXISTING": exists,
                    "IS_DRAFT": draft,
                })
                result = self.run_step("Publish release")
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                writes = [args for args in calls if args[1] in ("create", "upload")]
                self.assertEqual(len(writes), 1)
                args = writes[0]
                self.assertEqual(args[:3], ["release", action, self.tag])
                self.assertEqual(
                    [arg for arg in args if arg.startswith("build/")
                     and arg.endswith((".apk", ".zip"))],
                    self.names,
                )
                if action == "create":
                    self.assertEqual("--draft" in args, creates_draft)
                    self.assertEqual("--latest" in args, not creates_draft)
                else:
                    self.assertIn("--clobber", args)  # Drafts only.

    def test_published_release_cannot_be_overwritten(self):
        self.name_assets()
        self.env.update({"EXISTING": "true", "IS_DRAFT": "false"})
        result = self.run_step("Publish release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite", result.stdout)
        calls = [
            json.loads(line)
            for line in (self.root / "gh-calls.jsonl").read_text().splitlines()
        ]
        self.assertTrue(calls)
        self.assertTrue(all(args[:2] == ["release", "view"] for args in calls))


if __name__ == "__main__":
    unittest.main()
