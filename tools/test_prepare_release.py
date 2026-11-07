import json
import os
import sys
import contextlib
import io
import tempfile
import re
import subprocess
import textwrap
import unittest
from unittest import mock
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

    def test_from_environment_default_values_are_supported(self):
        (self.root / "lib/updates/app_updates.dart").write_text(
            "const currentAppVersion = String.fromEnvironment(\n"
            "  'APP_VERSION',\n"
            "  defaultValue: '0.2.0',\n"
            ");\n"
            "const currentAppBuild = int.fromEnvironment(\n"
            "  'APP_BUILD',\n"
            "  defaultValue: 2,\n"
            ");\n"
        )
        self.assertEqual(metadata(self.root, "v0.2.0+2"), ("0.2.0", 2, "- 新功能\n"))




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


class ReleasePublicationTest(unittest.TestCase):
    def run_release_step(self, *, existing=None, cli_failure=False, **event):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/android-release.yml').read_text()
        step = re.search(
            r'      - name: Create draft release\n(.*?)(?=      - )',
            workflow, re.S,
        ).group(1)
        script = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            state_file = temp / 'state.json'
            state_file.write_text(json.dumps({'release': existing, 'calls': []}))
            fake = temp / 'gh'
            fake.write_text(f'#!{sys.executable}\n' + textwrap.dedent('''\
                import json
                import os
                from pathlib import Path
                import sys

                path = Path(os.environ['FAKE_GH_STATE'])
                state = json.loads(path.read_text())
                args = sys.argv[1:]
                state['calls'].append(args)
                path.write_text(json.dumps(state))
                if os.environ['FAKE_GH_FAILURE'] == '1':
                    sys.exit(7)
                if args and args[0] == 'api':
                    # Put the matching release on a later page to exercise pagination.
                    print(json.dumps([[{'tag_name': 'v0.1.0'}],
                                      [{'tag_name': state['release']['tag']}]
                                      if state['release'] else []]))
                    sys.exit(0)
                if args[:2] != ['release', 'create']:
                    sys.exit(90)
                if state['release'] is not None:
                    sys.exit(1)
                state['release'] = {
                    'tag': args[2],
                    'draft': '--draft' in args,
                    'latest': '--latest' in args,
                    'target': args[args.index('--target') + 1],
                    'assets': [arg for arg in args if arg.endswith(('.apk', '.zip'))],
                }
                path.write_text(json.dumps(state))
                '''))
            fake.chmod(0o700)
            env = {
                **os.environ,
                'PATH': f'{temp}{os.pathsep}{os.environ["PATH"]}',
                'FAKE_GH_STATE': str(state_file),
                'FAKE_GH_FAILURE': '1' if cli_failure else '0',
                'RELEASE_TAG': 'v1.8.2+49',
                'GITHUB_SHA': 'candidate-commit',
                'GITHUB_REPOSITORY': 'sushi342119/Shuyu',
                **event,
            }
            result = subprocess.run(
                ['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', script],
                cwd=temp, env=env, capture_output=True, text=True,
            )
            return result, json.loads(state_file.read_text())

    def test_all_triggers_create_published_release(self):
        for event in (
            {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_TYPE': 'tag',
             'GITHUB_REF': 'refs/tags/v1.8.2+49'},
            {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_TYPE': 'branch',
             'GITHUB_REF': 'refs/heads/main', 'PUBLISH_FROM_MAIN': 'true'},
            {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF_TYPE': 'branch',
             'GITHUB_REF': 'refs/heads/main', 'PUBLISH_FROM_MAIN': 'true'},
        ):
            with self.subTest(event=event):
                result, state = self.run_release_step(**event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state['release'], {
                    'tag': 'v1.8.2+49', 'draft': False, 'latest': True,
                    'target': 'candidate-commit',
                    'assets': ['build/shuyu-v1.8.2+49-arm64-v8a.apk',
                               'build/shuyu-source.zip'],
                })
                self.assertEqual(len(state['calls']), 2)
                self.assertEqual(state['calls'][0], [
                    'api', '--paginate', '--slurp',
                    'repos/sushi342119/Shuyu/releases?per_page=100',
                ])

    def test_existing_draft_and_published_assets_are_unchanged(self):
        for draft in (True, False):
            existing = {
                'tag': 'v1.8.2+49', 'draft': draft,
                'assets': ['original.apk'], 'digest': 'original-digest',
            }
            with self.subTest(draft=draft):
                result, state = self.run_release_step(existing=existing)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Release already exists (including drafts)', result.stderr)
                self.assertEqual(state['release'], existing)
                self.assertEqual(len(state['calls']), 1)

    def test_cli_errors_stop_without_fallback_mutations(self):
        result, state = self.run_release_step(cli_failure=True)
        self.assertEqual(result.returncode, 7)
        self.assertIsNone(state['release'])
        self.assertEqual(len(state['calls']), 1)


class UpdateIdentityValidationTest(unittest.TestCase):
    def check_candidate(self, *, package='app.shuyu.reader', build=50,
                        version='1.8.3', certificate='ab' * 32, invalid_signature=False,
                        labels=('Signer #1', 'Signer #1'), extra_report=''):
        workflow = (Path(__file__).resolve().parents[1] /
                    '.github/workflows/android-release.yml').read_text()
        step = re.search(
            r'      - name: Verify update identity against published APK\n(.*?)(?=      - )',
            workflow, re.S,
        ).group(1)
        script = textwrap.dedent(step.split('        run: |\n', 1)[1])
        python = script.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]

        def inspect_command(command, *, text):
            old = command[-1] == 'old.apk'
            if 'badging' in command:
                identity = ('org.mewx.wenku8_flutter', 49, '1.8.2') if old else (package, build, version)
                return "package: name='%s' versionCode='%s' versionName='%s'\n" % identity
            if invalid_signature and not old:
                raise subprocess.CalledProcessError(1, command)
            digest = 'ab' * 32 if old else certificate
            label = labels[0] if old else labels[1]
            return (f'{label} certificate SHA-256 digest: {digest}\n' if digest else '') + extra_report

        with mock.patch.dict(os.environ, {'ANDROID_HOME': '/sdk', 'APP_BUILD': '50',
                                         'APP_VERSION': '1.8.3'}), \
                mock.patch.object(sys, 'argv', ['verify', 'old.apk']), \
                mock.patch.object(Path, 'glob', return_value=iter([Path('/sdk/build-tools/36.0.0/apksigner')])), \
                mock.patch.object(subprocess, 'check_output', side_effect=inspect_command), \
                contextlib.redirect_stdout(io.StringIO()):
            exec(compile(python, 'workflow-update-identity', 'exec'), {})

    def test_same_identity_and_increasing_version_are_accepted(self):
        self.check_candidate()

    def test_incompatible_packages_certificates_and_versions_are_rejected(self):
        for candidate in (
            {'package': 'org.mewx.wenku8_flutter'},
            {'package': 'com.github.sushi342119.wenku8local'},
            {'certificate': 'cd' * 32},
            {'certificate': 'ab'},
            {'certificate': ''},
            {'build': 49},
            {'build': 51},
            {'version': '1.8.2'},
        ):
            with self.subTest(candidate=candidate), self.assertRaises(SystemExit):
                self.check_candidate(**candidate)

    def test_invalid_signature_stops_release(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.check_candidate(invalid_signature=True)

    def test_build_tools_37_scheme_labels_and_older_labels_are_accepted(self):
        # Actual Build Tools 37 output from the published v1.8.2+49 APK.
        for label in ('V2 Signer:', 'V3.0 Signer:',
                      'Signer (minSdkVersion=33, maxSdkVersion=2147483647)'):
            with self.subTest(label=label):
                self.check_candidate(labels=('Signer #1', label), certificate='AB' * 32)

    def test_source_stamp_and_public_key_hashes_do_not_change_app_identity(self):
        self.check_candidate(extra_report=(
            'Source Stamp Signer certificate SHA-256 digest: ' + 'cd' * 32 + '\n'
            'V2 Signer: public key SHA-256 digest: ' + 'ef' * 32 + '\n'))

    def test_source_stamp_alone_cannot_authorize_an_update(self):
        with self.assertRaises(SystemExit):
            self.check_candidate(labels=('Signer #1', 'Source Stamp Signer'))
