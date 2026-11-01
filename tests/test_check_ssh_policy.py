"""The SSH policy check fails on each fixture pattern and passes the clean fixtures."""
import subprocess
import sys
import unittest
from pathlib import Path

from support import REPO

CHECKER = REPO / 'scripts' / 'check_ssh_policy.py'
FIXTURES = 'tests/ssh_policy_fixtures'

# (fixture, line, rule) the checker must report for each failing fixture.
EXPECTED = [
    ('fail_inline_ingress.tf', 4, 'public-ssh'),
    ('fail_ingress_ipv6_range.tf', 2, 'public-ssh'),
    ('fail_ingress_all_protocols.tf', 2, 'public-ssh'),
    ('fail_security_group_rule.tf', 1, 'public-ssh'),
    ('fail_vpc_ingress_rule.tf', 1, 'public-ssh'),
    ('fail_dynamic_ingress.tf', 2, 'public-ssh'),
    ('fail_connection_block.tf', 7, 'terraform-ssh-connection'),
    ('fail_strict_no.sh', 2, 'strict-host-key-checking-off'),
    ('fail_strict_accept_new.yml', 3, 'strict-host-key-checking-off'),
    ('fail_known_hosts_dev_null.sh', 2, 'known-hosts-dev-null'),
    ('fail_ansible_cfg.cfg', 2, 'ansible-host-key-checking-off'),
    ('fail_ansible_env.sh', 2, 'ansible-host-key-checking-off'),
    ('fail_keyscan.sh', 2, 'keyscan-into-known-hosts'),
    ('fail_unpinned_writer.sh', 3, 'unpinned-ssh-config'),
    ('fail_unpinned_writer_no_known_hosts.yml', 5, 'unpinned-ssh-config'),
]


def check(*args: str, cwd: Path = REPO) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(CHECKER), *args], cwd=cwd, capture_output=True, text=True)


class FixtureTest(unittest.TestCase):
    def test_every_failing_fixture_is_listed(self):
        on_disk = sorted(p.name for p in (REPO / FIXTURES).glob('fail_*'))
        self.assertEqual(on_disk, sorted(name for name, _, _ in EXPECTED))

    def test_each_failing_fixture_fails_naming_file_line_and_rule(self):
        for name, line, rule in EXPECTED:
            with self.subTest(fixture=name):
                result = check(f'{FIXTURES}/{name}')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f'{FIXTURES}/{name}:{line}: {rule}:', result.stdout)

    def test_clean_fixtures_pass(self):
        for name in ('pass_clean.tf', 'pass_clean.sh'):
            with self.subTest(fixture=name):
                result = check(f'{FIXTURES}/{name}')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_repo_scan_is_clean_and_skips_the_fixtures_and_itself(self):
        result = check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(FIXTURES, result.stdout)
        self.assertNotIn('scripts/check_ssh_policy.py', result.stdout)


if __name__ == '__main__':
    unittest.main()
