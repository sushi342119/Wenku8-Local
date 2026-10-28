#!/usr/bin/env python3
"""Run Flutter test suites directly when loopback sockets are unavailable.

Uses the installed Flutter engine and test_api's actual Declarer/Invoker, including
setUp/tearDown, async error tracking, expectations and testWidgets. No networking.
Usage: python3 tool/run_chapter_tests.py --flutter-sdk SDK --output OUT test/....dart
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

RUNNER = "import 'dart:async';\nimport 'dart:io';\nimport 'package:flutter_test/flutter_test.dart';\nimport 'package:test_api/src/backend/declarer.dart';\nimport 'package:test_api/src/backend/invoker.dart';\nimport 'package:test_api/src/backend/group.dart';\nimport 'package:test_api/src/backend/test.dart';\nimport 'package:test_api/src/backend/suite.dart';\nimport 'package:test_api/src/backend/suite_platform.dart';\nimport 'package:test_api/src/backend/runtime.dart';\nimport 'package:test_api/src/backend/operating_system.dart';\nimport 'SUITE_PATH' as tests;\nFuture<void> main() async {\n  final log = File('/tmp/chapter-runner-result.log').openSync(mode: FileMode.append);\n  void report(String s) { log.writeStringSync('$s\\n'); print(s); }\n  try {\n    TestWidgetsFlutterBinding.ensureInitialized();\n    final declarer = Declarer();\n    await declarer.declare(() async { tests.main(); });\n    final root = declarer.build();\n    final suite = Suite(root, SuitePlatform(Runtime.vm, os: OperatingSystem.linux));\n    var failed = 0, passed = 0;\n    Future<bool> run(Test test, List<Group> groups) async {\n      if (test.metadata.skip) {report('SKIP ${test.name}'); return true;}\n      report('START ${test.name}');\n      final live = test.load(suite, groups: groups);\n      final subscription = live.onError.listen((e) => report('ERROR ${test.name}: ${e.error}\\n${e.stackTrace}'));\n      await Invoker.guard(() => live.run());\n      final success = live.state.result.isPassing;\n      if(success) { passed++; report('PASS ${test.name}'); }\n      else {failed++; report('FAIL ${test.name}');}\n      await live.close();\n      await subscription.cancel();\n      return success;\n    }\n    Future<void> walk(Group group, List<Group> parents) async {\n      final groups = [...parents, group];\n      var ok = true;\n      if(group.setUpAll != null) ok=await run(group.setUpAll!, groups);\n      if(ok) for(final child in group.entries) {\n        if(child is Group) {await walk(child, groups);} else if(child is Test) {await run(child, groups);}\n      }\n      if(group.tearDownAll != null) await run(group.tearDownAll!, groups);\n    }\n    await walk(root, []);\n    report('RESULT $passed passed, $failed failed');\n    log.closeSync();\n    exit(failed == 0 ? 0 : 1);\n  } catch(e,s) {report('RUNNER ERROR $e\\n$s'); log.closeSync(); exit(2);}\n}\n"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-sdk', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('tests', nargs='+', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    cache = args.flutter_sdk.resolve() / 'bin/cache'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    failed = []
    for test in args.tests:
        test = (repo / test).resolve()
        with tempfile.TemporaryDirectory(prefix='chapter-flutter-test-') as temporary:
            temp = Path(temporary)
            entry, kernel = temp / 'runner.dart', temp / 'runner.dill'
            result_log = output / (test.stem + '.results.log')
            result_log.write_text('')
            entry.write_text(RUNNER.replace('SUITE_PATH', test.as_uri()).replace(
                '/tmp/chapter-runner-result.log', str(result_log)))
            with (output / (test.stem + '.compile.log')).open('w') as log:
                compile_result = subprocess.run([
                    str(cache / 'dart-sdk/bin/dartaotruntime'),
                    str(cache / 'dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
                    '--sdk-root', str(cache / 'artifacts/engine/common/flutter_patched_sdk'),
                    '--target', 'flutter', '--track-widget-creation',
                    '--packages', str(repo / '.dart_tool/package_config.json'),
                    '--output-dill', str(kernel),
                    '-Dflutter.inspector.structuredErrors=true', str(entry),
                ], cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            if compile_result.returncode:
                failed.append(test.name)
                print(f'COMPILE FAILED {test.name}', flush=True)
                continue
            with (output / (test.stem + '.console.log')).open('w') as log:
                result = subprocess.run([
                    str(cache / 'artifacts/engine/linux-x64/flutter_tester'),
                    '--non-interactive', '--disable-vm-service', '--enable-checked-mode',
                    '--verify-entry-points', '--enable-software-rendering',
                    '--skia-deterministic-rendering', '--test-fonts',
                    '--flutter-assets-dir=' + str(repo / 'build/unit_test_assets'), str(kernel),
                ], cwd=repo, env=dict(os.environ, FLUTTER_TEST='true'),
                    stdout=log, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode:
                failed.append(test.name)
            summary = [line for line in result_log.read_text().splitlines()
                       if line.startswith('RESULT')]
            print(f'{test.name}: {summary[-1] if summary else "NO RESULT"}; exit={result.returncode}', flush=True)
    print('FAILED SUITES:', failed, flush=True)
    raise SystemExit(bool(failed))


if __name__ == '__main__':
    main()
