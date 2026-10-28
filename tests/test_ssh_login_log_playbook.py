"""The CloudWatch agent playbook reinstalls only when the installed package is not the pin.

dpkg reports the package as the upstream version plus a Debian revision ("-1"), so the
condition must compare against that form: comparing the bare version would reinstall on
every start. The task's own `when` is evaluated through Ansible's templar, so the test
reads the playbook as Ansible does. Skipped where Ansible is not installed (the CI job
installs none); it runs wherever the start script runs.
"""
import unittest

from support import REPO

PLAYBOOK = REPO / 'instances' / 'ansible' / 'playbooks' / 'ssh-login-log.yml'

try:
    import yaml
    from ansible.parsing.dataloader import DataLoader
    from ansible.template import Templar, trust_as_template
except ImportError:  # pragma: no cover - depends on the machine
    yaml = None


@unittest.skipIf(yaml is None, 'ansible-core 2.19+ and PyYAML are not installed')
class InstallConditionTest(unittest.TestCase):
    def setUp(self):
        play = yaml.safe_load(PLAYBOOK.read_text())[0]
        self.vars = play['vars']
        self.when = next(t for t in play['tasks']
                         if t.get('name', '').startswith('Install the pinned agent'))['when']

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


if __name__ == '__main__':
    unittest.main()
