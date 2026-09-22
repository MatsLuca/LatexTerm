#!/usr/bin/env python3
"""Install only LatexTerm's Codex hook definitions, preserving existing hooks and notify.

Dry run by default. Review/trust the added hooks in Codex /hooks after --apply.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

from codex_hook import EVENTS


def install(home, codex_home, apply=False):
    target = home / ".local/share/latexterm/codex_hook.py"
    config = codex_home / "hooks.json"
    command = shlex.join([sys.executable, str(target)])
    old = config.read_text() if config.exists() else "{}"
    data = json.loads(old)
    if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
        raise ValueError("hooks.json has an unsupported shape")
    hooks = data.setdefault("hooks", {})
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError("Unsupported hook group: " + event)
        existing = [h for g in groups for h in g.get("hooks", []) if h.get("command") == command]
        if not existing:
            groups.append({"hooks": [{"type": "command", "command": command, "timeout": 2}]})
    new = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    source = Path(__file__).with_name("codex_hook.py").read_bytes()
    changes = []
    if target.is_symlink() or config.is_symlink():
        raise ValueError("Refusing to replace a symlink")
    if not target.exists() or target.read_bytes() != source:
        changes.append(str(target))
    if json.loads(old) != data:
        changes.append(str(config))
    if apply:
        codex_home.mkdir(parents=True, exist_ok=True)
        if (config.read_text() if config.exists() else "{}") != old:
            raise ValueError("hooks.json changed during preflight")
        for path, content in [(target, source), (config, new.encode())]:
            if str(path) not in changes:
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists():
                backup = Path(tempfile.mkdtemp(prefix="latexterm-backup-", dir=codex_home)) / path.name
                shutil.copy2(path, backup)
            fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".latexterm-")
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
    return changes


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    home = Path.home()
    codex_home = Path(os.environ.get("CODEX_HOME", home / ".codex"))
    changes = install(home, codex_home, args.apply)
    print("\n".join(changes) if changes else "Already installed.")
    print("Review and trust the LatexTerm entries in Codex /hooks." if args.apply else "Dry run; use --apply to install.")
