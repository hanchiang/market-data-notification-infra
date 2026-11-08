#!/usr/bin/env python3
"""Nginx error-log redactor: reads syslog datagrams from the socket systemd passes in,
redacts the query of each line, and appends the result to /var/log/nginx/error.log.

Nginx cannot format its error log, and request-scoped lines end with the raw request line,
the upstream URL, the host and, when the request sent one, the referrer, so a query value (a
token, say) would reach disk. Nginx
therefore sends the error log here (`error_log syslog:server=unix:...`) instead of to a file.

What this guarantees, for every line (a line is a datagram piece split on newline characters only):
- From the first `?` to the end of the line, nothing is written except `<redacted>` and ASCII
  parameter names that are followed by `=`. A name that is not a plain name, an entry with
  no `=`, and anything after a value's first ASCII whitespace become `<redacted>`.
  Trade-off: the fields after the query (`upstream`, `host`, `referrer`) are lost on such a
  line. Nginx keeps bytes inside the request field that a tokenizer would treat as
  whitespace (NBSP, U+3000, a tab, a space in the URI) or as a closing quote, so no
  delimiter after the `?` can be trusted to end the query.
- A line with no parseable header keeps only a time, level and pid that sit at the start of
  the line, after the optional syslog prefix, in that order. Anything else is `-`.
- Control characters and U+2028/U+2029/U+0085 are escaped, so one datagram piece is
  one output line.
- It never raises while redacting, and the input goes nowhere but the output file. Nothing
  reaches stdout or stderr except an exception class name, so no traceback carries a value
  into journald.
What this does NOT guarantee: a secret that is not in a query string (a header, a path
segment) or that sits before the first `?` is written as Nginx wrote it.

Line format: `YYYY/MM/DD HH:MM:SS [level] pid#tid: *cid message, client: ..., server: ...,
request: "...", upstream: "...", host: "...", referrer: "..."`. The host's error log confirmed
it through `host` on 2026-11-07 (Nginx 1.18.0; HostLineTest); `referrer` is from Nginx's docs.
Not yet seen on the host: the `<PRI>Mon DD HH:MM:SS nginx: ` syslog prefix, which `nohostname`
writes without a hostname. If the prefix pattern rejects it, lines come out as
`- [-] -: <redacted>`, and the Nginx play's 413 probe fails: it needs a `pid#tid` and a `*cid`.
"""
import re
import socket
import sys

REDACTED = '<redacted>'
DEFAULT_OUTPUT = '/var/log/nginx/error.log'
LISTEN_FDS_START = 3  # systemd socket activation: the first passed socket is fd 3
MAX_DATAGRAM = 65536

LEVELS = ('debug', 'info', 'notice', 'warn', 'error', 'crit', 'alert', 'emerg')
# re.ASCII everywhere: without it \d, \s and \w also match other scripts' digits and spaces.
_TIME = r'\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}'
# The header must start the line, after an optional syslog prefix (`<PRI>Mon DD HH:MM:SS [host] tag: `).
# Anchored, because a header found elsewhere in the line could be text the client supplied.
# A pid or thread id has at most 10 digits.
_SYSLOG_PREFIX = r'(?:<\d{1,3}>[A-Za-z]{3} [ 0-9]\d \d{2}:\d{2}:\d{2} (?:\S+ )?[^\s:]+: )?'
_HEADER = re.compile(
    r'\A' + _SYSLOG_PREFIX + r'(?P<time>' + _TIME + r') \[(?P<level>' + '|'.join(LEVELS) + r')\] '
    r'(?P<pid>\d{1,10})#(?P<tid>\d{1,10}): (?P<body>.*)', re.DOTALL | re.ASCII)
# The fallback for a line with no full header: time, then level, then pid, each only if it
# follows the one before it from the start of the line (after the optional syslog prefix).
# A field found anywhere else could be text the client supplied.
_FALLBACK = re.compile(
    r'\A' + _SYSLOG_PREFIX + r'(?:(?P<time>' + _TIME + r')(?: \[(?P<level>' + '|'.join(LEVELS) + r')\]'
    r'(?: (?P<pid>\d{1,10})(?!\d))?)?)?', re.ASCII)
# One query entry: a plain parameter name, `=`, and a value up to the next `&` or ASCII
# whitespace. A name is a letter or underscore, then name characters, with at most one
# `[...]` group, and 20 characters in all, brackets included (the lookahead counts up to the
# `=`). Anything else (percent escapes, quotes, several bracket groups, long random-looking
# strings that may be a secret passed without a name) does not match, so it is redacted.
_ENTRY = re.compile(r'(?=[^=]{1,20}=)([A-Za-z_][A-Za-z0-9_.\-]*(?:\[[A-Za-z0-9_\-]*\])?)=[^&\s]*', re.ASCII)
# Control characters, C1 controls (U+0085 among them), and the Unicode line/paragraph separators.
_UNSAFE = re.compile('[\x00-\x1f\x7f-\x9f\u2028\u2029]', re.ASCII)


def redact_text(text):
    """Redact from the first `?` to the end of the text; see the module docstring."""
    mark = text.find('?')
    if mark < 0:
        return text
    rest = text[mark + 1:]
    names, pos = [], 0
    while True:
        entry = _ENTRY.match(rest, pos)
        if not entry:
            break
        names.append(entry.group(1) + '=' + REDACTED)
        pos = entry.end()
        if rest[pos:pos + 1] != '&':
            break
        pos += 1
    leftover = ' ' + REDACTED if rest[pos:] else ''
    return text[:mark + 1] + '&'.join(names) + leftover


def _escape(text):
    return _UNSAFE.sub(lambda m: '\\x%02x' % ord(m.group()) if ord(m.group()) < 256
                       else '\\u%04x' % ord(m.group()), text)


def _unparseable(text):
    """Time, level and pid only, each from its fixed position, each a pattern whose match
    holds no free text."""
    found = _FALLBACK.match(text)
    return '%s [%s] %s: %s' % (found.group('time') or '-' if found else '-',
                               found.group('level') or '-' if found else '-',
                               found.group('pid') or '-' if found else '-',
                               REDACTED)


def redact_line(data):
    """Turn one line (bytes or str) into one cleaned log line, without newline."""
    try:
        text = data.decode('utf-8', 'replace') if isinstance(data, bytes) else str(data)
        header = _HEADER.match(text)
        if not header:
            return _escape(_unparseable(text))
        return _escape('%s [%s] %s#%s: %s' % (header.group('time'), header.group('level'),
                                              header.group('pid'), header.group('tid'),
                                              redact_text(header.group('body'))))
    except Exception:  # never raise, and never echo the input
        return REDACTED


def redact_datagram(data):
    """Split on newline only (str.splitlines also splits on VT, FS, U+2028 and more) and
    redact each piece as its own line. A piece that is not a line of its own has no header,
    so it comes out as placeholders."""
    try:
        text = data.decode('utf-8', 'replace') if isinstance(data, bytes) else str(data)
        pieces = text.split('\n')
        if len(pieces) > 1 and pieces[-1] == '':
            pieces.pop()
    except Exception:
        pieces = ['']
    return [redact_line(piece) for piece in pieces]


def append_lines(lines, output):
    # Opened per datagram so logrotate needs no signal: a recreated file is picked up next time.
    with open(output, 'a', encoding='utf-8', errors='replace') as handle:
        handle.write(''.join(line + '\n' for line in lines))


def serve(sock, output, max_messages=None):
    handled = 0
    while max_messages is None or handled < max_messages:
        try:
            data = sock.recv(MAX_DATAGRAM)
        except InterruptedError:
            continue
        except Exception as error:
            print('recv failed: %s' % type(error).__name__, file=sys.stderr)
            raise SystemExit(1)  # Restart=always brings back a fresh socket handle
        handled += 1
        try:
            append_lines(redact_datagram(data), output)
        except (PermissionError, FileNotFoundError) as error:
            # The file is gone or not ours (an old-log purge, a bad recreate). The unit's
            # ExecStartPre=+ recreates it with the right owner, so exit and let
            # Restart=always run it again. This datagram is lost.
            print('write failed: %s' % type(error).__name__, file=sys.stderr)
            raise SystemExit(1)
        except Exception as error:  # e.g. disk full: drop the line, keep serving
            print('write failed: %s' % type(error).__name__, file=sys.stderr)


def main(argv):
    output = DEFAULT_OUTPUT
    if len(argv) == 3 and argv[1] == '--output':
        output = argv[2]
    serve(socket.socket(fileno=LISTEN_FDS_START), output)


if __name__ == '__main__':
    main(sys.argv)
