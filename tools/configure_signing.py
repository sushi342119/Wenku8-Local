"""Write Java properties without shell-interpolating secret values."""
import base64
import os
from pathlib import Path

def escape(value):
    return "".join("\\u%04x" % ord(ch) if ord(ch) < 32 or ord(ch) > 126
                   else "\\" + ch if ch in "\\:= #!" else ch for ch in value)

def main():
    names = ("KEYSTORE", "STORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD")
    if any(not os.environ.get(name) for name in names):
        raise SystemExit("All four Android signing secrets must be configured")
    key = Path("android/release.keystore")
    key.write_bytes(base64.b64decode(os.environ["KEYSTORE"], validate=True))
    key.chmod(0o600)
    props = {"storeFile": "release.keystore", "storePassword": os.environ["STORE_PASSWORD"],
             "keyAlias": os.environ["KEY_ALIAS"], "keyPassword": os.environ["KEY_PASSWORD"]}
    target = Path("android/key.properties")
    target.write_text("".join(k + "=" + escape(v) + "\n" for k, v in props.items()), encoding="ascii")
    target.chmod(0o600)

if __name__ == "__main__":
    main()
