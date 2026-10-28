"""start.sh takes its inputs from the environment (Goal 9): positional arguments are
refused before anything runs, and the deploy token never reaches a process's argv."""
import subprocess
import unittest

from support import REPO, FakeBin

START = REPO / 'instances' / 'scripts' / 'start.sh'
GITHUB_API = REPO / 'instances' / 'scripts' / 'helper' / 'github_api.sh'
TOKEN = 'ghp_SYNTHETICTOKENFORTESTS0000000000000000'


class StartShTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeBin()
        for name in ('aws', 'ansible-playbook', 'session-manager-plugin', 'curl'):
            self.fake.add(name, 'exit 0')
        self.env = {
            'START_ENV_FILE': str(self.fake.dir / 'absent.env'),
            'ADMIN_EMAIL': 'admin@example.com', 'AWS_REGION': 'us-east-1', 'DOMAIN': 'example.com',
            'ROUTE53_HOSTED_ZONE_ID': 'Z0000000000000', 'SSH_USER': 'ubuntu',
            'SSH_PRIVATE_KEY_PATH': str(self.fake.dir / 'key'),
            'MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN': TOKEN,
        }

    def tearDown(self):
        self.fake.cleanup()

    def test_positional_arguments_are_refused_before_anything_runs(self):
        for argv in ([TOKEN, 'ubuntu', '/tmp/key'], ['--skip-deploy', 'ubuntu', '/tmp/key']):
            with self.subTest(argv=argv[0]):
                result = self.fake.run([str(START), *argv], env=self.env)
                self.assertEqual(result.returncode, 1)
                self.assertIn('takes no positional arguments', result.stderr)
                self.assertIn('MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN', result.stderr)
                self.assertEqual(self.fake.calls(), [])

    def test_a_known_hosts_file_without_the_alias_pin_stops_before_aws(self):
        known_hosts = self.fake.dir / 'known_hosts'
        known_hosts.write_text('other-host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQEefJ+1LCMqYlb2hNWvVPb89dMIx9Tpk7Fdl1cZ1dD\n')
        result = self.fake.run([str(START)], env={**self.env, 'SSH_KNOWN_HOSTS_FILE': str(known_hosts)})
        self.assertEqual(result.returncode, 1)
        self.assertIn('holds no host key for market-data-notification-production', result.stderr)
        self.assertEqual(self.fake.calls('aws'), [])

    def test_the_token_goes_to_curl_on_stdin_never_in_argv_or_a_trace(self):
        result = self.fake.run(
            ['bash', '-x', '-c', f'source {GITHUB_API}; github_api -X POST https://api.github.com/x -d "{{}}"'],
            env={'MARKET_DATA_NOTIFICATION_DEPLOY_TOKEN': TOKEN})
        self.assertEqual(result.returncode, 0, result.stderr)
        [call] = self.fake.calls('curl')
        self.assertFalse(any(TOKEN in arg for arg in call['argv']), call['argv'])
        self.assertIn('--config', call['argv'])
        self.assertIn(f'header = "Authorization: token {TOKEN}"', call['stdin'])
        self.assertNotIn(TOKEN, result.stderr)  # the -x trace

    def test_github_api_refuses_to_run_without_a_token(self):
        result = self.fake.run(['bash', '-c', f'source {GITHUB_API}; github_api https://api.github.com/x'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fake.calls('curl'), [])


if __name__ == '__main__':
    unittest.main()
