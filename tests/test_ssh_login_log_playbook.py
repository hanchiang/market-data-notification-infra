"""The CloudWatch agent playbook changes nothing on a run with nothing to change, and the
agent reads a file it can open without supplementary groups.

dpkg reports the package as the upstream version plus a Debian revision ("-1"), so the
install condition must compare against that form: comparing the bare version would
reinstall on every start. The install condition, the restart decision and the post-start
shell are evaluated through Ansible's templar; the other tests check the playbook's YAML.
Skipped where Ansible is not installed (the CI job installs none); they run wherever the
start script runs.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import REPO

PLAYBOOK = REPO / 'instances' / 'ansible' / 'playbooks' / 'ssh-login-log.yml'

try:
    import yaml
    from ansible.parsing.dataloader import DataLoader
    from ansible.template import Templar, trust_as_template
except ImportError:  # pragma: no cover - depends on the machine
    yaml = None


def _play():
    return yaml.safe_load(PLAYBOOK.read_text())[0]


def _task(tasks, prefix):
    return next(t for t in tasks if t.get('name', '').startswith(prefix))


@unittest.skipIf(yaml is None, 'ansible-core 2.19+ and PyYAML are not installed')
class InstallConditionTest(unittest.TestCase):
    def setUp(self):
        play = _play()
        self.vars = play['vars']
        self.when = _task(play['tasks'], 'Install the pinned agent')['when']

    def installs(self, installed: str) -> bool:
        # The playbook is our own tracked file, so its strings are trusted as templates.
        variables = {k: trust_as_template(v) for k, v in self.vars.items() if isinstance(v, str)}
        variables['cwa_installed'] = {'stdout': installed}
        return Templar(loader=DataLoader(), variables=variables).evaluate_conditional(trust_as_template(self.when))

    def test_the_pinned_package_as_dpkg_reports_it_is_left_alone(self):
        self.assertFalse(self.installs(self.vars['cwa_version'] + '-1'))

    def test_a_missing_or_different_package_is_installed(self):
        for installed in ('', '1.300000.0b1-1', self.vars['cwa_version']):
            with self.subTest(installed=installed):
                self.assertTrue(self.installs(installed))


@unittest.skipIf(yaml is None, 'ansible-core 2.19+ and PyYAML are not installed')
class LoginFileTest(unittest.TestCase):
    """2026-11-09: an agent start lost its supplementary groups and could not read auth.log."""

    def setUp(self):
        play = _play()
        self.vars = play['vars']
        self.tasks = play['tasks']
        self.agent_user = self.vars['cwa_config']['agent']['run_as_user']

    def test_the_agent_reads_the_login_file(self):
        files = self.vars['cwa_config']['logs']['logs_collected']['files']['collect_list']
        self.assertEqual([f['file_path'] for f in files], ['{{ cwa_login_log }}'])

    def test_the_login_file_is_readable_through_the_agents_primary_group(self):
        made = _task(self.tasks, 'Create the login file')['file']
        self.assertEqual((made['path'], made['group'], made['mode']),
                         ('{{ cwa_login_log }}', self.agent_user, '0640'))
        # A touch at the default times reports a change, which restarts rsyslog every run.
        self.assertEqual((made.get('access_time'), made.get('modification_time')), ('preserve', 'preserve'))
        rotate = _task(self.tasks, 'Rotate the login file')['copy']['content']
        self.assertIn('{{ cwa_login_log }} {', rotate)
        self.assertIn(f'create 0640 syslog {self.agent_user}', rotate)
        # The copy's validate run reads this file without logrotate.conf and its su line.
        self.assertIn('su root adm', rotate)

    def test_rsyslog_restarts_on_a_new_rule_a_remade_file_or_a_stale_start(self):
        when = _task(self.tasks, 'Check the rsyslog config, then restart rsyslog')['when']
        for term in ('rsyslog_rule is changed', 'login_file is changed', 'rsyslog_stale.rc == 0'):
            with self.subTest(term=term):
                self.assertIn(term, when)

    def test_rsyslog_writes_only_sshd_lines_to_the_login_file(self):
        rule = _task(self.tasks, 'Copy sshd')['copy']['content']
        self.assertIn("if $programname == 'sshd' then {", rule)
        self.assertIn('file="{{ cwa_login_log }}"', rule)

    def test_the_agent_holds_no_supplementary_group(self):
        groups = _task(self.tasks, 'Remove cwagent from every supplementary group')['user']
        self.assertEqual((groups['name'], groups['groups'], groups['append']),
                         (self.agent_user, '', False))

    def test_the_read_check_drops_every_supplementary_group(self):
        check = _task(self.tasks, 'Require the login file to be readable')['command']
        self.assertIn(f'--reuid={self.agent_user} --regid={self.agent_user} --clear-groups', check)


@unittest.skipIf(yaml is None, 'ansible-core 2.19+ and PyYAML are not installed')
class RestartTest(unittest.TestCase):
    """Every run restarted the agent while its config file was owned by root (2026-11-12)."""

    def setUp(self):
        play = _play()
        self.agent_user = play['vars']['cwa_config']['agent']['run_as_user']
        self.tasks = play['tasks']
        self.expr = _task(self.tasks, 'Decide whether the agent needs')['set_fact']['cwa_restart']

    def restarts(self, **changed) -> bool:
        variables = {name: {'changed': changed.get(name, False)}
                     for name in ('cwa_group', 'cwa_config_file', 'cwa_limits')}
        variables['cwa_active'] = {'rc': changed.get('cwa_active_rc', 0)}
        if 'cwa_package' in changed:
            variables['cwa_package'] = {'changed': changed['cwa_package']}
        rendered = Templar(loader=DataLoader(), variables=variables).template(trust_as_template(self.expr))
        return str(rendered).strip() == 'True'

    def test_the_config_file_has_the_owner_each_agent_start_sets(self):
        config = _task(self.tasks, 'Install the logs-only agent config')['copy']
        self.assertEqual((config['owner'], config['group']), (self.agent_user, self.agent_user))

    def test_the_start_and_its_log_check_run_only_on_the_restart_decision(self):
        for prefix in ('Load the config and (re)start the agent', 'Require this start to have opened'):
            with self.subTest(task=prefix):
                self.assertEqual(_task(self.tasks, prefix)['when'], 'cwa_restart | bool')

    def test_nothing_changed_means_no_restart(self):
        self.assertFalse(self.restarts())
        self.assertFalse(self.restarts(cwa_package=False))

    def test_any_change_or_a_stopped_agent_restarts(self):
        for case in ({'cwa_group': True}, {'cwa_config_file': True}, {'cwa_limits': True},
                     {'cwa_package': True}, {'cwa_active_rc': 3}):
            with self.subTest(case=case):
                self.assertTrue(self.restarts(**case))


BANNER = 'I! Starting AmazonCloudWatchAgent CWAgent/1.300074.0b1920 (go1.26.7; linux; arm64)'
OPENED = 'I! [logagent] piping log from /g/s(/var/log/sshd-login.log) to cloudwatchlogs with retention -1'
DENIED = 'E! open /var/log/sshd-login.log: permission denied'
OLD_DENIED = 'E! open /var/log/auth.log: permission denied'


@unittest.skipIf(yaml is None, 'ansible-core 2.19+ and PyYAML are not installed')
class PostStartLogCheckTest(unittest.TestCase):
    """The shell that fails the run when a start cannot open the login file, run on sample logs.

    Line 1 is from before the run; the check reads from line 2 on.
    """

    def setUp(self):
        play = _play()
        self.vars = play['vars']
        self.shell = _task(play['tasks'], 'Require this start to have opened')['shell']

    def passes(self, *lines: str) -> bool:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'agent.log'
            log.write_text('\n'.join(('before the run',) + lines) + '\n')
            variables = {'cwa_login_log': self.vars['cwa_login_log'], 'cwa_log_path': str(log),
                         'cwa_log_before': {'stdout': '1\n'}}
            script = Templar(loader=DataLoader(), variables=variables).template(trust_as_template(self.shell))
            return subprocess.run(['bash', '-c', script], capture_output=True).returncode == 0

    def test_an_open_after_the_banner_passes_despite_the_old_process_denials(self):
        self.assertTrue(self.passes(OLD_DENIED, OLD_DENIED, BANNER, OPENED))

    def test_a_failed_or_missing_open_fails(self):
        for lines in ((BANNER, OPENED, DENIED), (BANNER, DENIED), (OLD_DENIED,), (BANNER, OPENED, BANNER), ()):
            with self.subTest(lines=lines):
                self.assertFalse(self.passes(*lines))


if __name__ == '__main__':
    unittest.main()
