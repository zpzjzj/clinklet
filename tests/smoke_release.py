"""Verify and launch a built DMG without Python in the application's environment."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout


def main():
    release_dir = Path(sys.argv[1]).resolve()
    for line in (release_dir / 'SHA256SUMS.txt').read_text().splitlines():
        expected, filename = line.split(maxsplit=1)
        assert hashlib.sha256((release_dir / filename).read_bytes()).hexdigest() == expected
    dmg = next(release_dir.glob('*.dmg'))
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        mount = folder / 'mount'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg))
        try:
            app = mount / 'Clinklet.app'
            binary = app / 'Contents/MacOS/KeychainSecrets'
            run('codesign', '--verify', '--deep', '--strict', str(app))
            run('lipo', str(binary), '-verify_arch', 'arm64', 'x86_64')
            assert not list(app.rglob('*.py'))
            assert not [p for p in app.rglob('*') if 'python' in p.name.lower()]
            for line in run('otool', '-L', str(binary)).splitlines():
                if line.startswith('\t'):
                    assert line.strip().startswith(('/System/Library/', '/usr/lib/')), line
            fixture = folder / 'index.json'
            fixture.write_text(json.dumps({'RELEASE_DEMO': {'env': 'DEMO_TOKEN', 'note': 'Synthetic release smoke test'}}))
            before = fixture.read_bytes()
            architectures = ['x86_64']
            if run('sysctl', '-n', 'hw.optional.arm64').strip() == '1':
                architectures.insert(0, 'arm64')
            for architecture in architectures:
                env = dict(os.environ, PATH='/usr/bin:/bin', KEYCHAIN_SECRETS_INDEX_PATH=str(fixture))
                process = subprocess.Popen(['/usr/bin/arch', '-' + architecture, str(binary)], env=env,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    time.sleep(2)
                    assert process.poll() is None, process.communicate()
                    script = f'tell application "System Events" to get name of every window of (first application process whose unix id is {process.pid})'
                    visible = False
                    for _ in range(10):
                        if run('osascript', '-e', script).strip() == 'Clinklet':
                            visible = True
                            break
                        time.sleep(0.5)
                    assert visible, f'No Clinklet window registered for PID {process.pid}'
                    assert fixture.read_bytes() == before
                    print(f'{architecture}: signed packaged app launches with a Clinklet window and system-only PATH')
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
            extracted = folder / 'unzipped'
            run('ditto', '-x', '-k', str(next(release_dir.glob('*.zip'))), str(extracted))
            assert (extracted / 'Clinklet.app/Contents/MacOS/KeychainSecrets').read_bytes() == binary.read_bytes()
            run('codesign', '--verify', '--deep', '--strict', str(extracted / 'Clinklet.app'))
            print('DMG, ZIP, checksums, universal architectures, dependency isolation and metadata integrity verified')
        finally:
            run('hdiutil', 'detach', str(mount))


if __name__ == '__main__':
    main()
