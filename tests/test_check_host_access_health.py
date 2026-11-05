"""The host access health job alerts on a port 22 rule and on a silent login-line push.
The silent case is an EMPTY Datapoints list, because AWS/Logs publishes nothing for a
group that received nothing; that branch is the one the check exists for. Port 22 is
checked on the groups attached to the host instance, never on a group found by name."""
import json
import unittest

from support import REPO, FakeBin

SCRIPT = REPO / 'instances' / 'scripts' / 'check_host_access_health.sh'


def group(*permissions):
    return {'SecurityGroups': [{'GroupName': 'sg_22_80_443', 'GroupId': 'sg-host', 'IpPermissions': list(permissions)}]}


def host(*group_ids):
    return {'Reservations': [{'Instances': [{'SecurityGroups': [{'GroupId': g} for g in group_ids]}]}]}


def tcp(port, cidr, description=None):
    source = {'CidrIp': cidr}
    if description:
        source['Description'] = description
    return {'IpProtocol': 'tcp', 'FromPort': port, 'ToPort': port, 'IpRanges': [source]}


WEB = [tcp(80, '0.0.0.0/0'), tcp(443, '0.0.0.0/0')]
PUBLIC_22 = tcp(22, '0.0.0.0/0')
BREAK_GLASS_22 = tcp(22, '203.0.113.0/24', 'break-glass 2026-10-28T09:00Z')
EVENTS = {'Label': 'IncomingLogEvents', 'Datapoints': [{'Sum': 7.0, 'Unit': 'None'}]}
SILENT = {'Label': 'IncomingLogEvents', 'Datapoints': []}
HOST = host('sg-host')
OPEN_22 = 'port 22 is open on sg_22_80_443 (sg-host) to'


class HostAccessHealthTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeBin()
        self.fake.add('curl', 'exit 0')
        self.env = {'STOCKS_TELEGRAM_DEV_BOT_TOKEN': '123:SYNTHETIC', 'STOCKS_TELEGRAM_DEV_ID': '-100'}

    def tearDown(self):
        self.fake.cleanup()

    def check(self, groups, metric, *args, instances=HOST):
        (self.fake.dir / 'instances.json').write_text(json.dumps(instances))
        (self.fake.dir / 'groups.json').write_text(json.dumps(groups))
        (self.fake.dir / 'metric.json').write_text(json.dumps(metric))
        self.fake.add('aws', f'''
case "$1 $2" in
  "ec2 describe-instances") cat {self.fake.dir}/instances.json ;;
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
        for rule in (PUBLIC_22, BREAK_GLASS_22, {'IpProtocol': '-1', 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]},
                     {'IpProtocol': 'tcp', 'FromPort': 0, 'ToPort': 1024, 'Ipv6Ranges': [{'CidrIpv6': '::/0'}]},
                     {'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22, 'PrefixListIds': [{'PrefixListId': 'pl-1'}]},
                     {'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22, 'UserIdGroupPairs': [{'GroupId': 'sg-1'}]},
                     {'IpProtocol': '6', 'FromPort': 22, 'ToPort': 22, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}):
            with self.subTest(rule=rule):
                self.fake.log.unlink(missing_ok=True)
                result = self.check(group(*WEB, rule), EVENTS)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f'{OPEN_22} 1 source(s)', self.alert_text())

    def test_each_source_on_a_port_22_rule_counts(self):
        rule = {'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}],
                'Ipv6Ranges': [{'CidrIpv6': '::/0'}], 'PrefixListIds': [{'PrefixListId': 'pl-1'}],
                'UserIdGroupPairs': [{'GroupId': 'sg-1'}]}
        result = self.check(group(*WEB, rule), EVENTS)
        self.assertEqual(result.returncode, 1)
        self.assertIn('to 4 source(s)', self.alert_text())

    def test_any_argument_is_refused(self):
        self.assertEqual(self.check(group(*WEB), EVENTS, '--anything').returncode, 2)
        self.assertEqual(self.fake.calls('curl'), [])

    def test_no_host_instance_alerts(self):
        result = self.check(group(*WEB), EVENTS, instances={'Reservations': []})
        self.assertEqual(result.returncode, 1)
        self.assertIn('could not read security groups for an instance tagged Name=market_data_notification', self.alert_text())
        self.assertFalse([c for c in self.fake.calls('aws') if c['argv'][:2] == ['ec2', 'describe-security-groups']])

    def test_groups_come_from_the_host_instance_not_by_name(self):
        # A group name is unique only within a VPC, so only the host's own group ids are asked for.
        self.check(group(*WEB), EVENTS, instances=host('sg-host', 'sg-extra', 'sg-host'))
        [instances_call] = [c for c in self.fake.calls('aws') if c['argv'][:2] == ['ec2', 'describe-instances']]
        self.assertIn('Name=tag:Name,Values=market_data_notification', instances_call['argv'])
        self.assertIn('Name=instance-state-name,Values=pending,running,stopping,stopped', instances_call['argv'])
        [groups_call] = [c for c in self.fake.calls('aws') if c['argv'][:2] == ['ec2', 'describe-security-groups']]
        argv = groups_call['argv']
        self.assertEqual(argv[argv.index('--group-ids') + 1:argv.index('--output')], ['sg-extra', 'sg-host'])
        self.assertNotIn('--filters', argv)

    def test_the_bot_token_is_not_in_curl_argv(self):
        self.check(group(*WEB), SILENT)
        [call] = self.fake.calls('curl')
        self.assertFalse(any('123:SYNTHETIC' in arg for arg in call['argv']))
        self.assertIn('123:SYNTHETIC', call['stdin'])


if __name__ == '__main__':
    unittest.main()
