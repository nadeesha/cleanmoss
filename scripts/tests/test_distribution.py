"""Verify streamed install behavior without changing the current Mac's settings."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution_server', ROOT / 'scripts/distribution-server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cleanmoss-network-check-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.environment = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], TMPDIR=str(self.root) + '/', CLEANMOSS_TEST_DOWNLOAD=str(self.root / 'download.log'), CLEANMOSS_TEST_INSTALL=str(self.root / 'install.log'))
        self.executable('curl', '''#!/bin/bash
printf '%s\n' "$@" > "$CLEANMOSS_TEST_DOWNLOAD"
while (( $# )); do
  if [[ "$1" == -o ]]; then cp "$CLEANMOSS_TEST_ARCHIVE" "$2"; exit; fi
  shift
done
exit 1
''')

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def render(self, archive):
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        source = (ROOT / 'scripts/install-network.sh').read_text().replace('@@ARCHIVE_URL@@', "'http://example.test:52742/cleanmoss/releases/release.zip'").replace('@@SHA256@@', repr(digest))
        self.environment['CLEANMOSS_TEST_ARCHIVE'] = str(archive)
        return source

    def run_script(self, source, *arguments):
        return subprocess.run(['/bin/bash', '-s', '--', *arguments], input=source, text=True, capture_output=True, env=self.environment)

    def real_archive(self):
        metadata = json.loads((ROOT / 'dist/network/release.json').read_text())
        return ROOT / 'dist/network/releases' / metadata['sha256'] / 'cleanmoss-macos-universal.zip'

    def fake_archive(self):
        payload = self.root / 'payload'
        app = payload / 'Cleanmoss.app/Contents'
        (app / 'MacOS').mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.cleanmoss.mac'}))
        (app / 'MacOS/Cleanmoss').write_text('#!/bin/bash\nexit 0\n')
        (app / 'MacOS/Cleanmoss').chmod(0o755)
        cli = payload / 'cleanmoss'
        cli.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$CLEANMOSS_TEST_INSTALL"\n')
        cli.chmod(0o755)
        archive = self.root / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as stream:
            for file in payload.rglob('*'):
                if file.is_file(): stream.write(file, file.relative_to(payload))
        self.executable('codesign', '#!/bin/bash\nexit 0\n')
        return archive

    def test_real_release_download_signature_and_cleanup(self):
        result = self.run_script(self.render(self.real_archive()), '--verify-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Verified universal Cleanmoss release', result.stdout)
        self.assertFalse(list(self.root.glob('cleanmoss-install.*')))
        self.assertFalse((self.root / 'install.log').exists())

    def test_corrupt_download_is_rejected_before_extraction(self):
        archive = self.real_archive()
        source = self.render(archive)
        bad = self.root / 'bad.zip'
        bad.write_bytes(archive.read_bytes() + b'corrupt')
        self.environment['CLEANMOSS_TEST_ARCHIVE'] = str(bad)
        result = self.run_script(source, '--verify-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum failed', result.stderr)
        self.assertFalse(list(self.root.glob('cleanmoss-install.*')))

    def test_truncated_stream_does_not_start_download(self):
        complete = self.render(self.real_archive())
        source = complete.rsplit('\n{\n  main "$@"\n}', 1)[0] + '\n'
        self.assertEqual(self.run_script(source).returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())
        self.assertNotEqual(self.run_script(source[:len(source) // 2]).returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())
        self.assertNotEqual(self.run_script(complete.rsplit('\n}', 1)[0]).returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())

    def test_default_install_and_flag_forwarding_on_mac_bash(self):
        source = self.render(self.fake_archive())
        result = self.run_script(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'install.log').read_text(), 'install\n')
        result = self.run_script(source, '--no-launch', '--no-login', '--keep-system-shortcut')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'install.log').read_text().splitlines(), ['install', '--no-launch', '--no-login', '--keep-system-shortcut'])
        self.assertFalse(list(self.root.glob('cleanmoss-install.*')))

    def test_old_macos_and_unknown_options_fail_before_download(self):
        source = self.render(self.real_archive())
        self.executable('sw_vers', '#!/bin/bash\necho 13.7\n')
        result = self.run_script(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires macOS 14', result.stderr)
        self.assertFalse((self.root / 'download.log').exists())
        result = self.run_script(source, '--unknown')
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'download.log').exists())

    def test_intel_client_accepts_verified_universal_release(self):
        self.executable('uname', '#!/bin/bash\nif [[ "$1" == -s ]]; then echo Darwin; else echo x86_64; fi\n')
        result = self.run_script(self.render(self.real_archive()), '--verify-only')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_server_only_serves_release_assets_and_blocks_escape(self):
        handler = object.__new__(server.ReleaseHandler)
        handler.directory = str(self.root)
        installer = self.root / 'install.sh'
        installer.write_text('example')
        self.assertEqual(handler.release_path('/install.sh'), installer.resolve())
        self.assertEqual(handler.release_path('/cleanmoss/install.sh'), installer.resolve())
        (self.root / 'private.txt').write_text('not published')
        for url in ['/', '/cleanmoss/', '/private.txt', '/%2e%2e/private.txt', '/cleanmoss/../install.sh', '/cleanmoss/%5cinstall.sh']:
            self.assertIsNone(handler.release_path(url), url)
        archive = self.root / 'releases' / ('a' * 64) / 'cleanmoss-macos-universal.zip'
        archive.parent.mkdir(parents=True)
        outside = self.root.parent / ('outside-' + self.root.name)
        outside.write_text('outside root')
        self.addCleanup(outside.unlink)
        archive.symlink_to(outside)
        self.assertIsNone(handler.release_path('/releases/' + 'a' * 64 + '/cleanmoss-macos-universal.zip'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
