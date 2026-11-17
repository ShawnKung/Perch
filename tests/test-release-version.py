#!/usr/bin/env python3
import pathlib
import plistlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as tmp:
    plist = pathlib.Path(tmp) / "Info.plist"
    original = {"CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "154"}

    def run(tag, number):
        plist.write_bytes(plistlib.dumps(original))
        result = subprocess.run(
            ["bash", str(root / "scripts/prepare-release.sh"), tag, number, str(plist)],
            capture_output=True,
        )
        return result.returncode, plistlib.loads(plist.read_bytes())

    status, value = run("v1.2.3", "7")
    assert status == 0 and value == {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "161"}
    for tag, number in [("v01.2.3", "7"), ("v1.2", "7"), ("v1.2.3-rc.1", "7"), ("v1.2.3", "0")]:
        status, value = run(tag, number)
        assert status != 0 and value == original, (tag, number)
print("Release version checks passed")
