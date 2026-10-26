"""A failed build must preserve the existing application bundle."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'macOS installer')
class InstallerContracts(unittest.TestCase):
    def test_build_failure_preserves_existing_installation(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'scripts').mkdir()
            shutil.copy(root / 'scripts/install_macos_app.sh', folder / 'scripts')
            target = folder / 'Existing.app'
            target.mkdir()
            sentinel = target / 'sentinel'
            sentinel.write_text('previous-installation')
            # No source file: the real compiler fails before installation is published.
            result = subprocess.run(
                ['bash', str(folder / 'scripts/install_macos_app.sh')],
                env=dict(os.environ, KEYCHAIN_SECRETS_APP_DIR=str(target)),
                capture_output=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), 'previous-installation')
            self.assertEqual(list(folder.glob('.keychain-secrets-build.*')), [])


if __name__ == '__main__':
    unittest.main()
