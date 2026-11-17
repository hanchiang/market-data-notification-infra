"""Keeps every workflow /healthz probe in the one form that passes only on an HTTPS 200.

Port 80 answers the service's name with a 301 even with the backend down, and `curl -f`
counts a 3xx as success. Both start checks read a stopped backend as healthy that way while
HOST_NAME lacked its scheme (seen 2026-09-29, secret fixed 2026-10-31); since 2026-11-17 each
builds its URL with `https://` and judges curl's status code itself. Keys on the `/healthz`
path and the `health_url` variable, not the tool, so a probe written with wget, python or a
backslash-continued curl is caught too. Reads lines as text: the CI job installs no YAML parser.
"""
import unittest

from support import REPO

WORKFLOWS = REPO / '.github' / 'workflows'
HEALTH_URL = 'health_url="https://${health_host%/}/healthz"'
HEALTH_CURL = ("if code=$(curl -sS -o /dev/null -w '%{http_code}' \"$health_url\")"
               ' && [ "$code" = 200 ]')
EXPECTED_CHECKS = 2  # the start workflow's pre-check and its wait for the deploy


def workflow_lines():
    paths = sorted([*WORKFLOWS.glob('*.yml'), *WORKFLOWS.glob('*.yaml')])
    return [(path.name, line.strip())
            for path in paths
            for line in path.read_text().splitlines()
            if not line.strip().startswith('#')]


class HealthzCheckFormTest(unittest.TestCase):
    def test_every_healthz_probe_uses_the_https_200_form(self):
        for name, line in workflow_lines():
            if '/healthz' in line or 'health_url=' in line:
                with self.subTest(workflow=name, line=line):
                    self.assertEqual(line, HEALTH_URL)
            elif 'health_url' in line:
                with self.subTest(workflow=name, line=line):
                    self.assertEqual(line, HEALTH_CURL)

    def test_the_known_checks_are_found(self):
        # Guards the test itself: a reworded check must not silently match nothing.
        lines = [line for _, line in workflow_lines()]
        self.assertEqual(lines.count(HEALTH_CURL), EXPECTED_CHECKS)
        self.assertEqual(lines.count(HEALTH_URL), EXPECTED_CHECKS)
