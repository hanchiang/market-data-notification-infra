"""wait_for_ssm_online.sh against a fake `aws` that replays describe-instance-information replies."""
import json
import time
import unittest
from datetime import datetime, timezone

from support import REPO, FakeBin

SCRIPT = REPO / 'instances' / 'scripts' / 'helper' / 'wait_for_ssm_online.sh'
INSTANCE = 'i-0123456789abcdef0'


def reply(status=None, last_ping=None):
    if status is None:
        return {'InstanceInformationList': []}
    return {'InstanceInformationList': [{'InstanceId': INSTANCE, 'PingStatus': status, 'LastPingDateTime': last_ping}]}


def iso(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()


class WaitForSsmOnlineTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeBin()

    def tearDown(self):
        self.fake.cleanup()

    def replies(self, *bodies):
        """The fake returns the bodies in order, then repeats the last."""
        for index, body in enumerate(bodies):
            (self.fake.dir / f'reply{index}.json').write_text(json.dumps(body))
        self.fake.add('aws', f'''
n=$(grep -c '"cmd": "aws"' {self.fake.log})
last={len(bodies) - 1}
i=$(( n - 1 < last ? n - 1 : last ))
cat {self.fake.dir}/reply$i.json''')

    def wait(self, *args):
        return self.fake.run([str(SCRIPT), INSTANCE, '--interval', '0', *args])

    def test_waits_through_offline_until_online(self):
        self.replies(reply(), reply('ConnectionLost', iso(1)), reply('Online', iso(2)))
        result = self.wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.fake.calls('aws')), 3)

    def test_with_a_start_time_a_stale_online_does_not_count(self):
        started = int(time.time()) - 60
        self.replies(reply('Online', iso(started - 300)), reply('Online', iso(started + 30)))
        result = self.wait('--since', str(started))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.fake.calls('aws')), 2)
        self.assertIn('from before the start', result.stdout)

    def test_epoch_ping_times_from_cli_v1_are_read(self):
        started = int(time.time()) - 60
        self.replies(reply('Online', started + 30.5))
        self.assertEqual(self.wait('--since', str(started)).returncode, 0)

    def test_times_out_when_only_a_stale_online_is_seen(self):
        started = int(time.time())
        self.replies(reply('Online', iso(started - 300)))
        result = self.wait('--since', str(started), '--timeout', '0')
        self.assertEqual(result.returncode, 1)
        self.assertIn('not Online after 0 seconds', result.stderr)

    def test_times_out_when_the_instance_never_registers(self):
        self.replies(reply())
        self.assertEqual(self.wait('--timeout', '0').returncode, 1)

    def test_an_aws_error_stops_at_once(self):
        self.fake.add('aws', 'echo "AccessDeniedException" >&2; exit 254')
        result = self.wait('--timeout', '300')
        self.assertEqual(result.returncode, 254)
        self.assertEqual(len(self.fake.calls('aws')), 1)

    def test_bad_usage(self):
        self.replies(reply())
        self.assertEqual(self.fake.run([str(SCRIPT)]).returncode, 2)
        self.assertEqual(self.wait('--since', 'yesterday').returncode, 2)


if __name__ == '__main__':
    unittest.main()
