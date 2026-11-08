"""The Nginx config must not write a raw request value to any ingress log.

Reads the config as text, because the CI job installs no Nginx or YAML parser. The raw-field
ban reads only the `log_format` body: the maps that need `$request_uri` live in log_maps.conf.
"""
import re
import unittest

from support import REPO

ANSIBLE = REPO / 'instances' / 'ansible'
NGINX = ANSIBLE / 'files' / 'nginx'
REDACTOR = ANSIBLE / 'files' / 'nginx-log-redactor'
SITE = ANSIBLE / 'templates' / 'nginx' / 'market_data_notification_site.conf.j2'
PLAYBOOK = ANSIBLE / 'playbooks' / 'nginx.yml'

# $query_string is $args under another name; $arg_<name> reads one query value.
RAW_FIELDS = ('request_body', 'remote_user', 'request', 'request_uri', 'args', 'query_string',
              'http_referer', 'http_cookie', 'http_authorization', 'http_x_api_auth')
# Prefixes of whole variable families: one query value, a cookie, a response header.
RAW_PREFIXES = ('arg_', 'cookie_', 'sent_http_', 'upstream_http_')
# At or above warn; below it Nginx quotes request headers into the error log.
LEVELS_AT_OR_ABOVE_WARN = ('warn', 'error', 'crit', 'alert', 'emerg')


def log_format_body(text, name='json_combined'):
    """The text of one log_format directive, up to the `;` that is outside quotes."""
    start = re.search(r'\blog_format\s+' + name + r'\b', text).end()
    quoted = False
    for i in range(start, len(text)):
        if text[i] == "'":
            quoted = not quoted
        elif text[i] == ';' and not quoted:
            return text[start:i]
    raise AssertionError('log_format %s is not terminated' % name)


def server_blocks(template):
    """Each `server { ... }` body in the site template, with Jinja and comments removed."""
    text = re.sub(r'\{\{.*?\}\}', 'X', template)
    text = re.sub(r'#.*', '', text)
    blocks = []
    for start in re.finditer(r'\bserver\s*\{', text):
        depth, i = 1, start.end()
        while depth:
            depth += {'{': 1, '}': -1}.get(text[i], 0)
            i += 1
        blocks.append(text[start.end():i - 1])
    return blocks


def socket_path():
    return re.search(r'^ListenDatagram=(\S+)$', (REDACTOR / 'nginx-log-redactor.socket').read_text(),
                     re.MULTILINE).group(1)


def nginx_text(path):
    """A config file with Jinja expressions and comments removed."""
    return re.sub(r'#.*', '', re.sub(r'\{\{.*?\}\}', 'X', path.read_text()))


def log_directives(name):
    """Every `name args;` in each file that holds Nginx config for the site, as (file, args)."""
    found = []
    for path in sorted(NGINX.iterdir()) + [SITE]:
        for args in re.findall(r'(?<![\w$])%s\s+([^;]*);' % name, nginx_text(path)):
            found.append((path.name, args.strip()))
    return found


class EveryLogDirectiveTest(unittest.TestCase):
    """Reads every file under files/nginx/ and the site template, so a directive added to a
    fragment is checked too. The main-context error_log in the unmanaged nginx.conf is out
    of scope (startup lines carry no request)."""

    def test_the_scan_finds_the_directives(self):
        # Guards the check itself: a reworded config must not leave it reading nothing.
        self.assertGreaterEqual(len(log_directives('error_log')), 3)
        self.assertGreaterEqual(len(log_directives('access_log')), 4)

    def test_every_error_log_is_the_redactor_at_warn_or_above(self):
        for source, args in log_directives('error_log'):
            with self.subTest(source=source, args=args):
                match = re.fullmatch(r'syslog:server=unix:(\S+?),nohostname\s+(\w+)', args)
                self.assertIsNotNone(match)
                self.assertEqual(match.group(1), socket_path())
                self.assertIn(match.group(2), LEVELS_AT_OR_ABOVE_WARN)

    def test_every_access_log_is_json_combined_or_off(self):
        for source, args in log_directives('access_log'):
            with self.subTest(source=source, args=args):
                self.assertRegex(args, r'^(off|/var/log/nginx/access\.log\s+json_combined)$')


class AccessLogFormatTest(unittest.TestCase):
    def setUp(self):
        self.body = log_format_body((NGINX / 'json_log.conf').read_text())

    def test_the_log_format_is_found(self):
        # Guards the check itself: a reworded file must not leave the ban reading nothing.
        self.assertIn('$time_iso8601', self.body)
        self.assertIn('$request_id', self.body)

    def test_no_raw_field_is_logged(self):
        for name in RAW_FIELDS:
            with self.subTest(field=name):
                self.assertIsNone(re.search(r'\$(\{%s\}|%s(?![A-Za-z0-9_]))' % (name, name), self.body))

    def test_no_raw_variable_family_is_logged(self):
        for prefix in RAW_PREFIXES:
            with self.subTest(prefix=prefix):
                self.assertIsNone(re.search(r'\$\{?%s' % prefix, self.body))

    def test_the_replacement_fields_are_logged(self):
        for variable in ('$request_method', '$raw_path', '$is_args', '$referer_without_query'):
            with self.subTest(variable=variable):
                self.assertIn(variable, self.body)

    def test_the_maps_strip_the_query_and_are_included_with_the_log_format(self):
        maps = (NGINX / 'log_maps.conf').read_text()
        self.assertRegex(maps, r'map \$request_uri \$raw_path')
        self.assertRegex(maps, r'map \$http_referer \$referer_without_query')
        self.assertEqual(len(re.findall(r'\[\^\?\]\*', maps)), 2)
        site = SITE.read_text()
        self.assertIn('include /etc/nginx/common/log_maps.conf;', site)
        self.assertIn('src: ../files/nginx/log_maps.conf', PLAYBOOK.read_text())


class ProxyHeadersTest(unittest.TestCase):
    def setUp(self):
        self.proxy = (NGINX / 'market_data_notification_proxy.conf').read_text()

    def test_the_request_id_header_is_nginxs_own(self):
        self.assertRegex(self.proxy, r'(?m)^proxy_set_header X-Request-ID \$request_id;$')

    def test_the_forwarded_proto_header_is_spelled_right(self):
        self.assertRegex(self.proxy, r'(?m)^proxy_set_header X-Forwarded-Proto \$scheme;$')
        self.assertNotIn('Forwared', self.proxy)


class ServerBlockLogTest(unittest.TestCase):
    def setUp(self):
        self.template = SITE.read_text()
        self.blocks = server_blocks(self.template)

    def test_every_server_block_is_found(self):
        self.assertEqual(len(self.blocks), len(re.findall(r'^server\s*\{', self.template, re.MULTILINE)))
        self.assertEqual(len(self.blocks), 3)  # port-80 catch-all, port-80 redirect, 443

    def test_every_server_block_uses_the_json_access_log(self):
        for i, block in enumerate(self.blocks):
            with self.subTest(block=i):
                self.assertRegex(block, r'(?m)^\s*access_log\s+/var/log/nginx/access\.log\s+json_combined;')

    def test_every_server_block_sends_its_error_log_to_the_redactor_at_warn_or_above(self):
        path = socket_path()
        for i, block in enumerate(self.blocks):
            with self.subTest(block=i):
                directives = re.findall(r'^\s*error_log\s+(.*?);', block, re.MULTILINE)
                self.assertEqual(len(directives), 1, 'exactly one error_log, and none to a file')
                match = re.fullmatch(r'syslog:server=unix:(\S+?),nohostname\s+(\w+)', directives[0])
                self.assertIsNotNone(match, directives[0])
                self.assertEqual(match.group(1), path)
                self.assertIn(match.group(2), LEVELS_AT_OR_ABOVE_WARN)

    def test_the_socket_unit_matches_the_service_account_and_mode(self):
        unit = (REDACTOR / 'nginx-log-redactor.socket').read_text()
        self.assertRegex(unit, r'(?m)^SocketUser=www-data$')
        self.assertRegex(unit, r'(?m)^SocketMode=0600$')


class RedactorUnitsTest(unittest.TestCase):
    def setUp(self):
        self.service = (REDACTOR / 'nginx-log-redactor.service').read_text()

    def test_the_service_runs_as_www_data_and_never_gives_up(self):
        self.assertRegex(self.service, r'(?m)^User=www-data$')
        self.assertRegex(self.service, r'(?m)^Restart=always$')
        self.assertRegex(self.service, r'(?m)^StartLimitIntervalSec=0$')

    def test_the_service_makes_the_log_file_before_it_starts_and_is_sandboxed(self):
        pre = re.search(r'(?m)^ExecStartPre=\+(.*)$', self.service).group(1)
        self.assertIn(': > /var/log/nginx/error.log', pre)            # create, never truncate an existing one
        self.assertIn('[ -e /var/log/nginx/error.log ] ||', pre)
        self.assertIn('chown www-data:adm /var/log/nginx/error.log', pre)
        self.assertIn('chmod 0640 /var/log/nginx/error.log', pre)
        self.assertRegex(self.service, r'(?m)^RestartSec=2$')
        self.assertRegex(self.service, r'(?m)^ProtectSystem=strict$')
        self.assertRegex(self.service, r'(?m)^ReadWritePaths=/var/log/nginx$')

    def test_the_service_runs_the_script_the_playbook_installs(self):
        path = re.search(r'(?m)^ExecStart=/usr/bin/python3 (\S+)$', self.service).group(1)
        self.assertIn('dest: ' + path, PLAYBOOK.read_text())
        self.assertTrue((REDACTOR / path.rsplit('/', 1)[1]).is_file())


class PlaybookOrderTest(unittest.TestCase):
    def setUp(self):
        self.text = PLAYBOOK.read_text()

    def task(self, name):
        """The text of one task or handler, from its `- name:` line to the next one."""
        start = self.text.index('- name: ' + name)
        following = re.search(r'\n    - name: ', self.text[start + 1:])
        return self.text[start:start + 1 + following.start()] if following else self.text[start:]

    def test_the_socket_is_started_before_nginx_is_validated_and_reloaded(self):
        text = self.text
        started = text.index('name: nginx-log-redactor.socket\n        enabled: yes\n        state: started')
        self.assertLess(started, text.index('meta: flush_handlers'))
        self.assertLess(text.index('daemon_reload: yes'), started)
        # The redactor cannot create error.log (the log directory is root-owned), so the file
        # is ensured, without overwriting it, before the socket starts.
        ensure = text.index('- name: Ensure the redacted error log exists')
        self.assertLess(ensure, started)
        task = text[ensure:started]
        # `file: state=touch` with both times preserved creates a missing file, edits an existing
        # one in no way, and still enforces owner and mode. `copy` with `force: no` skips an
        # existing file attributes and all, and `touch` without the preserves moves its times.
        for line in ('file:', 'path: /var/log/nginx/error.log', 'state: touch',
                     'access_time: preserve', 'modification_time: preserve',
                     'owner: www-data', 'group: adm', 'mode: "0640"'):
            self.assertIn(line, task)
        self.assertNotIn('copy:', task)
        # Handlers run in definition order: both restarts come before the nginx reload.
        reload_at = text.index('- name: Validate and reload nginx\n      become')
        self.assertLess(text.index('- name: Restart nginx log redactor socket\n      become'), reload_at)
        self.assertLess(text.index('- name: Restart nginx log redactor service\n      become'), reload_at)

    def test_the_play_runs_notified_handlers_even_when_a_later_task_fails(self):
        play_header = self.text.split('  tasks:', 1)[0]
        self.assertRegex(play_header, r'(?m)^  force_handlers: true$')

    def test_the_script_and_service_unit_restart_the_service_only(self):
        for name in ('Install the nginx error-log redactor script',
                     'Install the nginx error-log redactor service unit'):
            with self.subTest(task=name):
                notify = self.task(name).split('notify:', 1)[1]
                self.assertIn('Restart nginx log redactor service', notify)
                self.assertNotIn('socket', notify)
                self.assertNotIn('Validate and reload nginx', notify)

    def test_a_changed_socket_unit_restarts_the_socket_and_reloads_nginx(self):
        notify = self.task('Install the nginx error-log redactor socket unit').split('notify:', 1)[1]
        self.assertIn('Restart nginx log redactor socket', notify)
        self.assertIn('Validate and reload nginx', notify)
        self.assertNotIn('Restart nginx log redactor service', notify)

    def test_the_redaction_probe_runs_after_the_reload_against_the_443_block(self):
        text = self.text
        probe = text[text.index('- name: Probe that the redacted error log'):text.index('  handlers:')]
        self.assertLess(text.index('meta: flush_handlers'), text.index('- name: Probe that the redacted'))
        for needle in ('--resolve {{ DOMAIN }}:443:127.0.0.1', 'Content-Length: 2000000',
                       '?token=probe-value', '"413"', 'tail -c +$((before + 1))',
                       'changed_when: false', 'check_mode: false'):
            self.assertIn(needle, probe)

    def test_the_probe_matches_the_whole_redacted_shape(self):
        probe = self.task('Probe that the redacted error log')
        shape = re.search(r"shape='(.*)'", probe).group(1)
        self.assertIn('grep -Eq "$shape"', probe)
        self.assertIn("grep -q 'probe-value'", probe)
        sample = ('2026/11/07 12:00:00 [error] 812#812: *7 client intended to send too large body: '
                  '2000000 bytes, client: 203.0.113.9, server: example.com, '
                  'request: "POST /?token=<redacted> <redacted>')
        self.assertIsNotNone(re.search(shape, sample))
        for broken in (sample.replace('[error] 812#812: *7 ', ''),       # no header
                       sample.replace('token=<redacted>', 'token=x'),    # value not redacted
                       sample.replace('request: "POST', 'request: "GET'),
                       sample.replace('token', 'tokens'),
                       # a tail the redactor would never keep: the rest of the line survived
                       sample[:-len(' <redacted>')] + ' HTTP/1.1", host: "x", referrer: "https://r/?k=v"',
                       sample + ' trailing'):
            with self.subTest(line=broken[:60]):
                self.assertIsNone(re.search(shape, broken))

    def test_every_redactor_file_is_installed(self):
        for name in ('nginx_error_log_redactor.py', 'nginx-log-redactor.socket', 'nginx-log-redactor.service'):
            with self.subTest(file=name):
                self.assertTrue((REDACTOR / name).is_file())
                self.assertIn(name, self.text)


if __name__ == '__main__':
    unittest.main()
