import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('verify_apk_runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ApkRuntimeTest(unittest.TestCase):
    def test_original_succeeds_and_stripped_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root/'android/app/src/main/jniLibs/arm64-v8a/libcpp.so'
            original.parent.mkdir(parents=True)
            original.write_bytes(b'original-runtime-with-symbols')
            for name, data, valid in [('original',original.read_bytes(),True),('stripped',b'original-runtime',False)]:
                apk=root/f'{name}.apk'
                with ZipFile(apk,'w') as z: z.writestr('lib/arm64-v8a/libcpp.so',data)
                if valid: runtime.verify(apk,'arm64-v8a',root)
                else:
                    with self.assertRaises(ValueError): runtime.verify(apk,'arm64-v8a',root)

    def test_wrong_or_extra_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            apk=root/'wrong.apk'
            with ZipFile(apk,'w') as z:
                z.writestr('lib/arm64-v8a/libcpp.so',b'x')
                z.writestr('lib/x86_64/libcpp.so',b'x')
            with self.assertRaises(ValueError): runtime.verify(apk,'arm64-v8a',root)


if __name__ == '__main__': unittest.main()
