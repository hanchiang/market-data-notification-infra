"""The SSH policy check fails on each fixture pattern, passes the clean fixtures, and
holds its phase 1 allowance to exactly one resource."""
import subprocess
import sys
import tempfile
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

    def test_the_repo_scan_skips_the_fixtures_and_itself(self):
        result = check('--allow-public-ssh', 'instances/main.tf:aws_security_group.sg_22_80_443')
        self.assertNotIn(FIXTURES, result.stdout)
        self.assertNotIn('scripts/check_ssh_policy.py', result.stdout)


class AllowanceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        fixtures = REPO / FIXTURES
        (self.root / 'main.tf').write_text((fixtures / 'fail_inline_ingress.tf').read_text())
        (self.root / 'rule.tf').write_text((fixtures / 'fail_security_group_rule.tf').read_text())
        (self.root / 'ansible.cfg').write_text((fixtures / 'fail_ansible_cfg.cfg').read_text())

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_allowance_suppresses_only_the_named_resource(self):
        result = check('--allow-public-ssh', 'main.tf:aws_security_group.web', 'main.tf', 'rule.tf', cwd=self.root)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('main.tf:4: public-ssh', result.stdout)
        self.assertIn('allowed for phase 1 only: main.tf:aws_security_group.web', result.stdout)
        self.assertIn('rule.tf:1: public-ssh', result.stdout)

    def test_the_allowance_never_covers_another_rule(self):
        result = check('--allow-public-ssh', 'ansible.cfg:aws_security_group.web', 'ansible.cfg', cwd=self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ansible.cfg:2: ansible-host-key-checking-off', result.stdout)

    def test_a_stale_allowance_fails(self):
        (self.root / 'main.tf').write_text('resource "aws_security_group" "web" {\n}\n')
        result = check('--allow-public-ssh', 'main.tf:aws_security_group.web', 'main.tf', cwd=self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn('main.tf:1: stale-allowance: aws_security_group.web has no port 22 ingress', result.stdout)

    def test_the_allowance_fails_when_its_resource_gains_a_second_port_22_ingress(self):
        result = check('--allow-public-ssh', f'{FIXTURES}/allow_two_ingress.tf:aws_security_group.web',
                       f'{FIXTURES}/allow_two_ingress.tf')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'{FIXTURES}/allow_two_ingress.tf:1: allowance-too-wide: aws_security_group.web has 2 port 22 ingresses',
                      result.stdout)
        self.assertIn(f'{FIXTURES}/allow_two_ingress.tf:4: public-ssh', result.stdout)

    def test_the_health_allowance_expires_with_the_policy_allowance(self):
        fixture = f'{FIXTURES}/health_allowance.yml'
        result = check(fixture)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'{fixture}:4: stale-health-allowance', result.stdout)
        with_policy_allowance = check('--allow-public-ssh', f'{FIXTURES}/fail_inline_ingress.tf:aws_security_group.web',
                                      f'{FIXTURES}/fail_inline_ingress.tf', fixture)
        self.assertEqual(with_policy_allowance.returncode, 0, with_policy_allowance.stdout)

    def test_only_one_allowance_is_accepted(self):
        result = check('--allow-public-ssh', 'main.tf:aws_security_group.web',
                       '--allow-public-ssh', 'rule.tf:aws_security_group_rule.home', 'main.tf', cwd=self.root)
        self.assertEqual(result.returncode, 2)
        self.assertIn('one resource only', result.stderr)


if __name__ == '__main__':
    unittest.main()
