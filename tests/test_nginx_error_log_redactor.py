"""The error-log redactor keeps query names, drops every query value, and survives hostile input.

Fixture lines follow Nginx's error-log format. The host's error log confirmed it through the
`host` field on 2026-11-07 (HostLineTest). The `referrer` field and the syslog prefix are not
yet seen on the host; see the script's note.
"""
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from support import REPO

SCRIPT = REPO / 'instances' / 'ansible' / 'files' / 'nginx-log-redactor' / 'nginx_error_log_redactor.py'
spec = importlib.util.spec_from_file_location('nginx_error_log_redactor', SCRIPT)
redactor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(redactor)

PREFIX = '<187>Nov  7 12:00:00 nginx: '
HEADER = '2026/11/07 12:00:00 [error] 812#812: '
SECRET = 'S3CR3T-value'


def request_line(request, extra=''):
    return (PREFIX + HEADER + '*7 client intended to send too large body: 2000000 bytes, '
            'client: 203.0.113.9, server: example.com, request: "' + request + '"' + extra +
            ', host: "example.com"')


class RedactLineTest(unittest.TestCase):
    def test_the_syslog_prefix_is_dropped_and_the_header_kept(self):
        out = redactor.redact_line(request_line('GET / HTTP/1.1').encode())
        self.assertTrue(out.startswith('2026/11/07 12:00:00 [error] 812#812: *7 client intended'), out)
        self.assertNotIn('nginx:', out.split('[error]')[0])
        self.assertNotIn('<187>', out)

    def test_query_names_stay_and_values_go_and_the_rest_of_the_line_is_dropped(self):
        out = redactor.redact_line(request_line('GET /a?token=%s&symbol=%s HTTP/1.1' % (SECRET, SECRET)))
        self.assertTrue(out.endswith('request: "GET /a?token=<redacted>&symbol=<redacted> <redacted>'), out)
        self.assertNotIn(SECRET, out)

    def test_nothing_after_the_first_question_mark_survives_but_names(self):
        # The upstream, host and referrer fields come after the request's query, so they are lost.
        line = (PREFIX + HEADER + '*9 connect() failed (111: Connection refused) while connecting to '
                'upstream, client: 203.0.113.9, server: example.com, request: "GET /x?a=%s HTTP/1.1", '
                'upstream: "http://127.0.0.1:8080/x?b=%s", host: "example.com", '
                'referrer: "https://evil.example/?c=%s"' % (SECRET, SECRET, SECRET))
        out = redactor.redact_line(line)
        self.assertNotIn(SECRET, out)
        self.assertTrue(out.endswith('request: "GET /x?a=<redacted> <redacted>'), out)
        self.assertNotIn('upstream: "http', out)

    def test_values_go_in_upstream_referrer_and_message_text_when_the_request_has_no_query(self):
        line = (PREFIX + HEADER + '*9 connect() failed, client: 203.0.113.9, request: "GET /x HTTP/1.1", '
                'upstream: "http://127.0.0.1:8080/x?b=%s", host: "example.com", '
                'referrer: "https://evil.example/?c=%s"' % (SECRET, SECRET))
        out = redactor.redact_line(line)
        self.assertNotIn(SECRET, out)
        self.assertIn('upstream: "http://127.0.0.1:8080/x?b=<redacted> <redacted>', out)
        message_only = redactor.redact_line(PREFIX + HEADER + 'open failed for /x?k=%s while reading' % SECRET)
        self.assertEqual(message_only, HEADER + 'open failed for /x?k=<redacted> while reading'.replace(
            ' while reading', ' <redacted>'))

    def test_an_entry_with_no_equals_is_redacted_not_kept_as_a_name(self):
        for query in ('flag', 'sk_live_%s' % SECRET, 'a=1&sk_live_%s' % SECRET, 'a=1&flag&b=2'):
            with self.subTest(query=query):
                out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s HTTP/1.1"' % query)
                self.assertNotIn(SECRET, out)
                self.assertNotIn('flag', out)
                self.assertNotIn('sk_live', out)
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a=1&flag&b=2 HTTP/1.1"')
        self.assertTrue(out.endswith('?a=<redacted> <redacted>'), out)

    def test_empty_values_and_a_bare_question_mark(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a=&b=1 HTTP/1.1"')
        self.assertTrue(out.endswith('?a=<redacted>&b=<redacted> <redacted>'), out)
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /? HTTP/1.1"')
        self.assertTrue(out.endswith('GET /? <redacted>'), out)

    def test_names_that_are_not_plain_are_redacted(self):
        odd_names = ['%73ecret', 'a"b', 'x' * 21, '1234', 'a<b>', "a'b", 'ключ']
        for name in odd_names:
            with self.subTest(name=name):
                out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s=%s HTTP/1.1"' % (name, SECRET))
                self.assertTrue(out.endswith('GET /? <redacted>'), out)
                self.assertNotIn(name, out)
                self.assertNotIn(SECRET, out)

    def test_a_plain_name_after_a_dropped_entry_is_not_kept(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a=1&%%73=2&b=%s HTTP/1.1"' % SECRET)
        self.assertTrue(out.endswith('?a=<redacted> <redacted>'), out)
        self.assertNotIn('b=', out)

    def test_bracketed_names_are_plain(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?ids[]=%s&m[k]=%s HTTP/1.1"' % (SECRET, SECRET))
        self.assertIn('?ids[]=<redacted>&m[k]=<redacted>', out)

    def test_a_line_with_no_question_mark_is_left_alone(self):
        out = redactor.redact_line(PREFIX + HEADER + 'what, why')
        self.assertEqual(out, HEADER + 'what, why')


class HostLineTest(unittest.TestCase):
    # A request-scoped line read from the production host's error log on 2026-11-07
    # (Nginx 1.18.0); the client address is replaced with a documentation address.
    HOST_LINE = ('2026/10/31 12:53:55 [error] 170402#170402: *3344 connect() failed (111: '
                 'Unknown error) while connecting to upstream, client: 192.0.2.10, server: '
                 'api.marketdata.yaphc.com, request: "GET /healthz HTTP/1.1", upstream: '
                 '"http://127.0.0.1:8080/healthz", host: "api.marketdata.yaphc.com"')

    def test_a_real_host_line_with_no_query_passes_through_whole(self):
        out = redactor.redact_line((PREFIX + self.HOST_LINE).encode())
        self.assertEqual(out, self.HOST_LINE)

    def test_a_real_host_line_with_a_query_keeps_its_header_and_loses_the_value(self):
        line = self.HOST_LINE.replace('/healthz HTTP', '/healthz?token=' + SECRET + ' HTTP')
        out = redactor.redact_line((PREFIX + line).encode())
        self.assertTrue(out.startswith('2026/10/31 12:53:55 [error] 170402#170402: *3344 '), out)
        self.assertIn('request: "GET /healthz?token=<redacted>', out)
        self.assertNotIn(SECRET, out)


class InjectionTest(unittest.TestCase):
    def test_a_quote_inside_the_query_does_not_end_the_redaction(self):
        # The attacker closes the request field early and puts the rest where a
        # quote-aware parser would treat it as a separate, unredacted field.
        hostile = 'GET /?a=1" HTTP/1.1", upstream: "http://x/?token=%s" ZZ' % SECRET
        out = redactor.redact_line(request_line(hostile))
        self.assertNotIn(SECRET, out)
        self.assertNotIn('token', out)

    def test_a_secret_after_an_injected_quote_in_the_same_query_is_still_redacted(self):
        out = redactor.redact_line(request_line('GET /?a=1"&token=%s HTTP/1.1' % SECRET))
        self.assertNotIn(SECRET, out)
        self.assertTrue(out.endswith('?a=<redacted>&token=<redacted> <redacted>'), out)

    def test_whitespace_nginx_keeps_inside_the_field_does_not_end_the_redaction(self):
        # A tokenizer that ends the query at whitespace leaks the value after it.
        separators = {
            'nbsp': '\u00a0', 'ideographic space': '\u3000', 'tab': '\t', 'space in the uri': ' ',
            'line separator': '\u2028', 'paragraph separator': '\u2029', 'next line': '\x85',
            'vertical tab': '\x0b', 'form feed': '\x0c', 'carriage return': '\r', 'file separator': '\x1c',
        }
        for label, separator in separators.items():
            with self.subTest(separator=label):
                request = 'GET /?a=1%sb=%s&token=%s HTTP/1.1' % (separator, SECRET, SECRET)
                for where in ('request', 'referrer'):
                    line = request_line(request) if where == 'request' else (
                        PREFIX + HEADER + 'referrer: "https://evil.example/?a=1%sb=%s&token=%s"' % (
                            separator, SECRET, SECRET))
                    out = redactor.redact_line(line)
                    self.assertNotIn(SECRET, out)
                    if separator != ' ':
                        self.assertNotIn(separator, out)

    def test_a_secret_before_a_separator_in_a_value_is_one_value(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a=%s\u00a0x HTTP/1.1"' % SECRET)
        self.assertEqual(out, HEADER + 'request: "GET /?a=<redacted> <redacted>')

    def test_a_secret_after_a_question_mark_inside_a_value(self):
        out = redactor.redact_line(request_line('GET /?a=1?b=%s HTTP/1.1' % SECRET))
        self.assertNotIn(SECRET, out)

    def test_a_newline_cannot_forge_a_second_entry_from_one_line(self):
        out = redactor.redact_line(request_line('GET /?a=1\n2026/11/07 12:00:01 [error] 1#1: forged'))
        self.assertNotIn('\n', out)
        self.assertNotIn('forged', out)

    def test_control_and_separator_characters_in_the_prefix_are_escaped(self):
        out = redactor.redact_line(PREFIX + HEADER + 'a\u2028b\u2029c\x85d\re\tf\x00g\x1bh no query')
        self.assertEqual(out, HEADER + 'a\\u2028b\\u2029c\\x85d\\x0de\\x09f\\x00g\\x1bh no query')
        for char in '\n\r\t\u2028\u2029\x85\x00\x1b':
            self.assertNotIn(char, out)

    def test_any_byte_is_accepted(self):
        # Whitespace and control bytes are left out of the query here so the value stays one run;
        # test_whitespace_nginx_keeps_inside_the_field covers them.
        data = (PREFIX + HEADER + 'request: "GET /?a=').encode() + bytes(
            b for b in range(33, 256) if b != 127) + SECRET.encode()
        out = redactor.redact_line(data)
        self.assertNotIn(SECRET, out)
        self.assertTrue(out.startswith('2026/11/07 12:00:00 [error] 812#812:'))

    def test_every_byte_after_a_question_mark_is_redacted(self):
        data = (PREFIX + HEADER + 'request: "GET /?').encode() + bytes(range(256)) + SECRET.encode()
        out = redactor.redact_line(data)
        self.assertNotIn(SECRET, out)
        self.assertEqual(out, HEADER + 'request: "GET /? <redacted>')

    def test_redact_line_never_raises(self):
        for data in (b'', b'\x00', None, 12, object(), b'\xff' * 70000):
            with self.subTest(data=repr(data)[:20]):
                self.assertIsInstance(redactor.redact_line(data), str)


class PositionalFieldTest(unittest.TestCase):
    """A time, level or pid is only taken from where Nginx writes it."""

    def test_a_card_number_in_the_text_is_not_taken_for_a_pid(self):
        out = redactor.redact_line('garbage pin] 4111111111111111 ?x')
        self.assertNotIn('4111111111111111', out)
        self.assertEqual(out, '- [-] -: <redacted>')

    def test_a_pid_after_the_first_question_mark_is_not_taken(self):
        out = redactor.redact_line(PREFIX + '2026/11/07 12:00:00 [error] ?token] 987654321')
        self.assertNotIn('987654321', out)
        self.assertEqual(out, '2026/11/07 12:00:00 [error] -: <redacted>')

    def test_a_pid_over_ten_digits_is_not_a_pid(self):
        out = redactor.redact_line('2026/11/07 12:00:00 [error] 12345678901 x')
        self.assertNotIn('1234567890', out)
        self.assertEqual(out, '2026/11/07 12:00:00 [error] -: <redacted>')
        parsed = redactor.redact_line(PREFIX + '2026/11/07 12:00:00 [error] 12345678901#1: kept ' + SECRET)
        self.assertNotIn(SECRET, parsed)

    def test_a_header_that_is_not_at_the_start_is_not_a_header(self):
        out = redactor.redact_line('x 2026/11/07 12:00:00 [error] 1#1: kept %s no q' % SECRET)
        self.assertNotIn(SECRET, out)
        self.assertEqual(out, '- [-] -: <redacted>')

    def test_a_fallback_field_is_not_taken_when_the_field_before_it_is_missing(self):
        # A continuation piece after a newline can start with a number or a level word.
        self.assertEqual(redactor.redact_line('4111111111 x'), '- [-] -: <redacted>')
        self.assertEqual(redactor.redact_line('[error] 4111111111 x'), '- [-] -: <redacted>')
        # With the separating space a later field would fit, so only the missing time stops it.
        for line in (' [error] 4111111111 x', ' 4111111111 x', PREFIX + ' [error] 4111111111 x'):
            with self.subTest(line=line):
                self.assertEqual(redactor.redact_line(line), '- [-] -: <redacted>')

    def test_a_header_after_other_text_in_the_syslog_slot_is_not_a_header(self):
        out = redactor.redact_line('<187>Nov  7 12:00:00 nginx: junk ' + HEADER + 'kept ' + SECRET)
        self.assertNotIn(SECRET, out)

    def test_the_header_is_found_with_or_without_a_syslog_prefix_or_hostname(self):
        for prefix in ('', '<187>Nov  7 12:00:00 nginx: ', '<187>Nov 17 12:00:00 host-1 nginx: ',
                       '<187>Nov  7 12:00:00 nginx[812]: '):
            with self.subTest(prefix=prefix):
                self.assertEqual(redactor.redact_line(prefix + HEADER + 'kept'), HEADER + 'kept')


class NameShapeTest(unittest.TestCase):
    def test_several_bracket_groups_are_not_a_plain_name(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a[AKIAIOSFODN][N7EXAMPLEKEY01][abcdef]=1 HTTP/1.1"')
        self.assertNotIn('AKIA', out)
        self.assertNotIn('EXAMPLEKEY', out)
        self.assertTrue(out.endswith('GET /? <redacted>'), out)

    def test_two_short_bracket_groups_are_not_a_plain_name_either(self):
        # Under 20 characters, so only the one-group rule can reject it.
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?a[KEY1][KEY2]=1 HTTP/1.1"')
        self.assertNotIn('KEY', out)

    def test_a_name_with_one_group_is_kept_up_to_20_characters_in_all(self):
        kept = 'a' * 12 + '[' + 'b' * 6 + ']'            # 20 characters, brackets included
        too_long = 'a' * 12 + '[' + 'b' * 7 + ']'         # 21
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s=1 HTTP/1.1"' % kept)
        self.assertIn('?%s=<redacted>' % kept, out)
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s=1 HTTP/1.1"' % too_long)
        self.assertNotIn(too_long, out)
        self.assertTrue(out.endswith('GET /? <redacted>'), out)

    def test_a_plain_name_is_kept_at_20_and_redacted_at_21_characters(self):
        for length, shown in ((20, True), (21, False)):
            name = 'n' * length
            with self.subTest(length=length):
                out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s=1&b=2 HTTP/1.1"' % name)
                self.assertEqual(name in out, shown)
                self.assertTrue(out.endswith('?%s=<redacted>&b=<redacted> <redacted>' % name if shown
                                             else 'GET /? <redacted>'), out)

    def test_a_secret_shaped_name_is_redacted_with_everything_after_it(self):
        for name in ('q2Xv-8_ZkLmN0pQrStUvWw==', '0123456789abcdef0123456789abcdef',
                     '123e4567-e89b-12d3-a456-426614174000', 'sort_direction'):
            with self.subTest(name=name):
                out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?%s=1&b=2 HTTP/1.1"' % name)
                if name == 'sort_direction':   # the backend's longest real parameter (14)
                    self.assertIn('?sort_direction=<redacted>&b=<redacted>', out)
                else:
                    self.assertNotIn(name.rstrip('='), out)
                    self.assertNotIn('b=', out)
                    self.assertTrue(out.endswith('GET /? <redacted>'), out)

    def test_a_secret_shaped_name_with_no_value_is_redacted_too(self):
        out = redactor.redact_line(PREFIX + HEADER + 'request: "GET /?q2Xv-8_ZkLmN0pQrStUvWw== HTTP/1.1"')
        self.assertNotIn('q2Xv', out)
        self.assertTrue(out.endswith('GET /? <redacted>'), out)


class DatagramTest(unittest.TestCase):
    def test_a_datagram_is_split_on_newline_only(self):
        for char in ('\x0b', '\x0c', '\x1c', '\x1d', '\x1e', '\x85', '\u2028', '\u2029', '\r'):
            with self.subTest(char=repr(char)):
                lines = redactor.redact_datagram((PREFIX + HEADER + 'm%sn ?a=%s' % (char, SECRET)).encode())
                self.assertEqual(len(lines), 1)
                self.assertNotIn(SECRET, lines[0])

    def test_each_newline_separated_piece_is_its_own_line_and_a_trailing_newline_adds_none(self):
        data = (PREFIX + HEADER + 'one ?a=%s\n' % SECRET).encode()
        self.assertEqual(redactor.redact_datagram(data), [HEADER + 'one ?a=<redacted>'])
        lines = redactor.redact_datagram((PREFIX + HEADER + 'one ?a=1\nb=%s' % SECRET).encode())
        self.assertEqual(lines, [HEADER + 'one ?a=<redacted>', '- [-] -: <redacted>'])

    def test_a_continuation_that_forges_a_header_still_has_its_query_redacted(self):
        lines = redactor.redact_datagram(
            (PREFIX + HEADER + 'x\n2026/11/07 12:00:01 [error] 1#1: y?token=%s' % SECRET).encode())
        self.assertNotIn(SECRET, ''.join(lines))

    def test_an_empty_datagram_and_a_non_bytes_value_do_not_raise(self):
        self.assertEqual(redactor.redact_datagram(b''), ['- [-] -: <redacted>'])
        self.assertIsInstance(redactor.redact_datagram(None), list)


class UnparseableLineTest(unittest.TestCase):
    def test_a_line_with_no_header_keeps_nothing_but_placeholders(self):
        out = redactor.redact_line('garbage with a ?token=%s in it' % SECRET)
        self.assertEqual(out, '- [-] -: <redacted>')

    def test_a_line_with_a_broken_header_keeps_time_level_and_pid_only(self):
        out = redactor.redact_line(PREFIX + '2026/11/07 12:00:00 [error] 812 no hash: ?token=%s' % SECRET)
        self.assertEqual(out, '2026/11/07 12:00:00 [error] 812: <redacted>')

    def test_a_forged_time_level_and_pid_after_other_text_are_not_taken(self):
        for line in ('junk 2026/11/07 12:00:00 [error] 9876543210 more',
                     'garbage pin] 4111111111 x',
                     'x [error] 1234 y',
                     '<187>Nov  7 12:00:00 nginx: junk 2026/11/07 12:00:00 [error] 812 more'):
            with self.subTest(line=line):
                self.assertEqual(redactor.redact_line(line), '- [-] -: <redacted>')

    def test_a_genuine_header_with_an_unparseable_body_keeps_time_level_and_pid(self):
        for line in (PREFIX + '2026/11/07 12:00:00 [error] 812 no hash: x',
                     '2026/11/07 12:00:00 [warn] 9876543210 more',
                     PREFIX + '2026/11/07 12:00:00 [crit] 812#: x ' + SECRET):
            with self.subTest(line=line):
                out = redactor.redact_line(line)
                self.assertTrue(out.startswith('2026/11/07 12:00:00 ['), out)
                self.assertTrue(out.endswith(': <redacted>'), out)
                self.assertNotIn(SECRET, out)
        self.assertEqual(redactor.redact_line('2026/11/07 12:00:00 [warn] 9876543210 more'),
                         '2026/11/07 12:00:00 [warn] 9876543210: <redacted>')

    def test_fields_are_taken_in_order_and_only_as_far_as_they_chain(self):
        self.assertEqual(redactor.redact_line('2026/11/07 12:00:00 x [error] 812'),
                         '2026/11/07 12:00:00 [-] -: <redacted>')
        self.assertEqual(redactor.redact_line('2026/11/07 12:00:00 [error] x 812'),
                         '2026/11/07 12:00:00 [error] -: <redacted>')
        # A pid in the level's own slot: only the chain, not its position, stops it.
        self.assertEqual(redactor.redact_line('2026/11/07 12:00:00 4111111111 x'),
                         '2026/11/07 12:00:00 [-] -: <redacted>')

    def test_a_pid_over_ten_digits_at_its_position_is_not_taken(self):
        self.assertEqual(redactor.redact_line('2026/11/07 12:00:00 [error] 12345678901 x'),
                         '2026/11/07 12:00:00 [error] -: <redacted>')

    def test_non_ascii_digits_are_not_taken_for_a_pid_or_time(self):
        out = redactor.redact_line('\u0662026/11/07 12:00:00 [error] \u0668\u0661\u0662 x ' + SECRET)
        self.assertEqual(out, '- [-] -: <redacted>')

    def test_an_unknown_level_is_not_echoed(self):
        out = redactor.redact_line('2026/11/07 12:00:00 [%s] 812#812: x' % SECRET)
        self.assertNotIn(SECRET, out)
        self.assertEqual(out, '2026/11/07 12:00:00 [-] -: <redacted>')  # no level, so no pid either

    def test_an_exception_in_redaction_prints_nothing_of_the_input(self):
        original = redactor.redact_text
        redactor.redact_text = lambda text: 1 / 0
        try:
            out = redactor.redact_line(request_line('GET /?a=%s HTTP/1.1' % SECRET))
        finally:
            redactor.redact_text = original
        self.assertEqual(out, '<redacted>')


class ServeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name) / 'error.log'

    def test_each_datagram_becomes_one_appended_line_and_the_file_is_reopened(self):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(server.close)
        self.addCleanup(client.close)
        client.send(request_line('GET /?a=%s HTTP/1.1' % SECRET).encode())
        redactor.serve(server, str(self.output), max_messages=1)
        self.output.rename(self.output.with_name('error.log.1'))  # logrotate moves it
        client.send(request_line('GET /?b=%s HTTP/1.1' % SECRET).encode())
        redactor.serve(server, str(self.output), max_messages=1)
        self.assertEqual(len(self.output.read_text().splitlines()), 1)
        self.assertIn('?b=<redacted>', self.output.read_text())
        self.assertNotIn(SECRET, self.output.read_text() + self.output.with_name('error.log.1').read_text())

    def test_an_unwritable_output_drops_the_line_and_keeps_serving(self):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(server.close)
        self.addCleanup(client.close)
        client.send(b'one')
        client.send(b'two')
        # A write that fails some other way (the output path is a directory) drops the line
        # and keeps serving. A missing or unowned file exits instead: see the next test.
        directory = Path(self.tmp.name) / 'is-a-directory'
        directory.mkdir()
        redactor.serve(server, str(directory), max_messages=2)  # does not raise

    def test_a_missing_file_or_permission_error_exits_nonzero_so_systemd_reruns_the_setup(self):
        for output in (Path(self.tmp.name) / 'no-such-dir' / 'error.log',):
            server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
            self.addCleanup(server.close)
            self.addCleanup(client.close)
            client.send(request_line('GET /?a=%s HTTP/1.1' % SECRET).encode())
            with self.assertRaises(SystemExit) as raised:
                redactor.serve(server, str(output), max_messages=1)
            self.assertEqual(raised.exception.code, 1)

    def test_a_permission_error_also_exits_nonzero(self):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(server.close)
        self.addCleanup(client.close)
        client.send(b'x')
        original = redactor.append_lines
        redactor.append_lines = lambda lines, output: (_ for _ in ()).throw(PermissionError(13, SECRET))
        try:
            with self.assertRaises(SystemExit) as raised:
                redactor.serve(server, 'unused', max_messages=1)
        finally:
            redactor.append_lines = original
        self.assertEqual(raised.exception.code, 1)

    def test_the_script_reads_fd_3_and_prints_none_of_its_input(self):
        path = os.path.join(self.tmp.name, 's.sock')
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(listener.close)
        listener.bind(path)
        child = subprocess.Popen(
            [sys.executable, '-I', str(SCRIPT), '--output', str(self.output)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(listener.fileno(),),
            preexec_fn=lambda: os.dup2(listener.fileno(), 3))
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(sender.close)
        sender.sendto(request_line('GET /?token=%s HTTP/1.1' % SECRET).encode(), path)
        deadline = time.time() + 10
        while time.time() < deadline and not (self.output.exists() and self.output.read_text()):
            time.sleep(0.05)
        child.kill()
        out, err = child.communicate()
        self.assertIn('?token=<redacted> <redacted>', self.output.read_text())
        self.assertNotIn(SECRET, self.output.read_text())
        self.assertNotIn(SECRET.encode(), out + err)


if __name__ == '__main__':
    unittest.main()
