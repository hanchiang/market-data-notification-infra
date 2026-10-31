"""Fake commands for the shell-script tests: each fake records its argv and stdin, then
prints a canned reply, so no test reaches AWS, GitHub, Telegram or the host."""
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

REPO = Path(__file__).resolve().parents[1]


class FakeBin:
    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        self.log = self.dir / 'calls.jsonl'

    def cleanup(self) -> None:
        self._tmp.cleanup()

    def add(self, name: str, body: str) -> None:
        """A fake whose behaviour is a bash snippet; it logs argv and stdin first."""
        script = self.bin / name
        script.write_text(
            '#!/bin/bash\n'
            'stdin=""\n'
            'if [ ! -t 0 ]; then stdin=$(cat); fi\n'
            f'python3 -c \'import json,sys; print(json.dumps({{"cmd": sys.argv[1], "argv": sys.argv[2:-1], "stdin": sys.argv[-1]}}))\' '
            f'{name} "$@" "$stdin" >> {self.log}\n'
            + body + '\n')
        script.chmod(script.stat().st_mode | stat.S_IXUSR)

    def calls(self, name: Optional[str] = None) -> List[Dict]:
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [r for r in rows if name is None or r['cmd'] == name]

    def run(self, argv: List[str], env: Optional[Dict[str, str]] = None, cwd: Optional[Path] = None,
            timeout: int = 60) -> subprocess.CompletedProcess:
        full_env = {'PATH': f'{self.bin}:/usr/bin:/bin', 'HOME': str(self.dir)}
        full_env.update(env or {})
        # A closed stdin: a fake reading an inherited, never-closed stdin would hang.
        return subprocess.run(argv, env=full_env, cwd=cwd, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=timeout)
