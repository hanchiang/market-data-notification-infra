"""pin_host_key.sh reads host keys from saved first-boot console output (scenario 11).
The fixtures hold synthetic keys generated for these tests, never a real host's."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import REPO

SCRIPT = REPO / 'instances' / 'scripts' / 'pin_host_key.sh'
FIXTURES = REPO / 'tests' / 'fixtures'
ALIAS = 'market-data-notification-production'
# The synthetic keys' fingerprints, as `ssh-keygen -lf` printed them when the fixture was made.
EXPECTED_FINGERPRINTS = {
    'SHA256:ErddObZzvuqrxI7N92+aGkZnsSxPF77yuxNHj4xv5D8',  # ECDSA
    'SHA256:sKx/lGcAWyALapknaROVXCfDDMYCgHHdQKpic0CqesA',  # ED25519
    'SHA256:Bgze5Wir5nELUEHpC3+38Vs0rvjvkOYsWPxa8UCEnaQ',  # RSA
}


def pin(fixture: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(SCRIPT), '--console-file', str(FIXTURES / fixture)],
                          capture_output=True, text=True)


class PinHostKeyTest(unittest.TestCase):
    def test_first_boot_output_yields_alias_keyed_lines_that_ssh_accepts(self):
        result = pin('console_first_boot.txt')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [line for line in result.stdout.splitlines() if line.startswith(ALIAS + ' ')]
        self.assertEqual(sorted(line.split()[1] for line in lines),
                         ['ecdsa-sha2-nistp256', 'ssh-ed25519', 'ssh-rsa'])
        with tempfile.NamedTemporaryFile('w', suffix='known_hosts') as known_hosts:
            known_hosts.write('\n'.join(lines) + '\n')
            known_hosts.flush()
            listed = subprocess.run(['ssh-keygen', '-lf', known_hosts.name], capture_output=True, text=True, check=True)
            found = subprocess.run(['ssh-keygen', '-F', ALIAS, '-f', known_hosts.name], capture_output=True, text=True)
        self.assertEqual({line.split()[1] for line in listed.stdout.splitlines()}, EXPECTED_FINGERPRINTS)
        self.assertEqual(found.returncode, 0)

    def test_dsa_is_never_pinned(self):
        self.assertIn('ssh-dss', (FIXTURES / 'console_first_boot.txt').read_text())
        self.assertNotIn('ssh-dss', pin('console_first_boot.txt').stdout)

    def test_a_later_boot_without_the_key_block_names_the_fallback(self):
        result = pin('console_later_boot.txt')
        self.assertEqual(result.returncode, 2)
        self.assertIn('admin shell session', result.stderr)
        self.assertNotIn(ALIAS, result.stdout)

    def test_a_key_that_disagrees_with_the_fingerprint_block_is_refused(self):
        result = pin('console_fingerprint_mismatch.txt')
        self.assertEqual(result.returncode, 3)
        self.assertNotIn(ALIAS + ' ssh-', result.stdout)


if __name__ == '__main__':
    unittest.main()
