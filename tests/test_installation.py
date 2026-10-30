from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROUTER = Path(__file__).resolve().parents[1] / 'router'


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'image'
        self.root.mkdir()
        self.key = Path(self.temp.name) / 'test-key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'test-only', '-f', str(self.key)], check=True)
        self.env = dict(os.environ, DESTDIR=str(self.root))
        self.auth = self.root / 'etc/dropbear/authorized_keys'
        self.auth.parent.mkdir(parents=True)
        self.original = '# existing administrator key is preserved\n'
        self.auth.write_text(self.original)

    def tearDown(self):
        self.temp.cleanup()

    def install(self):
        return subprocess.run(['sh', str(ROUTER / 'install.sh'), '--public-key', str(self.key.with_suffix('.pub')), '--profile', '/etc/mu300/vpn/profiles/example/config.yaml'], env=self.env, capture_output=True, text=True)

    def test_install_is_restricted_idempotent_and_uninstall_preserves_other_keys(self):
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.install().returncode, 0)
        auth = self.auth.read_text()
        self.assertTrue(auth.startswith(self.original))
        self.assertEqual(auth.count('test-only'), 1)
        for option in ['command=', 'no-port-forwarding', 'no-agent-forwarding', 'no-X11-forwarding', 'no-pty']:
            self.assertIn(option, auth)
        self.assertEqual(self.auth.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'etc/u30-monitor').stat().st_mode & 0o777, 0o700)
        result = subprocess.run(['sh', str(ROUTER / 'uninstall.sh')], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.original.strip(), self.auth.read_text())
        self.assertNotIn('test-only', self.auth.read_text())

    def test_refuses_an_existing_unrestricted_key(self):
        self.auth.write_text(self.original + self.key.with_suffix('.pub').read_text())
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dedicated', result.stderr)

    def test_refuses_unknown_files_without_an_installation_marker(self):
        helper = self.root / 'usr/libexec/u30-menubar-readonly'
        helper.parent.mkdir(parents=True)
        helper.write_text('unrelated helper')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(helper.read_text(), 'unrelated helper')

    def test_empty_marker_never_erases_authorized_keys(self):
        self.assertEqual(self.install().returncode, 0)
        before = self.auth.read_text()
        (self.root / 'etc/u30-monitor/installed-by-u30-flow').write_text('')
        result = subprocess.run(['sh', str(ROUTER / 'uninstall.sh')], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auth.read_text(), before)


if __name__ == '__main__':
    unittest.main()
