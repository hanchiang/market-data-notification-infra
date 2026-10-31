"""A job that reports a failed job must carry a status function in its `if`.

Without one GitHub adds success(), so the job is skipped on the very failure it reports. The
start and stop workflows' failure alerts sat dead that way from 2023 until 2026-10-31. Reads
single-line `if:` values as text, because the CI job installs no YAML parser.
"""
import re
import unittest

from support import REPO

WORKFLOWS = REPO / '.github' / 'workflows'
PLAYBOOK = REPO / 'instances' / 'ansible' / 'playbooks' / 'ssm-agent.yml'
ALERTING_WORKFLOWS = ('start_market_data_notification.yml', 'stop_market_data_notification.yml')
IF_LINE = re.compile(r'^\s*if:\s*(.*)$', re.MULTILINE)
STATUS_FUNCTION = re.compile(r'\b(always|failure|cancelled)\(\)')
ALERT_NEEDS = re.compile(r'^  notify_unsucc\w+:\n(?:.*\n)*?\s+needs: \[(.*)\]$', re.MULTILINE)
ALERT_CONDITION = "if: ${{ always() && contains(needs.*.result, 'failure') }}"
RETRIES = re.compile(r'^\s+ansible_ssh_retries: 10$', re.MULTILINE)


def failure_conditions(text):
    # `!=` too: `needs.a.result != 'success'` is true only on a result success() already skips.
    return [c for c in IF_LINE.findall(text)
            if '.result' in c and ("'failure'" in c or '!=' in c)]


class FailureAlertConditionTest(unittest.TestCase):
    def test_every_condition_on_a_failed_job_has_a_status_function(self):
        for workflow in sorted(WORKFLOWS.glob('*.yml')):
            for condition in failure_conditions(workflow.read_text()):
                with self.subTest(workflow=workflow.name, condition=condition):
                    self.assertRegex(condition, STATUS_FUNCTION)

    def test_the_start_and_stop_alerts_are_found(self):
        # Guards the check itself: a reworded condition must not silently match nothing.
        for name in ALERTING_WORKFLOWS:
            self.assertTrue(failure_conditions((WORKFLOWS / name).read_text()), name)

    def test_the_alerts_cover_the_check_jobs(self):
        # A failed check leaves the start or stop job skipped, not failed.
        for name in ALERTING_WORKFLOWS:
            text = (WORKFLOWS / name).read_text()
            needs = ALERT_NEEDS.search(text).group(1)
            with self.subTest(workflow=name):
                self.assertIn('check_timezone', needs)
                self.assertIn('health_check', needs)
                # Listing the checks does nothing unless the condition reads them too.
                self.assertIn(ALERT_CONDITION, text)


class AgentRestartRetriesTest(unittest.TestCase):
    def test_only_the_tasks_after_the_refresh_retry_ssh(self):
        # Missing, a session lost in the agent restart aborts the play. On any other task,
        # or the play, every failure slows down, a wrong host key included.
        header, *tasks = PLAYBOOK.read_text().split('\n    - name: ')
        self.assertIsNone(RETRIES.search(header))
        self.assertEqual(
            [task.splitlines()[0] for task in tasks if RETRIES.search(task)],
            ['Wait for the refresh to finish', 'Read the agent version after any refresh'])


if __name__ == '__main__':
    unittest.main()
