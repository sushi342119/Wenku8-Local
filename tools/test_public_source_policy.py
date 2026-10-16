import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('check_public_source.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PublicSourcePolicyTest(unittest.TestCase):
    def test_recognized_credentials_are_reported_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            credential = 'ghp_' + 'a' * 40
            (root / 'source.dart').write_text(credential)
            issues = policy.inspect(root)
            self.assertEqual(len(issues), 1)
            self.assertNotIn(credential, issues[0])

    def test_private_paths_signing_files_and_device_identifiers_are_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'key.properties').write_text('fixture')
            (root / 'machine.txt').write_text('/' + 'Users/private/project')
            (root / 'device.txt').write_text('adb -s ' + 'ABCD1234567890')
            self.assertEqual(len(policy.inspect(root)), 3)

    def test_public_api_identifier_and_embedded_binary_are_not_private_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'protocol.dart').write_text("const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';")
            (root / 'libcpp.so').write_bytes(b'\x7fELF\xff\x00')
            self.assertEqual(policy.inspect(root), [])


if __name__ == '__main__':
    unittest.main()
