#!/usr/bin/env python3
"""Fail when a tracked file reopens public SSH or weakens host-key checking (Goal 10).

The condition protected: no security group admits port 22 from an address range, and
every ssh, scp and Ansible path that reaches the host is strict against a pinned key.
Run by .github/workflows/ssh-policy.yml on every push and pull request.

    python3 scripts/check_ssh_policy.py [--allow-public-ssh FILE:TYPE.NAME] [PATH ...]

With no PATH it checks every file `git ls-files` lists, except this script and its
fixtures. Prints `path:line: rule: message` per finding and exits 1 if there is any.

--allow-public-ssh is the phase 1 transition only: main.tf keeps its port 22 ingress until
the phase 2 commit removes it, and that commit deletes the flag from ssh-policy.yml. The
flag names exactly one resource and suppresses only the public-ssh rule inside it. It fails
the run once that resource has no port 22 ingress, or more than one, so it can neither
outlive the ingress nor cover a second one.

The host access health job's --allow-terraform-public-22 is the same transition, so it
expires with this flag: with no --allow-public-ssh in force, any tracked file still naming
it fails. Otherwise a forgotten health flag would tolerate, for good, an undescribed
break-glass rule of the same shape.
"""
import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, List, Optional, Tuple

SELF = 'scripts/check_ssh_policy.py'
HEALTH_ALLOWANCE = '--allow-terraform-public-22'
FIXTURES = 'tests/ssh_policy_fixtures/'

# Host-key weakening, matched per line in any file type. The workspace's
# scripts/check_host_consumers.py applies the same patterns to the backend; its test
# compares the two lists, so change both together.
WEAKENING_PATTERNS: List[Tuple[str, re.Pattern]] = [
    ('strict-host-key-checking-off',
     re.compile(r'StrictHostKeyChecking["\']?\s*[=\s]\s*["\']?(no|off|accept-new)\b', re.IGNORECASE)),
    ('known-hosts-dev-null',
     re.compile(r'UserKnownHostsFile["\']?\s*[=\s]\s*["\']?/dev/null', re.IGNORECASE)),
    # host_key_checking = False, ANSIBLE_HOST_KEY_CHECKING=false, ansible_host_key_checking: no ...
    ('ansible-host-key-checking-off',
     re.compile(r'host_key_checking["\']?\s*[=:]\s*["\']?(false|no|off|0|n)\b', re.IGNORECASE)),
    # A key read off the network and trusted without an out-of-band comparison.
    ('keyscan-into-known-hosts',
     re.compile(r'ssh-keyscan\b.*(>|\btee\b).*known_hosts')),
]

# ssh_config keywords that mark the lines under `Host <alias>` as a config block.
SSH_CONFIG_KEYWORDS = {
    'hostname', 'user', 'port', 'identityfile', 'identitiesonly', 'proxycommand', 'proxyjump',
    'hostkeyalias', 'stricthostkeychecking', 'userknownhostsfile', 'serveraliveinterval',
    'controlmaster', 'controlpath', 'controlpersist', 'forwardagent', 'localforward', 'batchmode',
}

SG_RESOURCE = re.compile(
    r'resource\s+"(aws_security_group|aws_security_group_rule|aws_vpc_security_group_ingress_rule)"'
    r'\s+"([^"]+)"\s*\{')
INLINE_INGRESS = re.compile(r'(?<![\w.])(ingress\s*\{|dynamic\s+"ingress"\s*\{)')
CONNECTION_BLOCK = re.compile(r'(?<![\w.])connection\s*\{')
CIDR_ATTRIBUTES = ('cidr_blocks', 'ipv6_cidr_blocks', 'cidr_ipv4', 'cidr_ipv6', 'prefix_list_ids', 'prefix_list_id')


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str
    resource: Optional[str] = None

    def render(self) -> str:
        return f'{self.path}:{self.line}: {self.rule}: {self.message}'


def blank_comments(text: str) -> str:
    """HCL with comments replaced by spaces, so offsets and line numbers still line up."""
    out = []
    i, n, in_string = 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif c == '#' or text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end == -1 else end
            out.append(' ' * (end - i))
            i = end
        elif text.startswith('/*', i):
            end = text.find('*/', i + 2)
            end = n if end == -1 else end + 2
            out.append(''.join(ch if ch == '\n' else ' ' for ch in text[i:end]))
            i = end
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def block_end(text: str, open_brace: int) -> int:
    """Index just past the brace that closes the one at `open_brace` (strings skipped)."""
    depth, i, in_string = 0, open_brace, False
    while i < len(text):
        c = text[i]
        if in_string:
            if c == '\\':
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def attribute(body: str, name: str) -> Optional[str]:
    """The raw right-hand side of `name = ...` at the top level of a block body."""
    match = re.search(rf'(?m)^\s*{name}\s*=\s*(.+?)\s*$', body)
    return match.group(1) if match else None


def covers_port_22(body: str, protocol_attribute: str) -> Tuple[bool, str]:
    protocol = (attribute(body, protocol_attribute) or '"tcp"').strip('"').lower()
    if protocol in ('-1', 'all'):
        return True, 'every port (protocol -1)'
    if protocol not in ('tcp', '6'):
        return False, ''
    ports = []
    for name in ('from_port', 'to_port'):
        raw = attribute(body, name)
        if raw is None or not re.fullmatch(r'\d+', raw):
            # A computed port cannot be proven to miss 22, so it counts as covering it.
            return True, f'{name} is not a literal ({raw})'
        ports.append(int(raw))
    if ports[0] <= 22 <= ports[1]:
        return True, f'ports {ports[0]}-{ports[1]}'
    return False, ''


def has_address_source(body: str) -> bool:
    for name in CIDR_ATTRIBUTES:
        raw = attribute(body, name)
        if raw is not None and raw.replace(' ', '') not in ('[]', 'null'):
            return True
    return False


def line_of(text: str, offset: int) -> int:
    return text.count('\n', 0, offset) + 1


def terraform_findings(path: str, raw_text: str) -> Iterator[Finding]:
    text = blank_comments(raw_text)
    for resource in SG_RESOURCE.finditer(text):
        kind, name = resource.group(1), resource.group(2)
        resource_id = f'{kind}.{name}'
        start = resource.end() - 1
        body = text[start:block_end(text, start)]
        if kind == 'aws_security_group':
            for ingress in INLINE_INGRESS.finditer(body):
                brace = ingress.end() - 1
                ingress_body = body[brace:block_end(body, brace)]
                if ingress.group(0).startswith('dynamic'):
                    # Its rules are computed from data this check cannot see.
                    covered, why = True, 'dynamic ingress block'
                    sourced = True
                else:
                    covered, why = covers_port_22(ingress_body, 'protocol')
                    sourced = has_address_source(ingress_body)
                if covered and sourced:
                    yield Finding(path, line_of(text, start + ingress.start()), 'public-ssh',
                                  f'{resource_id} ingress admits port 22 ({why}) from an address range',
                                  resource_id)
            continue
        if kind == 'aws_security_group_rule' and (attribute(body, 'type') or '').strip('"') != 'ingress':
            continue
        protocol_attribute = 'ip_protocol' if kind == 'aws_vpc_security_group_ingress_rule' else 'protocol'
        covered, why = covers_port_22(body, protocol_attribute)
        if covered and has_address_source(body):
            yield Finding(path, line_of(text, resource.start()), 'public-ssh',
                          f'{resource_id} admits port 22 ({why}) from an address range', resource_id)

    for connection in CONNECTION_BLOCK.finditer(text):
        brace = connection.end() - 1
        body = text[brace:block_end(text, brace)]
        # A connection block with no type is an SSH connection.
        if (attribute(body, 'type') or '"ssh"').strip('"') == 'ssh':
            yield Finding(path, line_of(text, connection.start()), 'terraform-ssh-connection',
                          'a Terraform connection block cannot pin a host key or use a ProxyCommand')


def weakening_findings(path: str, text: str) -> Iterator[Finding]:
    for number, line in enumerate(text.splitlines(), start=1):
        for rule, pattern in WEAKENING_PATTERNS:
            if pattern.search(line):
                yield Finding(path, number, rule, line.strip()[:120])


def unpinned_writer_findings(path: str, text: str) -> Iterator[Finding]:
    """Every SSH config block a file writes must be strict against a real known_hosts."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        host = re.match(r'^(\s*)Host\s+\S', line)
        if not host:
            continue
        indent = len(host.group(1))
        settings = []
        for follow in lines[index + 1:]:
            setting = re.match(r'^(\s*)([A-Za-z]+)[\s=]+(.*)$', follow)
            if not setting or len(setting.group(1)) <= indent:
                break
            settings.append((setting.group(2).lower(), setting.group(3).strip().strip('"\'')))
        if not any(keyword in SSH_CONFIG_KEYWORDS for keyword, _ in settings):
            continue
        values = dict(settings)
        strict = values.get('stricthostkeychecking', '').lower() == 'yes'
        known_hosts = values.get('userknownhostsfile')
        if not strict or not known_hosts or known_hosts == '/dev/null':
            yield Finding(path, index + 1, 'unpinned-ssh-config',
                          'an SSH config block must set StrictHostKeyChecking yes and a real UserKnownHostsFile')


def check_file(path: str, text: str) -> List[Finding]:
    findings = list(weakening_findings(path, text))
    findings += unpinned_writer_findings(path, text)
    if path.endswith('.tf'):
        findings += terraform_findings(path, text)
    return findings


def tracked_files(root: Path) -> List[str]:
    listed = subprocess.run(['git', 'ls-files'], cwd=root, capture_output=True, text=True, check=True)
    return [p for p in listed.stdout.splitlines() if p != SELF and not p.startswith(FIXTURES)]


def parse_allowance(raw: str) -> Tuple[str, str]:
    path, sep, resource = raw.rpartition(':')
    if not sep or not path or not re.fullmatch(r'[a-z0-9_]+\.[A-Za-z0-9_-]+', resource):
        raise SystemExit(f'--allow-public-ssh wants FILE:TYPE.NAME, got {raw!r}')
    return path, resource


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--allow-public-ssh', action='append', default=[],
                        help='phase 1 only: FILE:TYPE.NAME of the one resource whose port 22 ingress may stay')
    parser.add_argument('paths', nargs='*')
    args = parser.parse_args(argv)
    if len(args.allow_public_ssh) > 1:
        parser.error('--allow-public-ssh may name one resource only')
    allowed_file, allowed_resource = (parse_allowance(args.allow_public_ssh[0]) if args.allow_public_ssh
                                      else (None, None))

    root = Path.cwd()
    paths = args.paths or tracked_files(root)
    findings: List[Finding] = []
    for path in paths:
        file = root / path
        if not file.is_file():
            continue
        try:
            text = file.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue  # binary files (images) carry no config
        findings += check_file(path, text)
        if not allowed_resource:
            findings += [Finding(path, number, 'stale-health-allowance',
                                 f'{HEALTH_ALLOWANCE} outlived --allow-public-ssh; delete it with the port 22 ingress')
                         for number, line in enumerate(text.splitlines(), start=1) if HEALTH_ALLOWANCE in line]

    if allowed_resource:
        allowed = [f for f in findings
                   if f.rule == 'public-ssh' and (f.path, f.resource) == (allowed_file, allowed_resource)]
        if len(allowed) > 1:
            findings.append(Finding(allowed_file, 1, 'allowance-too-wide',
                                    f'{allowed_resource} has {len(allowed)} port 22 ingresses; '
                                    'the phase 1 allowance covers exactly one'))
        elif allowed:
            findings = [f for f in findings if f not in allowed]
            print(f'allowed for phase 1 only: {allowed_file}:{allowed_resource} '
                  f'(one port 22 ingress); the phase 2 commit removes it and this flag')
        else:
            findings.append(Finding(allowed_file, 1, 'stale-allowance',
                                    f'{allowed_resource} has no port 22 ingress any more; '
                                    'delete --allow-public-ssh from .github/workflows/ssh-policy.yml'))

    for finding in findings:
        print(finding.render())
    if findings:
        print(f'{len(findings)} SSH policy finding(s). No port 22 from any address range, '
              'and every SSH path strict against a pinned host key (infra AGENTS.md).', file=sys.stderr)
        return 1
    print(f'SSH policy: {len(paths)} file(s) checked, no findings')
    return 0


if __name__ == '__main__':
    sys.exit(main())
