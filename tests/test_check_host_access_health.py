"""The host access health job alerts on a port 22 rule and on a silent login-line push.
The silent case is an EMPTY Datapoints list, because AWS/Logs publishes nothing for a
group that received nothing; that branch is the one the check exists for."""
import json
import unittest

from support import REPO, FakeBin

SCRIPT = REPO / 'instances' / 'scripts' / 'check_host_access_health.sh'


def group(*permissions):
    return {'SecurityGroups': [{'GroupName': 'sg_22_80_443', 'IpPermissions': list(permissions)}]}


def tcp(port, cidr, description=None):
    source = {'CidrIp': cidr}
    if description:
        source['Description'] = description
    return {'IpProtocol': 'tcp', 'FromPort': port, 'ToPort': port, 'IpRanges': [source]}


WEB = [tcp(80, '0.0.0.0/0'), tcp(443, '0.0.0.0/0')]
TERRAFORM_22 = tcp(22, '0.0.0.0/0')
BREAK_GLASS_22 = tcp(22, '203.0.113.0/24', 'break-glass 2026-10-28T09:00Z')
EVENTS = {'Label': 'IncomingLogEvents', 'Datapoints': [{'Sum': 7.0, 'Unit': 'None'}]}
SILENT = {'Label': 'IncomingLogEvents', 'Datapoints': []}


class HostAccessHealthTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeBin()
        self.fake.add('curl', 'exit 0')
        self.env = {'STOCKS_TELEGRAM_DEV_BOT_TOKEN': '123:SYNTHETIC', 'STOCKS_TELEGRAM_DEV_ID': '-100'}

    def tearDown(self):
        self.fake.cleanup()

    def check(self, groups, metric, *args):
        (self.fake.dir / 'groups.json').write_text(json.dumps(groups))
        (self.fake.dir / 'metric.json').write_text(json.dumps(metric))
        self.fake.add('aws', f'''
case "$1 $2" in
  "ec2 describe-security-groups") cat {self.fake.dir}/groups.json ;;
  "cloudwatch get-metric-statistics") cat {self.fake.dir}/metric.json ;;
  *) exit 99 ;;
esac''')
        return self.fake.run([str(SCRIPT), *args], env=self.env)

    def alert_text(self):
        [call] = self.fake.calls('curl')
        return ' '.join(call['argv'])

    def test_an_empty_datapoints_list_alerts(self):
        result = self.check(group(*WEB), SILENT)
        self.assertEqual(result.returncode, 1)
        self.assertIn('no SSH login lines reached /market-data-notification/sshd in 48h', self.alert_text())

    def test_healthy_sends_nothing(self):
        result = self.check(group(*WEB), EVENTS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fake.calls('curl'), [])

    def test_any_port_22_rule_alerts(self):
        for rule in (TERRAFORM_22, BREAK_GLASS_22, {'IpProtocol': '-1', 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]},
                     {'IpProtocol': 'tcp', 'FromPort': 0, 'ToPort': 1024, 'Ipv6Ranges': [{'CidrIpv6': '::/0'}]}):
            with self.subTest(rule=rule):
                self.fake.log.unlink(missing_ok=True)
                result = self.check(group(*WEB, rule), EVENTS)
                self.assertEqual(result.returncode, 1)
                self.assertIn('port 22 is open on sg_22_80_443 to 1 source(s)', self.alert_text())

    def test_the_phase_1_allowance_tolerates_only_the_terraform_rule(self):
        self.assertEqual(self.check(group(*WEB, TERRAFORM_22), EVENTS, '--allow-terraform-public-22').returncode, 0)
        result = self.check(group(*WEB, TERRAFORM_22, BREAK_GLASS_22), EVENTS, '--allow-terraform-public-22')
        self.assertEqual(result.returncode, 1)
        self.assertIn('to 1 source(s)', self.alert_text())

    def test_a_missing_security_group_alerts(self):
        result = self.check({'SecurityGroups': []}, EVENTS)
        self.assertEqual(result.returncode, 1)
        self.assertIn('security group sg_22_80_443 not found', self.alert_text())

    def test_the_bot_token_is_not_in_curl_argv(self):
        self.check(group(*WEB), SILENT)
        [call] = self.fake.calls('curl')
        self.assertFalse(any('123:SYNTHETIC' in arg for arg in call['argv']))
        self.assertIn('123:SYNTHETIC', call['stdin'])


if __name__ == '__main__':
    unittest.main()
